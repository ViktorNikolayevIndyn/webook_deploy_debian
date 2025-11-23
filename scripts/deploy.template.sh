#!/bin/bash
set -e

# -------- Basic info --------
MODE="$1"                          # dev / prod / staging ... опционально
WORKDIR="$(pwd)"

echo "[deploy] Working dir: $WORKDIR"
echo "[deploy] Mode: ${MODE:-<none>}"

# -------- Git pull (опционально) --------
if [ -d ".git" ]; then
  echo "[deploy] Running git pull..."
  git pull || echo "[deploy] WARNING: git pull failed (continuing anyway)"
else
  echo "[deploy] No .git directory in $WORKDIR – skipping git pull."
fi

# -------- Detect docker compose binary --------
if command -v "docker-compose" >/dev/null 2>&1; then
  DOCKER_COMPOSE_BIN="docker-compose"
elif command -v "docker" >/dev/null 2>&1; then
  DOCKER_COMPOSE_BIN="docker compose"
else
  echo "[deploy] ERROR: neither 'docker compose' nor 'docker-compose' found in PATH."
  exit 1
fi

echo "[deploy] Using compose binary: $DOCKER_COMPOSE_BIN"

# -------- Detect compose file --------
COMPOSE_FILE=""

# В каких директориях ищем
SEARCH_DIRS=(
  "."
  "docker"
  "deploy"
)

# Какие имена пытаемся подобрать
CANDIDATE_NAMES=()

# Если передан MODE – сначала ищем docker-compose.<mode>.yml/yaml
if [ -n "$MODE" ]; then
  CANDIDATE_NAMES+=(
    "docker-compose.$MODE.yml"
    "docker-compose.$MODE.yaml"
  )
fi

# Базовые имена без режима
CANDIDATE_NAMES+=(
  "docker-compose.yml"
  "docker-compose.yaml"
)

# Перебор директорий и имён
for dir in "${SEARCH_DIRS[@]}"; do
  for name in "${CANDIDATE_NAMES[@]}"; do
    candidate="$dir/$name"
    if [ -f "$candidate" ]; then
      COMPOSE_FILE="$candidate"
      break 2
    fi
  done
done

if [ -z "$COMPOSE_FILE" ]; then
  echo "[deploy] ERROR: no docker-compose file found."
  echo "[deploy] Looked for:"
  for dir in "${SEARCH_DIRS[@]}"; do
    for name in "${CANDIDATE_NAMES[@]}"; do
      echo "  - $dir/$name"
    done
  done
  exit 1
fi

echo "[deploy] Using compose file: $COMPOSE_FILE"

# -------- Run compose (pull/build/up) --------

# 1) pull (не обязательно, но полезно)
echo "[deploy] Running: $DOCKER_COMPOSE_BIN -f \"$COMPOSE_FILE\" pull"
# не фейлим весь деплой, если pull не обязателен
set +e
$DOCKER_COMPOSE_BIN -f "$COMPOSE_FILE" pull
PULL_RC=$?
set -e

if [ "$PULL_RC" -ne 0 ]; then
  echo "[deploy] WARNING: compose pull finished with code $PULL_RC (continuing)."
fi

# 2) build
echo "[deploy] Running: $DOCKER_COMPOSE_BIN -f \"$COMPOSE_FILE\" build"
$DOCKER_COMPOSE_BIN -f "$COMPOSE_FILE" build

# 3) up -d
echo "[deploy] Running: $DOCKER_COMPOSE_BIN -f \"$COMPOSE_FILE\" up -d"
$DOCKER_COMPOSE_BIN -f "$COMPOSE_FILE" up -d

echo "[deploy] Done."
