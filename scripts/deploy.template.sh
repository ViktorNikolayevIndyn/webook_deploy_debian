#!/bin/bash
set -e

MODE="$1"
FORCE_RECREATE="${2:-false}"
WORKDIR="$(pwd)"

echo "[deploy] Working dir: $WORKDIR"
echo "[deploy] Mode: ${MODE:-none}"
if [[ "$FORCE_RECREATE" == "force" ]]; then
  echo "[deploy] Force mode: will recreate Dockerfile and docker-compose.yml"
fi

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
  
  # Check if container exists before skipping deployment
  CONTAINER_NAME="$(basename "$WORKDIR")-${MODE:-app}"
  if [ "$BEFORE_COMMIT" = "$REMOTE_COMMIT" ]; then
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      echo "[deploy] ✓ No changes detected and container exists - skipping deployment"
      exit 0
    else
      echo "[deploy] ⚠ No changes but container missing - will deploy"
    fi
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
if [ ! -f "Dockerfile" ] || [[ "$FORCE_RECREATE" == "force" ]]; then
  if [ -f "Dockerfile" ] && [[ "$FORCE_RECREATE" == "force" ]]; then
    echo "[deploy] Force mode: removing existing Dockerfile"
    rm -f Dockerfile
  fi
  echo "[deploy] Generating Dockerfile for mode: $MODE"

  # Для dev режима - отдельный Dockerfile с next dev
  if [ "$MODE" = "dev" ]; then
    cat > Dockerfile <<'EOF'
FROM node:20-alpine

WORKDIR /app

# Устанавливаем зависимости
COPY package*.json ./
RUN npm ci

# Копируем исходники (volumes will override in compose)
COPY . .

# Dev mode - запускаем next dev
CMD ["npm", "run", "dev"]
EOF
  else
    # Для production - build и start
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
  fi

  echo "[deploy] Dockerfile generated."
else
  echo "[deploy] Existing Dockerfile found – using it."
fi

# 4) Если нет docker-compose.yml – создаём минимальный
if [ ! -f "$COMPOSE_FILE" ] || [[ "$FORCE_RECREATE" == "force" ]]; then
  if [ -f "$COMPOSE_FILE" ] && [[ "$FORCE_RECREATE" == "force" ]]; then
    echo "[deploy] Force mode: removing existing docker-compose.yml"
    rm -f "$COMPOSE_FILE"
  fi
  echo "[deploy] Generating docker-compose.yml for mode: $MODE"

  # Для dev режима - монтируем код как volume для hot reload
  if [ "$MODE" = "dev" ]; then
    cat > "$COMPOSE_FILE" <<EOF
services:
  ${APP_NAME}-${MODE:-app}:
    build:
      context: .
    container_name: ${APP_NAME}-${MODE:-app}
    restart: unless-stopped
    ports:
      - "${PORT}:3000"
    volumes:
      - ./src:/app/src:ro
      - ./public:/app/public:ro
      - ./app:/app/app:ro
    environment:
      - NODE_ENV=development
EOF
  else
    # Для production - обычный build без volumes
    cat > "$COMPOSE_FILE" <<EOF
services:
  ${APP_NAME}-${MODE:-app}:
    build:
      context: .
    container_name: ${APP_NAME}-${MODE:-app}
    restart: unless-stopped
    ports:
      - "${PORT}:3000"
    environment:
      - NODE_ENV=production
EOF
  fi

  echo "[deploy] $COMPOSE_FILE generated."
else
  echo "[deploy] Existing $COMPOSE_FILE found – using it."
fi

# 5) Умный деплой - build при любых изменениях для production
echo "[deploy] Checking if rebuild is needed..."

# Проверяем, изменились ли файлы
NEEDS_BUILD=0
USE_VOLUMES=0
CONTAINER_NAME="${APP_NAME}-${MODE:-app}"

# Проверяем существует ли контейнер
CONTAINER_EXISTS=0
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  CONTAINER_EXISTS=1
fi

# Если контейнера нет - всегда build (первый запуск)
if [ "$CONTAINER_EXISTS" -eq 0 ]; then
  echo "[deploy] ⚠ Container not found - first deployment, building..."
  NEEDS_BUILD=1
else
  # Проверяем используются ли volumes в docker-compose.yml (для dev режима)
  if [ -f "$COMPOSE_FILE" ] && grep -q "volumes:" "$COMPOSE_FILE"; then
    USE_VOLUMES=1
    echo "[deploy] Using volumes - hot reload enabled"
  fi

  # Если есть git, проверяем измененные файлы
  if [ -d ".git" ] && [ -n "$BEFORE_COMMIT" ] && [ -n "$AFTER_COMMIT" ]; then
    CHANGED_FILES=$(git diff --name-only "$BEFORE_COMMIT" "$AFTER_COMMIT" || echo "")
    
    if [ -n "$CHANGED_FILES" ]; then
      echo "[deploy] Changed files:"
      echo "$CHANGED_FILES" | sed 's/^/  - /'
      
      # Для dev режима с volumes - только restart (файлы обновятся через volume mount)
      if [ "$USE_VOLUMES" -eq 1 ]; then
        if echo "$CHANGED_FILES" | grep -qE '^(package.*\.json|Dockerfile|.*\.lock|tsconfig\.json|next\.config\.js|tailwind\.config\.)'; then
          echo "[deploy] ⚠ Critical files changed - rebuild needed even with volumes"
          NEEDS_BUILD=1
        else
          echo "[deploy] ✓ Source files changed - volumes will sync automatically, restart only"
          NEEDS_BUILD=0
        fi
      else
        # Для prod режима без volumes - всегда rebuild (Next.js требует пересборки)
        echo "[deploy] ⚠ Production mode (no volumes) - rebuild required for any changes"
        NEEDS_BUILD=1
      fi
    else
      echo "[deploy] No file changes detected"
    fi
  else
    # Если нет git или это первый запуск - делаем build
    echo "[deploy] First deployment or no git - full build required"
    NEEDS_BUILD=1
  fi
fi

if [ "$NEEDS_BUILD" -eq 1 ]; then
  echo "[deploy] Running FULL BUILD: docker compose -f $COMPOSE_FILE build ${APP_NAME}-${MODE:-app}"
  docker compose -f "$COMPOSE_FILE" build "${APP_NAME}-${MODE:-app}"
  
  echo "[deploy] Recreating containers: docker compose -f $COMPOSE_FILE up -d --force-recreate ${APP_NAME}-${MODE:-app}"
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate "${APP_NAME}-${MODE:-app}"
else
  # Быстрый рестарт без build (только для dev mode с изменениями кода)
  echo "[deploy] Running QUICK RESTART: docker compose -f $COMPOSE_FILE restart ${APP_NAME}-${MODE:-app}"
  docker compose -f "$COMPOSE_FILE" restart "${APP_NAME}-${MODE:-app}"
  
  if docker compose -f "$COMPOSE_FILE" ps "${APP_NAME}-${MODE:-app}" | grep -q "Up"; then
    echo "[deploy] ✓ Container restarted - dev mode hot reload active"
  fi
fi

echo "[deploy] Done in $(($SECONDS))s"
