#!/bin/bash
set -e

echo "=== setup_webhook_service.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_FILE="/etc/systemd/system/webhook-deploy.service"

echo "[webhook-setup] ROOT_DIR   = $ROOT_DIR"
echo "[webhook-setup] SCRIPT_DIR = $SCRIPT_DIR"
echo "[webhook-setup] SERVICE    = $SERVICE_FILE"
echo

# 1) Проверяем наличие webhook.js
if [ ! -f "$ROOT_DIR/webhook.js" ]; then
  echo "[webhook-setup] ERROR: webhook.js not found at $ROOT_DIR/webhook.js"
  echo "[webhook-setup]        Cannot create working service without webhook.js."
  exit 1
fi

# 2) Проверяем node
if ! command -v node >/dev/null 2>&1; then
  echo "[webhook-setup] ERROR: 'node' binary not found in PATH."
  echo "[webhook-setup]        Install Node.js first (e.g. via check_install_node.sh or apt)."
  exit 1
fi

NODE_BIN="$(command -v node)"
echo "[webhook-setup] Using node binary: $NODE_BIN"
echo

# 3) Определяем пользователя для сервиса (предпочтительно webuser)
SERVICE_USER="root"
SERVICE_GROUP="root"

if id webuser >/dev/null 2>&1; then
  SERVICE_USER="webuser"
  SERVICE_GROUP="webuser"
fi

echo "[webhook-setup] Service will run as: ${SERVICE_USER}:${SERVICE_GROUP}"
echo

# 3.5) Проверяем права на ROOT_DIR, если запускаем под webuser
if [ "$SERVICE_USER" != "root" ]; then
  echo "[webhook-setup] Checking ownership of $ROOT_DIR..."
  CURRENT_OWNER=$(stat -c '%U' "$ROOT_DIR" 2>/dev/null || echo "unknown")
  
  if [ "$CURRENT_OWNER" != "$SERVICE_USER" ]; then
    echo "[webhook-setup] WARNING: $ROOT_DIR is owned by '$CURRENT_OWNER', but service runs as '$SERVICE_USER'"
    echo "[webhook-setup]          Changing ownership to ${SERVICE_USER}:${SERVICE_GROUP}..."
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "$ROOT_DIR" || {
      echo "[webhook-setup] ERROR: Failed to chown $ROOT_DIR"
      echo "[webhook-setup]        Service may fail to start. Fix manually: chown -R $SERVICE_USER:$SERVICE_GROUP $ROOT_DIR"
    }
  else
    echo "[webhook-setup] Ownership OK: $ROOT_DIR is owned by $SERVICE_USER"
  fi
fi
echo

# 4) Создаём/обновляем unit-файл systemd
echo "[webhook-setup] Writing systemd unit to $SERVICE_FILE ..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GitHub Webhook Deploy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR
ExecStart=$NODE_BIN $ROOT_DIR/webhook.js
Restart=always
RestartSec=5
User=$SERVICE_USER
Group=$SERVICE_GROUP
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

echo "[webhook-setup] Unit file written."

# 4.5) Настройка GitHub token для статусов
CONFIG_FILE="$ROOT_DIR/config/projects.json"
SECRETS_DIR="$ROOT_DIR/secrets"
TOKEN_FILE="$SECRETS_DIR/github_token"

echo
echo "[webhook-setup] GitHub Status API Setup (optional)"
echo "[webhook-setup] ─────────────────────────────────────"

# Проверяем есть ли непустой токен в config или файле
EXISTING_TOKEN=""
TOKEN_CONFIGURED=0

if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
  EXISTING_TOKEN=$(jq -r '.webhook.githubToken // empty' "$CONFIG_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "null" ] && [ "$EXISTING_TOKEN" != '""' ]; then
    TOKEN_CONFIGURED=1
  fi
fi

if [ $TOKEN_CONFIGURED -eq 0 ] && [ -f "$TOKEN_FILE" ]; then
  EXISTING_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$EXISTING_TOKEN" ]; then
    TOKEN_CONFIGURED=1
  fi
fi

if [ $TOKEN_CONFIGURED -eq 1 ]; then
  echo "[webhook-setup] ✓ GitHub token already configured"
else
  echo "[webhook-setup] To enable GitHub commit status updates, you need a Personal Access Token."
  echo "[webhook-setup] Token scope required: repo:status (or full repo)"
  echo "[webhook-setup] Create token at: https://github.com/settings/tokens"
  echo
  
  TOKEN_VALID=0
  while [ $TOKEN_VALID -eq 0 ]; do
    read -r -p "[webhook-setup] Enter GitHub token (or press Enter to skip): " GITHUB_TOKEN
    
    if [ -z "$GITHUB_TOKEN" ]; then
      echo "[webhook-setup] ℹ Skipped. Webhook will work without GitHub status updates."
      break
    fi
    
    # Валидация токена через GitHub API
    echo "[webhook-setup] Validating token..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "User-Agent: webhook-deploy-setup" \
      https://api.github.com/user 2>/dev/null)
    
    if [ "$HTTP_CODE" = "200" ]; then
      echo "[webhook-setup] ✓ Token is valid"
      
      # Сохраняем в projects.json если есть jq
      if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        TMP_FILE=$(mktemp)
        jq --arg token "$GITHUB_TOKEN" '.webhook.githubToken = $token' "$CONFIG_FILE" > "$TMP_FILE"
        mv "$TMP_FILE" "$CONFIG_FILE"
        chmod 640 "$CONFIG_FILE"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$CONFIG_FILE"
        echo "[webhook-setup] ✓ Token saved to: $CONFIG_FILE"
      else
        # Fallback: сохраняем в файл
        mkdir -p "$SECRETS_DIR"
        echo "$GITHUB_TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$TOKEN_FILE"
        echo "[webhook-setup] ✓ Token saved to: $TOKEN_FILE"
      fi
      
      TOKEN_VALID=1
    elif [ "$HTTP_CODE" = "401" ]; then
      echo "[webhook-setup] ✗ Invalid token (401 Unauthorized)"
      echo "[webhook-setup]   Please check your token and try again."
      echo
    elif [ "$HTTP_CODE" = "000" ] || [ -z "$HTTP_CODE" ]; then
      echo "[webhook-setup] ✗ Cannot connect to GitHub API"
      echo "[webhook-setup]   Check your internet connection."
      echo
      read -r -p "[webhook-setup] Retry? [Y/n]: " RETRY
      RETRY=${RETRY:-Y}
      if [[ ! "$RETRY" =~ ^[Yy]$ ]]; then
        echo "[webhook-setup] ℹ Skipped. Webhook will work without GitHub status updates."
        break
      fi
    else
      echo "[webhook-setup] ✗ Unexpected response: HTTP $HTTP_CODE"
      echo "[webhook-setup]   Token may be valid but permissions are wrong."
      echo
      read -r -p "[webhook-setup] Save anyway? [y/N]: " SAVE_ANYWAY
      SAVE_ANYWAY=${SAVE_ANYWAY:-N}
      if [[ "$SAVE_ANYWAY" =~ ^[Yy]$ ]]; then
        mkdir -p "$SECRETS_DIR"
        echo "$GITHUB_TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$TOKEN_FILE"
        echo "[webhook-setup] ⚠ Token saved (not validated): $TOKEN_FILE"
        TOKEN_VALID=1
      else
        echo "[webhook-setup] ℹ Skipped. Webhook will work without GitHub status updates."
        break
      fi
    fi
  done
fi

echo

# 5) Перезагрузка systemd + включение + запуск
echo "[webhook-setup] Reloading systemd daemon..."
systemctl daemon-reload

echo "[webhook-setup] Enabling webhook-deploy.service..."
systemctl enable webhook-deploy.service

echo "[webhook-setup] Restarting webhook-deploy.service..."
systemctl restart webhook-deploy.service || true

echo
echo "[webhook-setup] Service status (short):"
systemctl status webhook-deploy.service --no-pager --lines=5 || true

echo
echo "[webhook-setup] Listening TCP ports (filter 4000):"
ss -tlnp 2>/dev/null | awk 'NR==1 || /:4000 /'

echo
echo "=== setup_webhook_service.sh finished ==="
