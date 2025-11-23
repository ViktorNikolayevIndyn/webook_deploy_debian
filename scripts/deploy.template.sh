#!/bin/bash
set -e

MODE="${1:-dev}"  # dev | prod | staging и т.д.

echo "[deploy] Working dir: $(pwd)"
echo "[deploy] Mode: $MODE"

# Имя проекта (по папке)
PROJECT_NAME="${PROJECT_NAME:-$(basename "$(pwd)")}"
# Порт берём из ENV, который задаёт deploy_config.sh, иначе 3000
HOST_PORT="${DEPLOY_PORT:-3000}"

# --- 1. git pull, если есть репозиторий ---
if [ -d ".git" ]; then
  echo "[deploy] Running git pull..."
  git pull || echo "[deploy] WARN: git pull failed (может быть ок для локальных тестов)"
else
  echo "[deploy] No .git directory – skipping git pull."
fi

# --- 2. Поиск или автогенерация docker-compose файла ---

find_compose_file() {
  local mode="$1"

  # Приоритет: docker-compose.<mode>.yml
  local candidates=(
    "docker-compose.${mode}.yml"
    "docker-compose.${mode}.yaml"
    "docker-compose.yml"
    "docker-compose.yaml"
  )

  for f in "${candidates[@]}"; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done

  return 1
}

generate_compose_file() {
  local mode="$1"
  local port="$2"
  local file="docker-compose.${mode}.yml"

  echo "[deploy] Autogenerating $file (mode=$mode, port=$port, project=$PROJECT_NAME)..."

  cat > "$file" <<EOF
services:
  ${PROJECT_NAME}-${mode}:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-${mode}
    restart: unless-stopped
    environment:
      - NODE_ENV=${mode}
      - HOST=0.0.0.0
      - PORT=3000
    ports:
      - "${port}:3000"
    # В dev-режиме удобно монтировать код с хоста
    $(if [ "$mode" = "dev" ]; then
        cat <<'VOL'
    volumes:
      - .:/app
      - /app/node_modules
    command: npm run dev
VOL
      else
        cat <<'VOL'
    command: npm run start
VOL
      fi)
EOF

  echo "[deploy] Generated $file."
  echo "$file"
}

COMPOSE_FILE=""
if COMPOSE_FILE="$(find_compose_file "$MODE")"; then
  echo "[deploy] Found compose file: $COMPOSE_FILE"
else
  echo "[deploy] No docker-compose file found – generating one..."
  COMPOSE_FILE="$(generate_compose_file "$MODE" "$HOST_PORT")"
fi

# --- 3. docker compose up --build --detach ---
echo "[deploy] Running: docker compose -f $COMPOSE_FILE up -d --build"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "[deploy] Done. Mode=$MODE, port=$HOST_PORT, compose=$COMPOSE_FILE"
