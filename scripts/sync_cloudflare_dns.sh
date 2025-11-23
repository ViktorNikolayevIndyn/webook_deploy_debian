#!/bin/bash
set -e

echo "=== sync_cloudflare_dns.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"
CLOUDFLARED_DIR="/root/.cloudflared"

echo "[cf-dns] ROOT_DIR    = $ROOT_DIR"
echo "[cf-dns] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[cf-dns] CONFIG_DIR  = $CONFIG_DIR"
echo "[cf-dns] CONFIG_FILE = $CONFIG_FILE"
echo

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-dns] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

need_bin jq
need_bin cloudflared

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf-dns] ERROR: config file not found: $CONFIG_FILE"
  exit 1
fi

if [ ! -d "$CLOUDFLARED_DIR" ]; then
  echo "[cf-dns] ERROR: $CLOUDFLARED_DIR not found."
  echo "          Run 'cloudflared tunnel login' first."
  exit 1
fi

echo "[cf-dns] Detected files in $CLOUDFLARED_DIR:"
ls -1 "$CLOUDFLARED_DIR" || true
echo

# --- collect tunnel names from config ---
TUNNELS_JSON=$(jq '
  [
    (.webhook.cloudflare.tunnelName // empty),
    (.projects[]? | .cloudflare.tunnelName // empty)
  ]
  | flatten? // .
  | map(select(. != "")) 
  | unique
' "$CONFIG_FILE")

TUNNELS=$(echo "$TUNNELS_JSON" | jq -r '.[]?' 2>/dev/null || true)

if [ -z "$TUNNELS" ]; then
  echo "[cf-dns] No tunnelName entries found in config. Nothing to do."
  exit 0
fi

echo "[cf-dns] Tunnels found in config:"
echo "$TUNNELS_JSON"
echo

# --- function: get desired hostnames for a tunnel ---
get_hosts_for_tunnel() {
  local tunnel="$1"

  jq -r --arg T "$tunnel" '
    [
      # webhook host:
      # - если tunnelName пустой → считаем, что подходит для любого туннеля
      # - если задан и совпадает с $T → берём
      (
        if .webhook? and .webhook.cloudflare? 
           and (.webhook.cloudflare.subdomain // "") != ""
           and (.webhook.cloudflare.rootDomain // "") != "" then

          if ((.webhook.cloudflare.tunnelName // "") == "" )
          then
            (.webhook.cloudflare.subdomain + "." + .webhook.cloudflare.rootDomain)
          elif .webhook.cloudflare.tunnelName == $T then
            (.webhook.cloudflare.subdomain + "." + .webhook.cloudflare.rootDomain)
          else
            empty
          end

        else
          empty
        end
      ),

      # project hosts
      (
        .projects[]? 
        | select(.cloudflare?)
        | select(
            (.cloudflare.tunnelName // "") == "" 
            or .cloudflare.tunnelName == $T
          )
        | (.cloudflare.subdomain + "." + .cloudflare.rootDomain)
      )
    ]
    | map(select(. != null and . != "")) 
    | unique
    | .[]
  ' "$CONFIG_FILE"
}

# --- main loop ---
for TUNNEL in $TUNNELS; do
  echo "[cf-dns] === Processing tunnelName='$TUNNEL' ==="

  CREDS_JSON="$CLOUDFLARED_DIR/$TUNNEL.json"
  if [ ! -f "$CREDS_JSON" ]; then
    echo "[cf-dns] WARNING: credentials JSON not found: $CREDS_JSON"
    echo "          Run: cloudflared tunnel create $TUNNEL"
    echo "          then rerun sync_cloudflare_dns.sh"
    echo
    continue
  fi

  DESIRED_HOSTS=$(get_hosts_for_tunnel "$TUNNEL")
  if [ -z "$DESIRED_HOSTS" ]; then
    echo "[cf-dns]   No hostnames in config for tunnel '$TUNNEL'. Skipping."
    echo
    continue
  fi

  echo "[cf-dns]   Desired hosts for tunnel '$TUNNEL':"
  echo "$DESIRED_HOSTS" | sed 's/^/      - /'
  echo

  echo "[cf-dns]   Existing DNS routes for '$TUNNEL':"
  EXISTING_HOSTS=$(cloudflared tunnel route dns "$TUNNEL" 2>/dev/null \
    | awk 'NR>1 && $2 ~ /\./ {print $2}' || true)

  if [ -n "$EXISTING_HOSTS" ]; then
    echo "$EXISTING_HOSTS" | sed 's/^/      * /'
  else
    echo "      (none)"
  fi
  echo

  for HOST in $DESIRED_HOSTS; do
    if echo "$EXISTING_HOSTS" | grep -qx "$HOST"; then
      echo "[cf-dns]   OK    $HOST already routed to tunnel '$TUNNEL'."
    else
      echo "[cf-dns]   ADD   $HOST -> tunnel '$TUNNEL' ..."
      cloudflared tunnel route dns "$TUNNEL" "$HOST"
    fi
  done

  echo
done

echo "=== sync_cloudflare_dns.sh finished ==="
