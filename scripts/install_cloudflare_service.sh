#!/bin/bash
set -e

echo "=== install_cloudflare_service.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

CF_DIR="/root/.cloudflared"
SYSTEMD_DIR="/etc/systemd/system"

echo "[cf-service] ROOT_DIR    = $ROOT_DIR"
echo "[cf-service] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[cf-service] CONFIG_DIR  = $CONFIG_DIR"
echo "[cf-service] CONFIG_FILE = $CONFIG_FILE"
echo "[cf-service] CF_DIR      = $CF_DIR"
echo "[cf-service] SYSTEMD_DIR = $SYSTEMD_DIR"
echo

if [ "$EUID" -ne 0 ]; then
  echo "[cf-service] This script must be run as root."
  exit 1
fi

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-service] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[cf-service] ERROR: config file not found: $CONFIG_FILE"
    echo "              Run ./scripts/init.sh first."
    exit 1
  fi
}

get_tunnel_id_by_name() {
  local name="$1"
  cloudflared tunnel list --output json 2>/dev/null \
    | jq -r --arg NAME "$name" '
        .[]? | select(.name == $NAME) | .id
      ' \
    | head -n1
}

need_bin cloudflared
need_bin jq
ensure_config

mkdir -p "$CF_DIR"

# собираем туннели, которые используются в конфиге
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
  echo "[cf-service] No tunnelName values in config. Nothing to install."
  echo "=== install_cloudflare_service.sh finished ==="
  exit 0
fi

echo "[cf-service] Tunnels from config:"
echo "$tunnel_names" | sed 's/^/  - /'
echo

for TUN_NAME in $tunnel_names; do
  echo "[cf-service] === Processing tunnelName='$TUN_NAME' ==="

  TUN_ID="$(get_tunnel_id_by_name "$TUN_NAME" || true)"

  if [ -z "$TUN_ID" ] || [ "$TUN_ID" = "null" ]; then
    echo "[cf-service] ERROR: tunnel '$TUN_NAME' not found in cloudflared tunnel list."
    echo "             Run ./scripts/register_cloudflare.sh first."
    echo
    continue
  fi

  CFG_YML="$CF_DIR/config-${TUN_NAME}.yml"
  if [ ! -f "$CFG_YML" ]; then
    echo "[cf-service] WARNING: config file not found: $CFG_YML"
    echo "             Run ./scripts/sync_cloudflare.sh first."
    echo
    continue
  fi

  UNIT_NAME="cloudflared-${TUN_NAME}.service"
  UNIT_PATH="${SYSTEMD_DIR}/${UNIT_NAME}"

  echo "[cf-service] Creating systemd unit: $UNIT_PATH"

  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Cloudflare Tunnel (${TUN_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --config ${CFG_YML} tunnel run ${TUN_NAME}
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$UNIT_PATH"

  echo "[cf-service] Reloading systemd..."
  systemctl daemon-reload

  echo "[cf-service] Enabling and restarting ${UNIT_NAME} ..."
  systemctl enable "$UNIT_NAME"
  systemctl restart "$UNIT_NAME" || true

  systemctl --no-pager --full status "$UNIT_NAME" | sed -n '1,5p'
  echo
done

echo "=== install_cloudflare_service.sh finished ==="
echo "[cf-service] To see all cloudflared services:"
echo "  systemctl list-units 'cloudflared-*.service'"
