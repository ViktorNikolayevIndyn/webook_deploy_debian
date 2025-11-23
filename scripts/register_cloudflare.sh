#!/bin/bash
set -e

echo "=== register_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"
CF_DIR="/root/.cloudflared"

echo "[cf-register] ROOT_DIR    = $ROOT_DIR"
echo "[cf-register] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[cf-register] CONFIG_DIR  = $CONFIG_DIR"
echo "[cf-register] CONFIG_FILE = $CONFIG_FILE"
echo "[cf-register] CF_DIR      = $CF_DIR"
echo

# ---- helpers ----

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-register] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

ensure_file() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "[cf-register] ERROR: file not found: $f"
    exit 1
  fi
}

# ---- checks ----

need_bin jq
need_bin cloudflared

ensure_file "$CONFIG_FILE"

mkdir -p "$CF_DIR"

if [ ! -f "$CF_DIR/cert.pem" ]; then
  echo "[cf-register] ERROR: $CF_DIR/cert.pem not found."
  echo "[cf-register] You must run on this host (once):"
  echo "    cloudflared tunnel login"
  echo "and select the correct zone in the browser."
  exit 1
fi

echo "[cf-register] Found Cloudflare cert: $CF_DIR/cert.pem"
echo

# ---- collect tunnels + FQDNs from config ----
# output format: "<tunnelName> <fqdn>"

echo "[cf-register] Parsing tunnels + FQDNs from projects.json ..."

MAP_LINES=$(jq -r '
  [
    # webhook
    (
      .webhook as $w
      | select($w.cloudflare.tunnelName != null and $w.cloudflare.tunnelName != "")
      | {
          tunnel:   $w.cloudflare.tunnelName,
          fqdn:     ($w.cloudflare.subdomain + "." + $w.cloudflare.rootDomain)
        }
    ),
    # projects
    (
      .projects[]? as $p
      | select($p.cloudflare.tunnelName != null and $p.cloudflare.tunnelName != "")
      | {
          tunnel:   $p.cloudflare.tunnelName,
          fqdn:     ($p.cloudflare.subdomain + "." + $p.cloudflare.rootDomain)
        }
    )
  ]
  | map(select(.fqdn != null and .fqdn != "" and .tunnel != null and .tunnel != ""))
  | .[]
  | "\(.tunnel) \(.fqdn)"
' "$CONFIG_FILE")

if [ -z "$MAP_LINES" ]; then
  echo "[cf-register] No tunnels / FQDNs found in config. Nothing to do."
  echo "=== register_cloudflare.sh finished ==="
  exit 0
fi

echo "[cf-register] Tunnels + FQDNs from config:"
echo "$MAP_LINES"
echo

# ---- ensure tunnels exist ----

# track which tunnels we already ensured
declare -A TUNNEL_DONE

# helper: find cred JSON for tunnelName
find_cred_json_for_tunnel() {
  local tname="$1"
  local f

  # search any *.json in CF_DIR whose TunnelName matches
  for f in "$CF_DIR"/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg tn "$tname" '.TunnelName == $tn' "$f" >/dev/null 2>&1; then
      echo "$f"
      return 0
    fi
  done

  return 1
}

# first pass: ensure each tunnelName has a JSON
echo "[cf-register] Ensuring Cloudflare tunnels exist ..."
echo

# build unique tunnel list
TUNNELS=$(echo "$MAP_LINES" | awk '{print $1}' | sort -u)

for t in $TUNNELS; do
  echo "[cf-register] === Tunnel '$t' ==="

  CRED_FILE="$(find_cred_json_for_tunnel "$t" || true)"

  if [ -n "$CRED_FILE" ]; then
    echo "[cf-register] Found credentials JSON for '$t': $CRED_FILE"
  else
    echo "[cf-register] No credentials JSON for '$t' – creating tunnel ..."
    # this will create <TunnelID>.json in $CF_DIR
    cloudflared tunnel create "$t"
    # find again
    CRED_FILE="$(find_cred_json_for_tunnel "$t" || true)"

    if [ -z "$CRED_FILE" ]; then
      echo "[cf-register] ERROR: tunnel '$t' was created but no JSON found."
      echo "[cf-register] Check /root/.cloudflared manually."
      exit 1
    fi

    echo "[cf-register] Created tunnel '$t' with credentials: $CRED_FILE"
  fi

  # show basic info
  echo "[cf-register] Tunnel JSON info:"
  jq '.TunnelName, .TunnelID' "$CRED_FILE" || true
  echo

  TUNNEL_DONE["$t"]=1
done

# ---- DNS routes for each FQDN ----

echo "[cf-register] Registering DNS routes (subdomains) via cloudflared tunnel route dns ..."
echo

# we may see same (tunnel,fqdn) multiple times -> use associative filter
declare -A DONE_ROUTE

while read -r TUNNEL_NAME FQDN; do
  [ -n "$TUNNEL_NAME" ] || continue
  [ -n "$FQDN" ] || continue

  KEY="${TUNNEL_NAME}|${FQDN}"
  if [ -n "${DONE_ROUTE[$KEY]}" ]; then
    # already processed
    continue
  fi

  echo "[cf-register] Route DNS: tunnel='$TUNNEL_NAME', fqdn='$FQDN'"

  # This command is idempotent: if the record exists, it will be updated;
  # if not, it will be created.
  cloudflared tunnel route dns "$TUNNEL_NAME" "$FQDN" || {
    echo "[cf-register] WARNING: failed to route DNS for '$FQDN' with tunnel '$TUNNEL_NAME'"
  }

  DONE_ROUTE["$KEY"]=1
  echo
done <<< "$MAP_LINES"

echo "=== register_cloudflare.sh finished ==="
echo
echo "[cf-register] Next steps:"
echo "  1) Generate per-tunnel config files with:"
echo "       $SCRIPT_DIR/sync_cloudflare.sh"
echo "  2) Start tunnel, for example:"
echo "       cloudflared --config /root/.cloudflared/config-<TunnelName>.yml tunnel run"
