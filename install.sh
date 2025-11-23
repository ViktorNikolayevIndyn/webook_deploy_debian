#!/bin/bash
set -e

echo "=== install.sh ==="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"

echo "[install] ROOT_DIR   = $ROOT_DIR"
echo "[install] SCRIPT_DIR = $SCRIPT_DIR"
echo "[install] CONFIG_DIR = $CONFIG_DIR"
echo

mkdir -p "$CONFIG_DIR"

# 1) Делаем все нужные скрипты исполняемыми
echo "[install] Making scripts executable (if present)..."
for f in \
  env-bootstrap.sh \
  enable_ssh.sh \
  init.sh \
  deploy_config.sh \
  check_env.sh \
  check_install_node.sh \
  setup_webhook_service.sh \
; do
  if [ -f "$SCRIPT_DIR/$f" ]; then
    chmod +x "$SCRIPT_DIR/$f"
    echo "  [OK] $f"
  else
    echo "  [..] $f (not found, skipping)"
  fi
done
echo

# 2) Базовый bootstrap окружения (docker, jq, git и т.п.)
if [ -x "$SCRIPT_DIR/env-bootstrap.sh" ]; then
  read -r -p "[install] Run env-bootstrap.sh (install base packages, docker, etc.)? [Y/n]: " ans_bootstrap
  ans_bootstrap=${ans_bootstrap:-Y}
  if [[ "$ans_bootstrap" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/env-bootstrap.sh"
  else
    echo "[install] Skipping env-bootstrap.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/env-bootstrap.sh not found or not executable. Skipping env bootstrap."
fi
echo

# 3) SSH + webuser
if [ -x "$SCRIPT_DIR/enable_ssh.sh" ]; then
  read -r -p "[install] Run enable_ssh.sh (create webuser, enable SSH)? [Y/n]: " ans_ssh
  ans_ssh=${ans_ssh:-Y}
  if [[ "$ans_ssh" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/enable_ssh.sh"
  else
    echo "[install] Skipping enable_ssh.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/enable_ssh.sh not found or not executable. Skipping SSH setup."
fi
echo

# 4) Конфиг проектов + вебхука (projects.json)
if [ -x "$SCRIPT_DIR/init.sh" ]; then
  read -r -p "[install] Run init.sh (configure webhook + projects)? [Y/n]: " ans_init
  ans_init=${ans_init:-Y}
  if [[ "$ans_init" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/init.sh"
  else
    echo "[install] Skipping init.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/init.sh not found or not executable. Skipping init.sh."
fi
echo

# 5) Node.js для webhook.js (если есть check_install_node.sh)
if [ -x "$SCRIPT_DIR/check_install_node.sh" ]; then
  read -r -p "[install] Run check_install_node.sh (install Node.js if missing)? [Y/n]: " ans_node
  ans_node=${ans_node:-Y}
  if [[ "$ans_node" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/check_install_node.sh"
  else
    echo "[install] Skipping check_install_node.sh by user choice."
  fi
else
  echo "[install] NOTE: check_install_node.sh not found – assuming Node.js is managed manually."
fi
echo

echo "[install] Base installation phase finished."
echo "         Config dir: $CONFIG_DIR"
echo "         You can inspect $CONFIG_DIR/projects.json if needed."
echo

# 6) Деплой проектов + (по желанию) старт webhook.js (через deploy_config.sh)
if [ -x "$SCRIPT_DIR/deploy_config.sh" ]; then
  read -r -p "[install] Run deploy_config.sh now (deploy projects & optionally start webhook.js)? [Y/n]: " ans_deploy
  ans_deploy=${ans_deploy:-Y}
  if [[ "$ans_deploy" =~ ^[Yy]$ ]]; then
    echo "[install] Starting deploy_config.sh..."
    "$SCRIPT_DIR/deploy_config.sh"
  else
    echo "[install] Skipping deploy_config.sh by user choice."
  fi
else
  echo "[install] NOTE: $SCRIPT_DIR/deploy_config.sh not found yet."
  echo "       Once you add it, you can run: $SCRIPT_DIR/deploy_config.sh"
fi
echo

# 7) Настройка systemd-сервиса для вебхука (webhook-deploy.service)
if [ -x "$SCRIPT_DIR/setup_webhook_service.sh" ]; then
  read -r -p "[install] Create & enable systemd service for webhook (webhook-deploy.service)? [Y/n]: " ans_wh
  ans_wh=${ans_wh:-Y}
  if [[ "$ans_wh" =~ ^[Yy]$ ]]; then
    echo "[install] Running setup_webhook_service.sh..."
    "$SCRIPT_DIR/setup_webhook_service.sh"
  else
    echo "[install] Skipping webhook systemd setup by user choice."
  fi
else
  echo "[install] NOTE: $SCRIPT_DIR/setup_webhook_service.sh not found – no systemd service created."
fi

echo
echo "=== install.sh finished ==="
