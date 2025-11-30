#!/bin/bash
set -e

WORKDIR="${WORKDIR:-$(pwd)}"
MODE="${1:-prod}"
FORCE_RECREATE="${2:-false}"

echo "[deploy] Working dir: $WORKDIR"
echo "[deploy] Mode: $MODE"
if [[ "$FORCE_RECREATE" == "force" ]]; then
  echo "[deploy] Force mode: will recreate Dockerfile and docker-compose.yml"
fi

cd "$WORKDIR"

# 1) Git pull
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
    # Skip deployment only if not force mode
    if [[ "$FORCE_RECREATE" != "force" ]]; then
      if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[deploy] ✓ No changes detected and container exists - skipping deployment"
        exit 0
      else
        echo "[deploy] ⚠ No changes but container missing - will deploy"
      fi
    else
      echo "[deploy] Force mode enabled - will rebuild even without git changes"
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
PORT_DEFAULT=8000

# 2) Определяем порт
case "$MODE" in
  dev|development)
    PORT="${PORT:-$PORT_DEFAULT}"
    ;;
  prod|production)
    PORT="${PORT:-$((PORT_DEFAULT + 1))}"
    ;;
  *)
    PORT="${PORT:-$PORT_DEFAULT}"
    ;;
esac

echo "[deploy] Using APP_NAME=$APP_NAME, PORT=$PORT"

# 3) Создаём Dockerfile для PHP/Lumen
if [ ! -f "Dockerfile" ] || [[ "$FORCE_RECREATE" == "force" ]]; then
  if [ -f "Dockerfile" ] && [[ "$FORCE_RECREATE" == "force" ]]; then
    echo "[deploy] Force mode: removing existing Dockerfile"
    rm -f Dockerfile
  fi
  echo "[deploy] Generating Dockerfile for PHP Lumen (mode: $MODE)"

  cat > Dockerfile <<'EOF'
FROM php:8.2-fpm-alpine

WORKDIR /app

# Install system dependencies
RUN apk add --no-cache \
    nginx \
    supervisor \
    bash \
    git \
    curl \
    zip \
    unzip

# Install PHP extensions
RUN docker-php-ext-install pdo pdo_mysql

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Copy application files
COPY . .

# Create necessary directories first
RUN mkdir -p storage/logs storage/framework/cache storage/framework/sessions storage/framework/views \
    && chmod -R 775 storage \
    && if [ -d bootstrap/cache ]; then chmod -R 775 bootstrap/cache; fi

# Install dependencies
RUN if [ -f composer.json ]; then \
        composer install --no-interaction --optimize-autoloader --no-dev || composer install --no-interaction; \
    else \
        echo "No composer.json found"; \
    fi

# Configure nginx for Lumen/Laravel
RUN echo "server {" > /etc/nginx/http.d/default.conf && \
    echo "    listen 80;" >> /etc/nginx/http.d/default.conf && \
    echo "    root /app/public;" >> /etc/nginx/http.d/default.conf && \
    echo "    index index.php;" >> /etc/nginx/http.d/default.conf && \
    echo "" >> /etc/nginx/http.d/default.conf && \
    echo "    location / {" >> /etc/nginx/http.d/default.conf && \
    echo "        try_files \$uri \$uri/ /index.php?\$query_string;" >> /etc/nginx/http.d/default.conf && \
    echo "    }" >> /etc/nginx/http.d/default.conf && \
    echo "" >> /etc/nginx/http.d/default.conf && \
    echo "    location ~ \.php\$ {" >> /etc/nginx/http.d/default.conf && \
    echo "        fastcgi_pass 127.0.0.1:9000;" >> /etc/nginx/http.d/default.conf && \
    echo "        fastcgi_index index.php;" >> /etc/nginx/http.d/default.conf && \
    echo "        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;" >> /etc/nginx/http.d/default.conf && \
    echo "        include fastcgi_params;" >> /etc/nginx/http.d/default.conf && \
    echo "    }" >> /etc/nginx/http.d/default.conf && \
    echo "}" >> /etc/nginx/http.d/default.conf

# Configure supervisor to run nginx and php-fpm
RUN echo "[supervisord]" > /etc/supervisord.conf && \
    echo "nodaemon=true" >> /etc/supervisord.conf && \
    echo "user=root" >> /etc/supervisord.conf && \
    echo "" >> /etc/supervisord.conf && \
    echo "[program:php-fpm]" >> /etc/supervisord.conf && \
    echo "command=php-fpm -F" >> /etc/supervisord.conf && \
    echo "stdout_logfile=/dev/stdout" >> /etc/supervisord.conf && \
    echo "stdout_logfile_maxbytes=0" >> /etc/supervisord.conf && \
    echo "stderr_logfile=/dev/stderr" >> /etc/supervisord.conf && \
    echo "stderr_logfile_maxbytes=0" >> /etc/supervisord.conf && \
    echo "autorestart=true" >> /etc/supervisord.conf && \
    echo "" >> /etc/supervisord.conf && \
    echo "[program:nginx]" >> /etc/supervisord.conf && \
    echo "command=nginx -g \"daemon off;\"" >> /etc/supervisord.conf && \
    echo "stdout_logfile=/dev/stdout" >> /etc/supervisord.conf && \
    echo "stdout_logfile_maxbytes=0" >> /etc/supervisord.conf && \
    echo "stderr_logfile=/dev/stderr" >> /etc/supervisord.conf && \
    echo "stderr_logfile_maxbytes=0" >> /etc/supervisord.conf && \
    echo "autorestart=true" >> /etc/supervisord.conf

EXPOSE 80

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

  echo "[deploy] Dockerfile created."
fi

# 4) Создаём docker-compose.yml
if [ ! -f "$COMPOSE_FILE" ] || [[ "$FORCE_RECREATE" == "force" ]]; then
  if [ -f "$COMPOSE_FILE" ] && [[ "$FORCE_RECREATE" == "force" ]]; then
    echo "[deploy] Force mode: removing existing $COMPOSE_FILE"
    rm -f "$COMPOSE_FILE"
  fi
  echo "[deploy] Generating docker-compose.yml for mode: $MODE"

  if [ "$MODE" = "dev" ]; then
    # Dev mode с volumes для hot reload
    cat > "$COMPOSE_FILE" <<EOF
services:
  ${APP_NAME}-${MODE:-app}:
    build:
      context: .
    container_name: ${APP_NAME}-${MODE:-app}
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    volumes:
      - ./app:/app/app:ro
      - ./routes:/app/routes:ro
      - ./resources:/app/resources:ro
    environment:
      - APP_ENV=local
      - APP_DEBUG=true
EOF
  else
    # Production mode без volumes
    cat > "$COMPOSE_FILE" <<EOF
services:
  ${APP_NAME}-${MODE:-app}:
    build:
      context: .
    container_name: ${APP_NAME}-${MODE:-app}
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    environment:
      - APP_ENV=production
      - APP_DEBUG=false
EOF
  fi

  echo "[deploy] $COMPOSE_FILE generated."
else
  echo "[deploy] Existing $COMPOSE_FILE found – using it."
fi

# 5) Умный деплой - build при изменениях
echo "[deploy] Checking if rebuild is needed..."

NEEDS_BUILD=0
USE_VOLUMES=0
CONTAINER_NAME="${APP_NAME}-${MODE:-app}"

# Проверяем существует ли контейнер
CONTAINER_EXISTS=0
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  CONTAINER_EXISTS=1
fi

# Если контейнера нет - всегда build
if [ "$CONTAINER_EXISTS" -eq 0 ]; then
  echo "[deploy] ⚠ Container not found - first deployment, building..."
  NEEDS_BUILD=1
else
  # Проверяем используются ли volumes (dev режим)
  if [ -f "$COMPOSE_FILE" ] && grep -q "volumes:" "$COMPOSE_FILE"; then
    USE_VOLUMES=1
    echo "[deploy] Using volumes - changes sync automatically"
  fi

  # Если есть git, проверяем измененные файлы
  if [ -d ".git" ] && [ -n "$BEFORE_COMMIT" ] && [ -n "$AFTER_COMMIT" ]; then
    CHANGED_FILES=$(git diff --name-only "$BEFORE_COMMIT" "$AFTER_COMMIT" || echo "")
    
    if [ -n "$CHANGED_FILES" ]; then
      echo "[deploy] Changed files:"
      echo "$CHANGED_FILES" | sed 's/^/  - /'
      
      # Для dev с volumes - только restart
      if [ "$USE_VOLUMES" -eq 1 ]; then
        if echo "$CHANGED_FILES" | grep -qE '^(composer\.(json|lock)|Dockerfile)'; then
          echo "[deploy] ⚠ Critical files changed - rebuild needed"
          NEEDS_BUILD=1
        else
          echo "[deploy] ✓ Source files changed - volumes will sync, restart only"
          NEEDS_BUILD=0
        fi
      else
        # Для production - всегда rebuild
        echo "[deploy] ⚠ Production mode - rebuild needed"
        NEEDS_BUILD=1
      fi
    fi
  fi
fi

# Force mode принудительный rebuild
if [[ "$FORCE_RECREATE" == "force" ]]; then
  echo "[deploy] Force mode: rebuilding..."
  NEEDS_BUILD=1
fi

# 6) Build/Restart
if [ "$NEEDS_BUILD" -eq 1 ]; then
  echo "[deploy] Building and starting containers..."
  docker compose up -d --build
else
  echo "[deploy] Restarting container without rebuild..."
  docker compose restart
fi

echo "[deploy] Deployment complete!"
echo "[deploy] Container: $CONTAINER_NAME"
echo "[deploy] Port: $PORT"
echo "[deploy] Logs: docker logs $CONTAINER_NAME -f"
