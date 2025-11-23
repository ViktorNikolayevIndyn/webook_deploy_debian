#!/bin/bash
set -e

echo "=== sync_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "[cf] ROOT_DIR   = $ROOT_DIR"
echo "[cf] SCRIPT_DIR = $SCRIPT_DIR"
echo "[cf] CONFIG_DIR = $CONFIG_DIR"
echo "[cf] CONFIG_FILE = $CONFIG_FILE"
echo

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

# jq обязателен, cloudflared — опционально (мы только конфиг пишем)
need_bin jq

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf] ERROR: config file not found: $CONFIG_FILE"
  exit 1
fi

# Собираем список всех tunnelName из webhook + projects
TUNNELS=$(jq -r '
  [
    (.webhook.cloudflare? | select(.) | .tunnelName // empty),
    (.projects[]? | .cloudflare? | select(.) | .tunnelName // empty)
  ]
  | map(select(. != ""))
  | unique[]
' "$CONFIG_FILE")

if [ -z "$TUNNELS" ]; then
  echo "[cf] No tunnelName entries found in config. Nothing to do."
  exit 0
fi

echo "[cf] Tunnels found in config: $TUNNELS"
echo

# Сканируем /root/.cloudflared/*.json и строим map: TunnelName -> (jsonPath, TunnelID)
declare -A TUNNEL_JSON
declare -A TUNNEL_ID

for f in /root/.cloudflared/*.json; do
  [ -f "$f" ] || continue

  name=$(jq -r '.TunnelName // empty' "$f" 2>/dev/null || echo "")
  id=$(jq -r '.TunnelID // empty' "$f" 2>/dev/null || echo "")

  if [ -n "$name" ]; then
    TUNNEL_JSON["$name"]="$f"
    if [ -n "$id" ]; then
      TUNNEL_ID["$name"]="$id"
    else
      # Если по какой-то причине TunnelID нет — возьмём из имени файла без .json
      base="$(basename "$f")"
      TUNNEL_ID["$name"]="${base%.json}"
    fi
  fi
done

echo "[cf] Detected tunnels in /root/.cloudflared:"
for n in "${!TUNNEL_JSON[@]}"; do
  echo "  - $n -> ${TUNNEL_JSON[$n]} (TunnelID=${TUNNEL_ID[$n]})"
done
echo

# Функция: собрать ingress-правила для данного tunnelName
build_routes_for_tunnel() {
  local tn="$1"

  jq -r --arg tn "$tn" '
    [
      # webhook
      (if .webhook.cloudflare? and .webhook.cloudflare.enabled == true
          and (.webhook.cloudflare.tunnelName // "") == $tn
       then
         {
           host: (.webhook.cloudflare.subdomain + "." + .webhook.cloudflare.rootDomain),
           service: (
             .webhook.cloudflare.protocol
             + "://localhost:"
             + (.webhook.cloudflare.localPort | tostring)
           )
         }
       else empty end),

      # projects
      (.projects[]? |
        select(.cloudflare? and .cloudflare.enabled == true
               and (.cloudflare.tunnelName // "") == $tn) |
        {
          host: (.cloudflare.subdomain + "." + .cloudflare.rootDomain),
          service: (
            .cloudflare.protocol
            + "://localhost:"
            + (.cloudflare.localPort | tostring)
          )
        }
      )
    ]
    | .[]
    | "\(.host)|\(.service)"
  ' "$CONFIG_FILE"
}

# Генерация config-<tunnelName>.yml по каждому туннелю
for tn in $TUNNELS; do
  echo "[cf] === Processing tunnelName='$tn' ==="

  json_path="${TUNNEL_JSON[$tn]}"
  tunnel_id="${TUNNEL_ID[$tn]}"

  if [ -z "$json_path" ]; then
    echo "[cf] WARNING: No credentials JSON found in /root/.cloudflared for TunnelName='$tn'. Skipping."
    echo
    continue
  fi

  if [ -z "$tunnel_id" ]; then
    echo "[cf] WARNING: No TunnelID detected for '$tn' (json: $json_path). Skipping."
    echo
    continue
  fi

  routes=$(build_routes_for_tunnel "$tn")

  if [ -z "$routes" ]; then
    echo "[cf] WARNING: No routes (webhook/projects) bound to tunnelName='$tn'. Skipping config."
    echo
    continue
  fi

  cfg_path="/root/.cloudflared/config-${tn}.yml"

  echo "[cf] Writing config: $cfg_path"
  {
    echo "tunnel: ${tunnel_id}"
    echo "credentials-file: ${json_path}"
    echo
    echo "ingress:"
    IFS=$'\n'
    for r in $routes; do
      host="${r%%|*}"
      service="${r#*|}"
      echo "  - hostname: ${host}"
      echo "    service: ${service}"
    done
    unset IFS
    echo "  - service: http_status:404"
  } > "$cfg_path"

  chown root:root "$cfg_path"
  chmod 600 "$cfg_path"

  echo "[cf] Config written: $cfg_path"
  echo
done

echo "=== sync_cloudflare.sh finished ==="
echo
echo "[cf] You can run tunnels manually, e.g.:"
echo "  cloudflared --config /root/.cloudflared/config-<tunnelName>.yml tunnel run"
