#!/bin/bash
set -e

# === install.sh ===
# Основной установщик:
#  - делает все .sh в scripts/ исполняемыми
#  - готовит окружение (env-bootstrap.sh)
#  - настраивает SSH (enable_ssh.sh)
#  - создаёт/обновляет config/projects.json (init.sh)
#  - при желании сразу запускает deploy_config.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"

echo "=== install.sh ==="
echo "[install] ROOT_DIR   = $ROOT_DIR"
echo "[install] SCRIPT_DIR = $SCRIPT_DIR"
echo "[install] CONFIG_DIR = $CONFIG_DIR"
echo

mkdir -p "$CONFIG_DIR"

# 0) Сделать все .sh в scripts/ исполняемыми (если папка существует)
if [ -d "$SCRIPT_DIR" ]; then
  echo "[install] Making all *.sh in $SCRIPT_DIR executable..."
  chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
else
  echo "[install] NOTE: scripts directory '$SCRIPT_DIR' does not exist yet."
fi

echo

# 1) Бутстрап окружения
if [ -x "$SCRIPT_DIR/env-bootstrap.sh" ]; then
  echo "[install] Running env-bootstrap.sh (environment bootstrap)..."
  "$SCRIPT_DIR/env-bootstrap.sh"
else
  echo "[install] WARNING: $SCRIPT_DIR/env-bootstrap.sh not found or not executable. Skipping env bootstrap."
fi

echo

# 2) SSH-setup (по желанию)
if [ -x "$SCRIPT_DIR/enable_ssh.sh" ]; then
  read -rp "[install] Run SSH setup (enable_ssh.sh)? [Y/n]: " ssh_ans
  ssh_ans="${ssh_ans:-Y}"
  if [[ "$ssh_ans" =~ ^[Yy]$ ]]; then
    echo "[install] Running enable_ssh.sh..."
    "$SCRIPT_DIR/enable_ssh.sh"
  else
    echo "[install] SSH setup skipped by user."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/enable_ssh.sh not found or not executable. Skipping SSH setup."
fi

echo

# 3) Инициализация/обновление конфигурации проектов
if [ -x "$SCRIPT_DIR/init.sh" ]; then
  echo "[install] Running init.sh (project / webhook config)..."
  "$SCRIPT_DIR/init.sh"
else
  echo "[install] WARNING: $SCRIPT_DIR/init.sh not found or not executable. Skipping init.sh."
fi

echo
echo "[install] Base installation phase finished."
echo "         Config dir: $CONFIG_DIR"
echo "         You can inspect config/projects.json if needed."
echo

# 4) Предложить сразу выполнить deploy_config.sh
if [ -x "$SCRIPT_DIR/deploy_config.sh" ]; then
  read -rp "[install] Run deploy_config.sh now (deploy projects & start webhook)? [Y/n]: " dep_ans
  dep_ans="${dep_ans:-Y}"
  if [[ "$dep_ans" =~ ^[Yy]$ ]]; then
    echo "[install] Starting deploy_config.sh..."
    "$SCRIPT_DIR/deploy_config.sh"
  else
    echo "[install] You can run it later with: $SCRIPT_DIR/deploy_config.sh"
  fi
else
  echo "[install] NOTE: scripts/deploy_config.sh not found yet."
  echo "       Once you add it, you can run: $SCRIPT_DIR/deploy_config.sh"
fi

echo
echo "=== install.sh finished ==="
