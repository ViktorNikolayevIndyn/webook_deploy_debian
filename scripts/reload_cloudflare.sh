#!/bin/bash
set -e

echo "=== reload_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

if [ "$EUID" -ne 0 ]; then
  echo "[cf-reload] This script must be run as root (systemctl needed)."
  exit 1
fi

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-reload] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[cf-reload] ERROR: config file not found: $CONFIG_FILE"
    exit 1
  fi
}

need_bin jq
need_bin systemctl
ensure_config

echo "[cf-reload] ROOT_DIR    = $ROOT_DIR"
echo "[cf-reload] CONFIG_FILE = $CONFIG_FILE"
echo

# Собираем список tunnelName из config
tunnel_names="$(
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

if [ -z "$tunnel_names" ]; then
  echo "[cf-reload] No tunnelName entries found in projects.json."
  echo "=== reload_cloudflare.sh finished ==="
  exit 0
fi

echo "[cf-reload] Tunnels from config:"
echo "$tunnel_names" | sed 's/^/  - /'
echo

for TUN_NAME in $tunnel_names; do
  UNIT="cloudflared-${TUN_NAME}.service"
  echo "[cf-reload] Restarting ${UNIT} ..."
  if systemctl restart "$UNIT"; then
    echo "[cf-reload] ${UNIT} restarted OK. Short status:"
    systemctl --no-pager --full status "$UNIT" | sed -n '1,5p' || true
  else
    echo "[cf-reload] WARNING: failed to restart ${UNIT} (maybe not installed?)."
  fi
  echo
done

echo "[cf-reload] Active cloudflared units:"
systemctl list-units 'cloudflared-*.service' --no-pager || true

echo
echo "=== reload_cloudflare.sh finished ==="
