#!/bin/bash
set -e

echo "=== install.sh ==="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"

echo "[install] ROOT_DIR   = $ROOT_DIR"
echo "[install] SCRIPT_DIR = $SCRIPT_DIR"
echo "[install] CONFIG_DIR = $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
echo

# Все скрипты в scripts делаем исполняемыми
if [ -d "$SCRIPT_DIR" ]; then
  echo "[install] Marking scripts/*.sh as executable..."
  chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
  echo
fi

# --- шаг 1: env-bootstrap ---
if [ -x "$SCRIPT_DIR/env-bootstrap.sh" ]; then
  read -r -p "[install] Run env-bootstrap.sh (apt, docker, tools)? [Y/n]: " ans_env
  ans_env="${ans_env:-Y}"
  if [[ "$ans_env" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/env-bootstrap.sh"
  else
    echo "[install] Skipping env-bootstrap.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/env-bootstrap.sh not found or not executable. Skipping env bootstrap."
fi
echo

# --- шаг 2: enable_ssh ---
if [ -x "$SCRIPT_DIR/enable_ssh.sh" ]; then
  read -r -p "[install] Run enable_ssh.sh (SSH user / sudo / docker group)? [Y/n]: " ans_ssh
  ans_ssh="${ans_ssh:-Y}"
  if [[ "$ans_ssh" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/enable_ssh.sh"
  else
    echo "[install] Skipping enable_ssh.sh by user choice."
  fi
else
  echo "[install] WARNING: $SCRIPT_DIR/enable_ssh.sh not found or not executable. Skipping SSH setup."
fi
echo

# --- шаг 3: init.sh (webhook + projects.json) ---
if [ -x "$SCRIPT_DIR/init.sh" ]; then
  read -r -p "[install] Run init.sh (webhook + projects.json wizard)? [Y/n]: " ans_init
  ans_init="${ans_init:-Y}"
  if [[ "$ans_init" =~ ^[Yy]$ ]]; then
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

# --- шаг 4: deploy_config.sh (деплой проектов + webhook.service) ---
if [ -x "$SCRIPT_DIR/deploy_config.sh" ]; then
  read -r -p "[install] Run deploy_config.sh now (deploy projects & start webhook)? [Y/n]: " ans_deploy
  ans_deploy="${ans_deploy:-Y}"
  if [[ "$ans_deploy" =~ ^[Yy]$ ]]; then
    echo "[install] Starting deploy_config.sh..."
    "$SCRIPT_DIR/deploy_config.sh"
  else
    echo "[install] Skipping deploy_config.sh by user choice."
  fi
else
  echo "[install] NOTE: scripts/deploy_config.sh not found yet."
  echo "       Once you add it, you can run: $SCRIPT_DIR/deploy_config.sh"
fi

echo
echo "=== install.sh: Cloudflare quick check ==="

CF_DIR="/root/.cloudflared"
CERT_FILE="$CF_DIR/cert.pem"
CONFIG_FILE="$CONFIG_DIR/projects.json"

have_cf=0
if command -v cloudflared >/dev/null 2>&1; then
  have_cf=1
  echo "[cf-check] cloudflared found: $(command -v cloudflared)"
else
  echo "[cf-check] cloudflared not found in PATH – Cloudflare automation disabled on this host."
fi

# 1) Если cloudflared есть, но нет cert.pem – предложить register_cloudflare.sh
if [ "$have_cf" -eq 1 ]; then
  if [ ! -f "$CERT_FILE" ]; then
    echo "[cf-check] cert.pem not found in $CF_DIR"
    if [ -x "$SCRIPT_DIR/register_cloudflare.sh" ]; then
      echo "[cf-check] To link this server with your Cloudflare account you must run 'cloudflared tunnel login' once."
      read -r -p "[cf-check] Run scripts/register_cloudflare.sh now (this will open browser login)? [Y/n]: " ans_reg
      ans_reg="${ans_reg:-Y}"
      if [[ "$ans_reg" =~ ^[Yy]$ ]]; then
        "$SCRIPT_DIR/register_cloudflare.sh"
      else
        echo "[cf-check] Skipping register_cloudflare.sh by user choice."
      fi
    else
      echo "[cf-check] WARNING: scripts/register_cloudflare.sh not found."
    fi
  else
    echo "[cf-check] cert.pem exists: $CERT_FILE"
  fi
fi

# 2) Если есть cert.pem и config/projects.json – проверить tunnelName и предложить sync_cloudflare.sh
if [ "$have_cf" -eq 1 ] && [ -f "$CERT_FILE" ] && [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
  tunnels_from_config="$(
    jq -r '
      [
        .webhook.cloudflare.tunnelName?,
        (.projects[]?.cloudflare.tunnelName?)
      ]
      | map(select(. != null and . != ""))
      | unique[]
      | .[]
    ' "$CONFIG_FILE" 2>/dev/null || true
  )"

  if [ -n "$tunnels_from_config" ]; then
    echo
    echo "[cf-check] Tunnels referenced in projects.json:"
    echo "$tunnels_from_config" | sed 's/^/  - /'

    need_sync=0
    for TUN_NAME in $tunnels_from_config; do
      CFG_YML="$CF_DIR/config-${TUN_NAME}.yml"
      if [ ! -f "$CFG_YML" ]; then
        echo "[cf-check] Missing config for tunnel '${TUN_NAME}': $CFG_YML"
        need_sync=1
      fi
    done

    if [ "$need_sync" -eq 1 ]; then
      if [ -x "$SCRIPT_DIR/sync_cloudflare.sh" ]; then
        read -r -p "[cf-check] Run scripts/sync_cloudflare.sh now to create missing configs? [Y/n]: " ans_sync
        ans_sync="${ans_sync:-Y}"
        if [[ "$ans_sync" =~ ^[Yy]$ ]]; then
          "$SCRIPT_DIR/sync_cloudflare.sh"
        else
          echo "[cf-check] Skipping sync_cloudflare.sh by user choice."
        fi
      else
        echo "[cf-check] WARNING: scripts/sync_cloudflare.sh not found."
      fi
    else
      echo "[cf-check] All config-<tunnel>.yml files seem to exist."
    fi
  else
    echo "[cf-check] No tunnelName entries in $CONFIG_FILE – Cloudflare tunnel mapping not configured yet."
  fi
elif [ "$have_cf" -eq 1 ] && [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf-check] NOTE: projects.json not present yet – Cloudflare sync will be skipped."
fi

echo
echo "=== install.sh finished ==="
echo
echo "[install] Cloudflare manual / advanced steps (once per host):"
echo "  1) If not done automatically:  ./scripts/register_cloudflare.sh"
echo "  2) Then:                       ./scripts/sync_cloudflare.sh"
echo "  3) To install systemd units:   ./scripts/install_cloudflare_service.sh"
echo "  4) For checks / status:        ./scripts/check_env.sh, ./scripts/reload_cloudflare.sh"
