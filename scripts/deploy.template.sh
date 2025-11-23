#!/bin/bash
set -e

MODE="$1"
WORKDIR="$(pwd)"

echo "[deploy] Working dir: $WORKDIR"
echo "[deploy] Mode: ${MODE:-none}"

# 1) git pull, если это git-репо
if [ -d ".git" ]; then
  echo "[deploy] Running git pull..."
  git pull --ff-only || echo "[deploy] WARNING: git pull failed (non-fast-forward or other issue)."
else
  echo "[deploy] No .git directory here – skipping git pull."
fi

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
APP_NAME="$(basename "$WORKDIR")"
PORT_DEFAULT_DEV=3001
PORT_DEFAULT_PROD=3002

# 2) Определим порт (если хочешь – можно потом передавать как 2-й аргумент)
if [ -n "$DEPLOY_PORT" ]; then
  PORT="$DEPLOY_PORT"
else
  case "$MODE" in
    dev)  PORT="$PORT_DEFAULT_DEV" ;;
    prod) PORT="$PORT_DEFAULT_PROD" ;;
    *)    PORT=3000 ;;
  esac
fi

echo "[deploy] Using APP_NAME=$APP_NAME, PORT=$PORT"

# 3) Если нет Dockerfile – создаём минимальный для Node/Next
if [ ! -f "Dockerfile" ]; then
  echo "[deploy] Dockerfile not found – generating basic Node/Next Dockerfile..."

  cat > Dockerfile <<'EOF'
FROM node:20-alpine

WORKDIR /app

# Устанавливаем зависимости
COPY package*.json ./
RUN npm ci

# Копируем исходники
COPY . .

# Сборка (для Next / других билд-проектов)
RUN npm run build

EXPOSE 3000

# Прод-режим: npm start (для Next – обычно "next start")
CMD ["npm", "start"]
EOF

  echo "[deploy] Dockerfile generated."
else
  echo "[deploy] Existing Dockerfile found – using it."
fi

# 4) Если нет docker-compose.yml – создаём минимальный
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "[deploy] $COMPOSE_FILE not found – generating basic compose file..."

  cat > "$COMPOSE_FILE" <<EOF
services:
  ${APP_NAME}-${MODE:-app}:
    build:
      context: .
    container_name: ${APP_NAME}-${MODE:-app}
    restart: unless-stopped
    ports:
      - "${PORT}:3000"
EOF

  echo "[deploy] $COMPOSE_FILE generated."
else
  echo "[deploy] Existing $COMPOSE_FILE found – using it."
fi

# 5) Запуск docker compose
echo "[deploy] Running: docker compose -f $COMPOSE_FILE up -d --build"
docker compose -f "$COMPOSE_FILE" up -d --build

echo "[deploy] Done."
