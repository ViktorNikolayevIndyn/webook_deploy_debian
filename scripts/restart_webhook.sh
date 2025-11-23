#!/bin/bash
set -e

SERVICE_NAME="webhook-deploy.service"

echo "=== restart_webhook.sh ==="

# Проверка systemctl
if ! command -v systemctl >/dev/null 2>&1; then
  echo "[restart] systemctl not found. This script requires systemd."
  exit 1
fi

echo "[restart] Restarting ${SERVICE_NAME}..."
systemctl daemon-reload || true
systemctl restart "${SERVICE_NAME}"

echo "[restart] Status:"
systemctl status "${SERVICE_NAME}" --no-pager -l | sed -n '1,15p'

echo
echo "[restart] Last 30 log lines:"
journalctl -u "${SERVICE_NAME}" -n 30 --no-pager

echo
echo "=== restart_webhook.sh finished ==="
