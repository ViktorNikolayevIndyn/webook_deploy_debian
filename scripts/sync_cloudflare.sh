#!/bin/bash
set -e

echo "=== sync_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

CF_DIR="/root/.cloudflared"

echo "[cf-sync] ROOT_DIR     = $ROOT_DIR"
echo "[cf-sync] SCRIPT_DIR   = $SCRIPT_DIR"
echo "[cf-sync] CONFIG_DIR   = $CONFIG_DIR"
echo "[cf-sync] CONFIG_FILE  = $CONFIG_FILE"
echo "[cf-sync] CF_DIR       = $CF_DIR"
echo

# ---------- helpers ----------

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf-sync] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[cf-sync] ERROR: config file not found: $CONFIG_FILE"
    echo "           Run ./scripts/init.sh first."
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

mkdir -p "$CF_DIR"

need_bin cloudflared
need_bin jq
ensure_config

# ---------- собираем все сервисы из config/projects.json ----------

echo "[cf-sync] Building services list from projects.json ..."
services_json="$(
  jq -c '
    [
      # webhook как отдельный сервис
      if .webhook and .webhook.cloudflare and (.webhook.cloudflare.tunnelName // "") != "" then
        {
          kind:       "webhook",
          tunnelName: .webhook.cloudflare.tunnelName,
          rootDomain: .webhook.cloudflare.rootDomain,
          subdomain:  .webhook.cloudflare.subdomain,
          port:       .webhook.cloudflare.localPort,
          protocol:   (.webhook.cloudflare.protocol // "http"),
          localPath:  (.webhook.cloudflare.localPath // "/"),
          path:       (.webhook.path // "/github")
        }
      else
        empty
      end,

      # проекты
      (
        .projects[]? |
        select(.cloudflare != null and (.cloudflare.tunnelName // "") != "") |
        {
          kind:       "project",
          name:       .name,
          tunnelName: .cloudflare.tunnelName,
          rootDomain: .cloudflare.rootDomain,
          subdomain:  .cloudflare.subdomain,
          port:       .cloudflare.localPort,
          protocol:   (.cloudflare.protocol // "http"),
          localPath:  (.cloudflare.localPath // "/"),
          path:       null
        }
      )
    ]
  ' "$CONFIG_FILE"
)"

if [ -z "$services_json" ] || [ "$services_json" = "[]" ]; then
  echo "[cf-sync] No Cloudflare-enabled services found in config."
  echo "=== sync_cloudflare.sh finished ==="
  exit 0
fi

# уникальные имена туннелей
tunnel_names="$(echo "$services_json" | jq -r '.[].tunnelName' | sort -u)"

echo "[cf-sync] Tunnels in use (from config):"
echo "$tunnel_names" | sed 's/^/  - /'
echo

# ---------- цикл по каждому tunnelName ----------

for TUN_NAME in $tunnel_names; do
  echo "[cf-sync] === Tunnel '$TUN_NAME' ==="

  TUN_ID="$(get_tunnel_id_by_name "$TUN_NAME" || true)"

  if [ -z "$TUN_ID" ] || [ "$TUN_ID" = "null" ]; then
    echo "[cf-sync] ERROR: tunnel '$TUN_NAME' not found in 'cloudflared tunnel list'."
    echo "          Run ./scripts/register_cloudflare.sh first."
    echo
    continue
  fi

  CRED_JSON="$CF_DIR/${TUN_ID}.json"
  if [ ! -f "$CRED_JSON" ]; then
    echo "[cf-sync] WARNING: credentials JSON not found: $CRED_JSON"
    echo "          Tunnel may not be runnable on this host."
  fi

  CFG_YML="$CF_DIR/config-${TUN_NAME}.yml"
  echo "[cf-sync] Generating config: $CFG_YML"
  echo "[cf-sync]   tunnel id: $TUN_ID"
  echo "[cf-sync]   creds    : $CRED_JSON"

  # выбираем сервисы только для этого туннеля
  group_json="$(echo "$services_json" | jq -c --arg T "$TUN_NAME" '[.[] | select(.tunnelName == $T)]')"

  # webhook-сервисы отдельно (path строгое), проекты отдельно
  webhook_json="$(echo "$group_json"  | jq -c '[.[] | select(.kind == "webhook")]')"
  projects_json="$(echo "$group_json" | jq -c '[.[] | select(.kind == "project")]')"

  {
    echo "tunnel: ${TUN_ID}"
    echo "credentials-file: ${CRED_JSON}"
    echo
    echo "ingress:"

    # 1) Webhook – сначала, чтобы match по path сработал до аппки
    echo "$webhook_json" | jq -c '.[]?' | while read -r svc; do
      rootDomain=$(echo "$svc" | jq -r '.rootDomain')
      subdomain=$(echo "$svc"  | jq -r '.subdomain')
      port=$(echo "$svc"       | jq -r '.port')
      protocol=$(echo "$svc"   | jq -r '.protocol')
      path=$(echo "$svc"       | jq -r '.path')

      host="$rootDomain"
      if [ -n "$subdomain" ] && [ "$subdomain" != "null" ]; then
        host="${subdomain}.${rootDomain}"
      fi

      echo "  - hostname: ${host}"
      if [ -n "$path" ] && [ "$path" != "null" ] && [ "$path" != "/" ]; then
        echo "    path: ${path}"
      fi
      echo "    service: ${protocol}://localhost:${port}"
    done

    # 2) Проекты – отдельные hostname без path (всё на приложуху)
    echo "$projects_json" | jq -c '.[]?' | while read -r svc; do
      name=$(echo "$svc"      | jq -r '.name')
      rootDomain=$(echo "$svc"| jq -r '.rootDomain')
      subdomain=$(echo "$svc" | jq -r '.subdomain')
      port=$(echo "$svc"      | jq -r '.port')
      protocol=$(echo "$svc"  | jq -r '.protocol')

      host="$rootDomain"
      if [ -n "$subdomain" ] && [ "$subdomain" != "null" ]; then
        host="${subdomain}.${rootDomain}"
      fi

      echo "  - hostname: ${host}"
      echo "    service: ${protocol}://localhost:${port}  # project: ${name}"
    done

    # 3) Фоллбек
    echo "  - service: http_status:404"
  } > "$CFG_YML"

  echo "[cf-sync] Wrote $CFG_YML"
  echo
done

echo "[cf-sync] cloudflared tunnel list:"
cloudflared tunnel list
echo

echo "=== sync_cloudflare.sh finished ==="
echo "[cf-sync] Next step (optional):"
echo "  ./scripts/install_cloudflare_service.sh   # create & enable systemd services for tunnels"
