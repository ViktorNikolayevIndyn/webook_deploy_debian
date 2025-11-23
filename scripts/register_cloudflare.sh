#!/bin/bash
set -e

echo "=== register_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

CF_DIR="/root/.cloudflared"
CERT_FILE="$CF_DIR/cert.pem"

echo "[cf-register] ROOT_DIR    = $ROOT_DIR"
echo "[cf-register] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[cf-register] CONFIG_DIR  = $CONFIG_DIR"
echo "[cf-register] CONFIG_FILE = $CONFIG_FILE"
echo "[cf-register] CF_DIR      = $CF_DIR"
echo

# ----- helpers -----

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-register] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[cf-register] ERROR: config file not found: $CONFIG_FILE"
    echo "              Run ./scripts/init.sh first."
    exit 1
  fi
}

# ----- check binaries -----

need_bin cloudflared
need_bin jq

mkdir -p "$CF_DIR"

# ----- ensure cert.pem (cloudflared tunnel login) -----

if [ ! -f "$CERT_FILE" ]; then
  echo "[cf-register] $CERT_FILE not found."
  echo "[cf-register] Now running 'cloudflared tunnel login'."
  echo
  echo "  • В консоли появится URL вида:"
  echo "      https://dash.cloudflare.com/arg... "
  echo "  • Открой этот URL в браузере,"
  echo "    залогинься в Cloudflare и выбери нужную зону (домен)."
  echo "  • После подтверждения Cloudflare скачает cert.pem на этот сервер."
  echo

  cloudflared tunnel login || {
    echo "[cf-register] ERROR: cloudflared tunnel login failed."
    exit 1
  }

  # проверяем ещё раз наличие cert.pem
  if [ ! -f "$CERT_FILE" ]; then
    echo "[cf-register] ERROR: cloudflared tunnel login finished but $CERT_FILE is still missing."
    echo "[cf-register] Check the output above and repeat, if needed."
    exit 1
  fi
else
  echo "[cf-register] Found existing cert.pem: $CERT_FILE"
fi

echo
ensure_config

# ----- collect unique tunnel names from projects.json -----

echo "[cf-register] Collecting tunnelName values from $CONFIG_FILE ..."

tunnel_names=$(jq -r '
  [
    .webhook.cloudflare.tunnelName?,
    (.projects[]?.cloudflare.tunnelName?)
  ]
  | map(select(. != null and . != ""))
  | unique[]
' "$CONFIG_FILE" 2>/dev/null || true)

if [ -z "$tunnel_names" ]; then
  echo "[cf-register] No tunnelName values found in config. Nothing to register."
  echo "=== register_cloudflare.sh finished ==="
  exit 0
fi

echo "[cf-register] Tunnels requested in config:"
echo "$tunnel_names" | sed 's/^/  - /'
echo

# ----- helper: get tunnel id by name -----

get_tunnel_id_by_name() {
  local name="$1"
  cloudflared tunnel list --output json 2>/dev/null \
    | jq -r --arg NAME "$name" '
        .[]? | select(.name == $NAME) | .id
      ' \
    | head -n1
}

# ----- main loop over tunnelNames -----

for TUN_NAME in $tunnel_names; do
  echo "[cf-register] === Processing tunnelName='$TUN_NAME' ==="

  # ищем существующий туннель
  TUN_ID="$(get_tunnel_id_by_name "$TUN_NAME" || true)"

  if [ -n "$TUN_ID" ] && [ "$TUN_ID" != "null" ]; then
    echo "[cf-register] Tunnel '$TUN_NAME' already exists with id=$TUN_ID"
  else
    echo "[cf-register] No tunnel named '$TUN_NAME' found. Creating..."
    cloudflared tunnel create "$TUN_NAME" || {
      echo "[cf-register] ERROR: failed to create tunnel '$TUN_NAME'."
      continue
    }

    # после create ещё раз читаем список
    TUN_ID="$(get_tunnel_id_by_name "$TUN_NAME" || true)"
    if [ -z "$TUN_ID" ] || [ "$TUN_ID" = "null" ]; then
      echo "[cf-register] ERROR: tunnel '$TUN_NAME' created but id could not be determined."
      continue
    fi
    echo "[cf-register] Created tunnel '$TUN_NAME' with id=$TUN_ID"
  fi

  # путь к credentials JSON
  CRED_JSON="$CF_DIR/${TUN_ID}.json"
  if [ -f "$CRED_JSON" ]; then
    echo "[cf-register] Credentials file: $CRED_JSON"
  else
    echo "[cf-register] WARNING: credentials JSON not found at $CRED_JSON."
    echo "             cloudflared usually creates it during 'tunnel create'."
  fi

  echo
done

echo "[cf-register] Current tunnels (cloudflared tunnel list):"
cloudflared tunnel list
echo

echo "=== register_cloudflare.sh finished ==="
echo "[cf-register] Next steps:"
echo "  1) ./scripts/sync_cloudflare.sh   # generate config-<tunnelName>.yml with services"
echo "  2) (optional) create systemd units for tunnels to auto-start on boot."
