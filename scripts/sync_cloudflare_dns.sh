#!/bin/bash
set -e

echo "=== sync_cloudflare_dns.sh ==="

# ROOT_DIR = /opt/webook_deploy_debian
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "[dns] ROOT_DIR    = $ROOT_DIR"
echo "[dns] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[dns] CONFIG_DIR  = $CONFIG_DIR"
echo "[dns] CONFIG_FILE = $CONFIG_FILE"
echo

# --- helpers ---

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[dns] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

# --- checks ---

need_bin cloudflared
need_bin jq

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[dns] ERROR: config file not found: $CONFIG_FILE"
  exit 1
fi

CF_DIR="/root/.cloudflared"
CERT="$CF_DIR/cert.pem"

if [ ! -f "$CERT" ]; then
  echo "[dns] ERROR: $CERT not found."
  echo "[dns] You must run on this host (once):"
  echo "       cloudflared tunnel login"
  echo "     and choose the correct zone in the browser."
  exit 1
fi

echo "[dns] Using Cloudflare credentials: $CERT"
echo

# базовый tunnelName из webhook (если у проектов пусто)
BASE_TUNNEL_NAME="$(jq -r '.webhook.cloudflare.tunnelName // ""' "$CONFIG_FILE")"

if [ -z "$BASE_TUNNEL_NAME" ] || [ "$BASE_TUNNEL_NAME" = "null" ]; then
  echo "[dns] WARNING: webhook.cloudflare.tunnelName is empty – projects must have their own tunnelName."
fi

echo "[dns] Collecting hostnames from projects.json ..."
echo

# формируем список: "tunnelName hostname"
# если у проекта tunnelName пустой → подставляем BASE_TUNNEL_NAME
HOST_LINES=$(jq -r --arg base_tunnel "$BASE_TUNNEL_NAME" '
  [
    # webhook hostname
    (
      if .webhook and .webhook.cloudflare
         and (.webhook.cloudflare.subdomain != null)
         and (.webhook.cloudflare.rootDomain != null)
      then
        {
          tunnel: (.webhook.cloudflare.tunnelName // $base_tunnel),
          host: (.webhook.cloudflare.subdomain + "." + .webhook.cloudflare.rootDomain)
        }
      else empty end
    )
    +
    # project hostnames
    (
      .projects[]? |
      select(.cloudflare.subdomain != null and .cloudflare.rootDomain != null) |
      {
        tunnel: ( .cloudflare.tunnelName // $base_tunnel ),
        host: (.cloudflare.subdomain + "." + .cloudflare.rootDomain)
      }
    )
  ]
  # уникальные по host
  | unique_by(.host)
  | .[]
  | (.tunnel // "") + " " + .host
' "$CONFIG_FILE")

if [ -z "$HOST_LINES" ]; then
  echo "[dns] No hostnames found in config – nothing to sync."
  exit 0
fi

echo "[dns] Planned DNS routes:"
echo "$HOST_LINES" | while read -r line; do
  t=$(echo "$line" | awk '{print $1}')
  h=$(echo "$line" | awk '{print $2}')
  printf "  tunnel=%-20s host=%s\n" "${t:-<EMPTY>}" "$h"
done
echo

read -r -p "[dns] Apply these DNS routes with 'cloudflared tunnel route dns'? [Y/n]: " ans
ans=${ans:-Y}
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
  echo "[dns] Aborted by user."
  exit 0
fi

echo
echo "[dns] Applying DNS routes..."
echo

FAILED=0

echo "$HOST_LINES" | while read -r line; do
  t=$(echo "$line" | awk '{print $1}')
  h=$(echo "$line" | awk '{print $2}')

  if [ -z "$t" ] || [ "$t" = "null" ]; then
    echo "[dns] SKIP: host=$h has empty tunnelName (no BASE_TUNNEL too?)."
    FAILED=1
    continue
  fi

  echo "[dns] Running: cloudflared tunnel route dns '$t' '$h'"
  if cloudflared tunnel route dns "$t" "$h"; then
    echo "[dns] OK: $h → tunnel=$t"
  else
    echo "[dns] ERROR: failed for host=$h, tunnel=$t"
    FAILED=1
  fi
  echo
done

echo "[dns] DNS route sync finished."

if [ "$FAILED" -ne 0 ]; then
  echo "[dns] Some entries failed – check messages above."
  exit 1
fi

echo "=== sync_cloudflare_dns.sh finished ==="
