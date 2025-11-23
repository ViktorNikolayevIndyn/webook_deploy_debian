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

# --- ensure all scripts are executable ---
echo "[install] Ensuring scripts are executable..."
if [ -d "$SCRIPT_DIR" ]; then
  chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
fi
echo

# --- env-bootstrap ---
if [ -x "$SCRIPT_DIR/env-bootstrap.sh" ]; then
  echo "[install] Running env-bootstrap.sh ..."
  "$SCRIPT_DIR/env-bootstrap.sh"
else
  echo "[install] WARNING: $SCRIPT_DIR/env-bootstrap.sh not found or not executable. Skipping env bootstrap."
fi
echo

# --- enable_ssh ---
if [ -x "$SCRIPT_DIR/enable_ssh.sh" ]; then
  if ask_yes_no_default_yes "[install] Run enable_ssh.sh now (SSH user/sudo/docker groups)?"; then
    "$SCRIPT_DIR/enable_ssh.sh"
  else
    echo "[install] Skipping enable_ssh.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/enable_ssh.sh not found or not executable. Skipping SSH setup."
fi
echo

# --- init.sh (webhook + projects.json) ---
if [ -x "$SCRIPT_DIR/init.sh" ]; then
  if ask_yes_no_default_yes "[install] Run init.sh now (webhook + projects config)?"; then
    "$SCRIPT_DIR/init.sh"
  else
    echo "[install] Skipping init.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/init.sh not found or not executable. Skipping init.sh."
fi
echo

echo "[install] Base installation phase finished."
echo "         Config dir: $CONFIG_DIR"
echo "         You can inspect config/projects.json if needed."
echo

# --- deploy_config.sh (deploy projects + webhook.js + systemd unit) ---
if [ -x "$SCRIPT_DIR/deploy_config.sh" ]; then
  if ask_yes_no_default_yes "[install] Run deploy_config.sh now (deploy projects & start webhook)?"; then
    "$SCRIPT_DIR/deploy_config.sh"
  else
    echo "[install] Skipping deploy_config.sh by user choice."
  fi
else
  echo "[install] NOTE: $SCRIPT_DIR/deploy_config.sh not found yet."
  echo "       Once you add it, you can run: $SCRIPT_DIR/deploy_config.sh"
fi
echo

# --- Cloudflare: register tunnels (первая автоматизация Cloudflare) ---
if command -v cloudflared >/dev/null 2>&1; then
  if [ -x "$SCRIPT_DIR/register_cloudflare.sh" ]; then
    if ask_yes_no_default_yes "[install] Run register_cloudflare.sh now (Cloudflare tunnel registration)?"; then
      "$SCRIPT_DIR/register_cloudflare.sh"
    else
      echo "[install] Skipping register_cloudflare.sh by user choice."
    fi
  else
    echo "[install] NOTE: $SCRIPT_DIR/register_cloudflare.sh not found. Cloudflare tunnel registration is manual for now."
  fi
else
  echo "[install] NOTE: cloudflared not installed or not in PATH – Cloudflare automation skipped."
fi
echo

# --- Cloudflare: sync config (services для проектов + webhook) ---
if command -v cloudflared >/dev/null 2>&1; then
  if [ -x "$SCRIPT_DIR/sync_cloudflare.sh" ]; then
    if ask_yes_no_default_yes "[install] Run sync_cloudflare.sh now (generate tunnel configs)?"; then
      "$SCRIPT_DIR/sync_cloudflare.sh"
    else
      echo "[install] Skipping sync_cloudflare.sh by user choice."
    fi
  else
    echo "[install] NOTE: $SCRIPT_DIR/sync_cloudflare.sh not found. You can still manage tunnels manually."
  fi
fi
echo

# --- Final status: check_env.sh ---
if [ -x "$SCRIPT_DIR/check_env.sh" ]; then
  echo "[install] Running check_env.sh for final status..."
  "$SCRIPT_DIR/check_env.sh"
else
  echo "[install] NOTE: $SCRIPT_DIR/check_env.sh not found. No final summary."
fi

echo
echo "=== install.sh finished ==="
