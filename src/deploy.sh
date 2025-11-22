#!/bin/bash
set -e

REPO_DIR="$1"
BRANCH_NAME="$2"
COMPOSE_FILE="$3"
SERVICE_NAME="$4"

if [ -z "$REPO_DIR" ] || [ -z "$BRANCH_NAME" ] || [ -z "$COMPOSE_FILE" ] || [ -z "$SERVICE_NAME" ]; then
  echo "Usage: $0 <REPO_DIR> <BRANCH_NAME> <COMPOSE_FILE> <SERVICE_NAME>"
  exit 1
fi

echo "=== DEPLOY START ==="
echo "Repo dir     : $REPO_DIR"
echo "Branch       : $BRANCH_NAME"
echo "Compose file : $COMPOSE_FILE"
echo "Service      : $SERVICE_NAME"
echo "===================="

if [ ! -d "$REPO_DIR" ]; then
  echo "[ERROR] Repo directory does not exist: $REPO_DIR"
  exit 1
fi

cd "$REPO_DIR"

if [ ! -d .git ]; then
  echo "[ERROR] This directory is not a git repository: $REPO_DIR"
  exit 1
fi

echo "--- Git fetch ---"
git fetch origin "$BRANCH_NAME"

LOCAL_REV="$(git rev-parse HEAD)"
REMOTE_REV="$(git rev-parse "origin/$BRANCH_NAME")"

echo "Local  HEAD : $LOCAL_REV"
echo "Remote HEAD : $REMOTE_REV"

if [ "$LOCAL_REV" = "$REMOTE_REV" ]; then
  echo "--- No changes detected. Skipping Docker build and restart. ---"
  echo "=== DEPLOY DONE (NO CHANGES) ==="
  exit 0
fi

echo "--- Changes detected. Resetting to origin/$BRANCH_NAME ---"
git reset --hard "origin/$BRANCH_NAME"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "[ERROR] docker compose file not found: $COMPOSE_FILE"
  exit 1
fi

echo "--- Docker build ---"
docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"

echo "--- Docker up -d ---"
docker compose -f "$COMPOSE_FILE" up -d "$SERVICE_NAME"

echo "=== DEPLOY DONE (UPDATED) ==="
