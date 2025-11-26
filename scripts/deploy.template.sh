#!/bin/bash
set -e

MODE="$1"
WORKDIR="$(pwd)"

echo "[deploy] Working dir: $WORKDIR"
echo "[deploy] Mode: ${MODE:-none}"

# 1) git pull с проверкой изменений
if [ -d ".git" ]; then
  echo "[deploy] Checking for changes..."
  
  # Сохраняем текущий commit
  BEFORE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  
  echo "[deploy] Current commit: $BEFORE_COMMIT"
  echo "[deploy] Running git fetch..."
  git fetch --all
  
  # Новый commit на remote
  REMOTE_COMMIT=$(git rev-parse @{u} 2>/dev/null || echo "unknown")
  echo "[deploy] Remote commit: $REMOTE_COMMIT"
  
  if [ "$BEFORE_COMMIT" = "$REMOTE_COMMIT" ]; then
    echo "[deploy] ✓ No changes detected - skipping deployment"
    exit 0
  fi
  
  echo "[deploy] Changes detected - pulling..."
  git pull --ff-only || {
    echo "[deploy] WARNING: git pull failed (non-fast-forward or other issue)."
    exit 1
  }
  
  AFTER_COMMIT=$(git rev-parse HEAD)
  echo "[deploy] Updated to: $AFTER_COMMIT"
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

# 5) Умный деплой - build только если нужно
echo "[deploy] Checking if rebuild is needed..."

# Проверяем, изменились ли критичные файлы
NEEDS_BUILD=0

# Если есть git, проверяем измененные файлы
if [ -d ".git" ] && [ -n "$BEFORE_COMMIT" ] && [ -n "$AFTER_COMMIT" ]; then
  CHANGED_FILES=$(git diff --name-only "$BEFORE_COMMIT" "$AFTER_COMMIT" || echo "")
  
  echo "[deploy] Changed files:"
  echo "$CHANGED_FILES" | sed 's/^/  - /'
  
  # Критичные файлы, требующие rebuild
  if echo "$CHANGED_FILES" | grep -qE '^(package.*\.json|Dockerfile|.*\.lock|tsconfig\.json|next\.config\.js)'; then
    echo "[deploy] ⚠ Critical files changed (package.json, Dockerfile, etc.) - full rebuild needed"
    NEEDS_BUILD=1
  else
    echo "[deploy] ✓ Only source files changed - trying hot restart without rebuild"
    NEEDS_BUILD=0
  fi
else
  # Если нет git или это первый запуск - делаем build
  NEEDS_BUILD=1
fi

if [ "$NEEDS_BUILD" -eq 1 ]; then
  echo "[deploy] Running FULL BUILD: docker compose -f $COMPOSE_FILE build $SERVICE_NAME"
  docker compose -f "$COMPOSE_FILE" build "${APP_NAME}-${MODE:-app}"
  
  echo "[deploy] Starting containers: docker compose -f $COMPOSE_FILE up -d"
  docker compose -f "$COMPOSE_FILE" up -d "${APP_NAME}-${MODE:-app}"
else
  # Быстрый рестарт без build (только для изменений кода)
  echo "[deploy] Running QUICK RESTART: docker compose -f $COMPOSE_FILE restart"
  docker compose -f "$COMPOSE_FILE" restart "${APP_NAME}-${MODE:-app}"
  
  # Для Next.js / hot reload - просто обновляем файлы внутри контейнера
  if docker compose -f "$COMPOSE_FILE" ps "${APP_NAME}-${MODE:-app}" | grep -q "Up"; then
    echo "[deploy] ✓ Container restarted - changes will be hot-reloaded (if supported)"
  fi
fi

echo "[deploy] Done in $(($SECONDS))s"
