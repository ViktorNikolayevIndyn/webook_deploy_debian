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
