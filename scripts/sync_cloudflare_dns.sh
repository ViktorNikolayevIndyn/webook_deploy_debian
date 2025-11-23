#!/bin/bash
set -e

echo "=== install.sh ==="

if [ "$EUID" -ne 0 ]; then
  echo "[install] This script must be run as root."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"

echo "[install] ROOT_DIR   = $ROOT_DIR"
echo "[install] SCRIPT_DIR = $SCRIPT_DIR"
echo "[install] CONFIG_DIR = $CONFIG_DIR"
echo

mkdir -p "$CONFIG_DIR"

ask_yes_no_default_yes() {
  local msg="$1"
  local ans
  read -r -p "$msg [Y/n]: " ans
  ans="${ans:-Y}"
  case "$ans" in
    n|N) return 1 ;;
    *)   return 0 ;;
  esac
}

ask_yes_no_default_no() {
  local msg="$1"
  local ans
  read -r -p "$msg [y/N]: " ans
  ans="${ans:-N}"
  case "$ans" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

if [ -d "$SCRIPT_DIR" ]; then
  echo "[install] Making all scripts in $SCRIPT_DIR executable..."
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} \;
  echo "[install] chmod +x done."
  echo
fi

# 1) env-bootstrap (умgebung)
if [ -x "$SCRIPT_DIR/env-bootstrap.sh" ]; then
  if ask_yes_no_default_yes "[install] Run env-bootstrap.sh (packages, Docker install)?"; then
    "$SCRIPT_DIR/env-bootstrap.sh"
  else
    echo "[install] Skipping env-bootstrap.sh."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/env-bootstrap.sh not found or not executable. Skipping env bootstrap."
fi
echo

# 2) enable_ssh
if [ -x "$SCRIPT_DIR/enable_ssh.sh" ]; then
  if ask_yes_no_default_yes "[install] Run enable_ssh.sh (SSH user / sudo / docker group)?"; then
    "$SCRIPT_DIR/enable_ssh.sh"
  else
    echo "[install] Skipping enable_ssh.sh."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/enable_ssh.sh not found or not executable. Skipping SSH setup."
fi
echo

# 3) init.sh (webhook + projects.json)
if [ -x "$SCRIPT_DIR/init.sh" ]; then
  if ask_yes_no_default_yes "[install] Run init.sh (configure webhook + projects)?"; then
    "$SCRIPT_DIR/init.sh"
  else
    echo "[install] Skipping init.sh."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/init.sh not found or not executable. Skipping init.sh."
fi
echo

echo "[install] Base installation phase finished."
echo "         Config dir: $CONFIG_DIR"
echo "         You can inspect config/projects.json if needed."
echo

# 4) deploy_config.sh (деплой проектов + запуск webhook.js)
if [ -x "$SCRIPT_DIR/deploy_config.sh" ]; then
  if ask_yes_no_default_yes "[install] Run deploy_config.sh now (deploy projects & start webhook)?"; then
    echo "[install] Starting deploy_config.sh..."
    "$SCRIPT_DIR/deploy_config.sh"
  else
    echo "[install] Skipping deploy_config.sh."
  fi
else
  echo "[install] NOTE: scripts/deploy_config.sh not found yet."
  echo "       Once you add it, you can run: $SCRIPT_DIR/deploy_config.sh"
fi

echo

# 5) sync_cloudflare.sh (туннели + systemd)
if [ -x "$SCRIPT_DIR/sync_cloudflare.sh" ]; then
  if ask_yes_no_default_yes "[install] Run sync_cloudflare.sh now (tunnels + systemd units)?"; then
    echo "[install] Starting sync_cloudflare.sh..."
    "$SCRIPT_DIR/sync_cloudflare.sh"
  else
    echo "[install] Skipping sync_cloudflare.sh."
  fi
else
  echo "[install] NOTE: scripts/sync_cloudflare.sh not found. Cloudflare tunnels not auto-synced."
fi

echo

# 6) sync_cloudflare_dns.sh (DNS маршруты)
if [ -x "$SCRIPT_DIR/sync_cloudflare_dns.sh" ]; then
  if ask_yes_no_default_yes "[install] Run sync_cloudflare_dns.sh now (Cloudflare DNS routes)?"; then
    echo "[install] Starting sync_cloudflare_dns.sh..."
    "$SCRIPT_DIR/sync_cloudflare_dns.sh"
  else
    echo "[install] Skipping sync_cloudflare_dns.sh."
  fi
else
  echo "[install] NOTE: scripts/sync_cloudflare_dns.sh not found. DNS routes not auto-synced."
fi

echo
echo "[install] Final environment check (check_env.sh)..."
if [ -x "$SCRIPT_DIR/check_env.sh" ]; then
  "$SCRIPT_DIR/check_env.sh"
else
  echo "[install] WARNING: check_env.sh not found."
fi

echo
echo "=== install.sh finished ==="
