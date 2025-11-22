#!/bin/bash
set -e

MODE="$1"

if [ -z "$MODE" ]; then
  echo "Usage: $0 <mode>"
  echo "Example: $0 dev  or  $0 prod"
  exit 1
fi

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[deploy] Working dir: $APP_DIR"
echo "[deploy] Mode: $MODE"

if [ ! -d ".git" ]; then
  echo "[deploy] WARNING: .git directory not found in $APP_DIR (git pull skipped)."
else
  echo "[deploy] Running git pull..."
  git pull --rebase || git pull
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[deploy] ERROR: docker not found in PATH."
  exit 1
fi

if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
  echo "[deploy] ERROR: docker-compose.yml not found in $APP_DIR"
  exit 1
fi

COMPOSE_FILE="docker-compose.yml"
[ -f "docker-compose.yaml" ] && COMPOSE_FILE="docker-compose.yaml"

echo "[deploy] Using compose file: $COMPOSE_FILE"

SERVICE_NAME="app-${MODE}"

echo "[deploy] Building service ${SERVICE_NAME}..."
docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"

echo "[deploy] Starting service ${SERVICE_NAME}..."
docker compose -f "$COMPOSE_FILE" up -d "$SERVICE_NAME"

echo "[deploy] Done."
