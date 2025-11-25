#!/bin/bash
set -e

echo "=== sync_cloudflare_dns.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "[cf-dns] ROOT_DIR    = $ROOT_DIR"
echo "[cf-dns] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[cf-dns] CONFIG_DIR  = $CONFIG_DIR"
echo "[cf-dns] CONFIG_FILE = $CONFIG_FILE"
echo

route_dns_for_host() {
  local tunnelName="$1"
  local host="$2"

  echo "[cf-dns]   Running: cloudflared tunnel route dns $tunnelName $host"
  local out
  # запускаем cloudflared и собираем вывод
  if out=$(cloudflared tunnel route dns "$tunnelName" "$host" 2>&1); then
    echo "$out"
    echo "[cf-dns]   OK: DNS route ensured for $host"
    return 0
  fi

  # если команда завершилась с ошибкой – печатаем вывод
  echo "$out"

  # спец-случай: запись уже существует
  if grep -q "An A, AAAA, or CNAME record with that host already exists" <<<"$out"; then
    # если есть токен и zone id – пробуем переписать через API
    if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ZONE_ID" ]; then
      echo "[cf-dns]   Existing record for $host detected. Trying to override via Cloudflare API..."

      # забираем все DNS-записи для host
      local ids
      ids=$(
        curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$host" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
        | jq -r '.result[].id'
      )

      if [ -z "$ids" ]; then
        echo "[cf-dns]   No existing DNS records found in API for $host, cannot override."
        return 1
      fi

      local id
      for id in $ids; do
        echo "[cf-dns]   Deleting old DNS record id=$id for $host via API..."
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$id" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" >/dev/null
      done

      echo "[cf-dns]   Retry: cloudflared tunnel route dns $tunnelName $host"
      if cloudflared tunnel route dns "$tunnelName" "$host"; then
        echo "[cf-dns]   OK: DNS route overridden for $host"
        return 0
      else
        echo "[cf-dns]   ERROR: route dns still failing for $host after override attempt."
        return 1
      fi
    else
      # токена нет – сообщаем, что надо руками удалить в панели
      echo "[cf-dns]   WARNING: DNS record for $host already exists and CF_API_TOKEN/CF_ZONE_ID are not set."
      echo "[cf-dns]            Delete existing A/AAAA/CNAME for $host in Cloudflare dashboard, then rerun sync_cloudflare_dns.sh."
      # считаем это soft-ошибкой и идём дальше
      return 0
    fi
  fi

  echo "[cf-dns]   ERROR: failed to route DNS for $host"
  return 1
}


# --- basic checks ---
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf-dns] ERROR: config file not found: $CONFIG_FILE"
  exit 1
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[cf-dns] ERROR: cloudflared not found in PATH."
  echo "          Install it first (scripts/register_cloudflare.sh) and try again."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[cf-dns] ERROR: jq not found in PATH."
  exit 1
fi

CLOUDFLARED_DIR="/root/.cloudflared"
if [ ! -d "$CLOUDFLARED_DIR" ]; then
  echo "[cf-dns] ERROR: $CLOUDFLARED_DIR not found. Did you run cloudflared tunnel login/create?"
  exit 1
fi

echo "[cf-dns] Detected files in $CLOUDFLARED_DIR:"
ls -1 "$CLOUDFLARED_DIR"
echo

# --- collect tunnel names from config (projects + webhook) ---
TUNNELS_JSON=$(jq -r '
  [
    (.projects[]? | .cloudflare? | select(.enabled == true) | .tunnelName),
    (.webhook.cloudflare? | select(.enabled == true) | .tunnelName)
  ]
  | map(select(. != null and . != ""))
  | unique
' "$CONFIG_FILE")

if [ "$TUNNELS_JSON" = "[]" ]; then
  echo "[cf-dns] No tunnelName values found in config (projects + webhook). Nothing to do."
  exit 0
fi

echo "[cf-dns] Tunnels found in config:"
echo "$TUNNELS_JSON" | jq -r '.[] | "  - " + .'
echo

# --- helper: get tunnel id from cloudflared ---
get_tunnel_id() {
  local tunnelName="$1"
  cloudflared tunnel list --output json 2>/dev/null \
    | jq -r --arg name "$tunnelName" '.[] | select(.name == $name) | .id' \
    | head -n 1
}

# --- main loop over tunnels ---
for tunnelName in $(echo "$TUNNELS_JSON" | jq -r '.[]'); do
  echo "[cf-dns] === Processing tunnelName='$tunnelName' ==="

  # find tunnel id (for info only)
  tunnel_id="$(get_tunnel_id "$tunnelName")"
  if [ -z "$tunnel_id" ] || [ "$tunnel_id" = "null" ]; then
    echo "[cf-dns] WARNING: Tunnel '$tunnelName' not found in 'cloudflared tunnel list'."
    echo "          Make sure you created it with: cloudflared tunnel create $tunnelName"
    echo
    continue
  fi

  cname_target="${tunnel_id}.cfargotunnel.com"
  echo "[cf-dns]   Found tunnel ID: $tunnel_id"
  echo "[cf-dns]   CNAME target:   $cname_target"
  echo

  # collect hosts for this tunnel from projects
  HOSTS_PROJECTS=$(jq -r --arg t "$tunnelName" '
    .projects[]?
    | select(.cloudflare.enabled == true and .cloudflare.tunnelName == $t)
    | "\(.cloudflare.subdomain).\(.cloudflare.rootDomain)"
  ' "$CONFIG_FILE" | sort -u)

  # collect webhook host for this tunnel (если включен и tunnelName совпадает или пустой)
  HOSTS_WEBHOOK=$(jq -r --arg t "$tunnelName" '
    .webhook.cloudflare?
    | select(.enabled == true and (.tunnelName == $t or .tunnelName == null or .tunnelName == ""))
    | "\(.subdomain).\(.rootDomain)"
  ' "$CONFIG_FILE" 2>/dev/null || true)

  # merge hosts + uniq
  HOSTS_ALL=$(printf "%s\n%s\n" "$HOSTS_PROJECTS" "$HOSTS_WEBHOOK" \
    | sed '/^$/d' \
    | sort -u)

  if [ -z "$HOSTS_ALL" ]; then
    echo "[cf-dns]   No hosts found in config for tunnel '$tunnelName'. Skipping."
    echo
    continue
  fi

  echo "[cf-dns]   Hosts for this tunnel:"
  echo "$HOSTS_ALL" | sed 's/^/      - /'
  echo

  # create/update DNS via cloudflared tunnel route dns
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    echo "[cf-dns]   Running: cloudflared tunnel route dns $tunnelName $host"
    if cloudflared tunnel route dns "$tunnelName" "$host"; then
      echo "[cf-dns]   OK: DNS route ensured for $host"
    else
      echo "[cf-dns]   ERROR: failed to route DNS for $host"
    fi
    echo
  done <<< "$HOSTS_ALL"

  echo "[cf-dns] === Done for tunnelName='$tunnelName' ==="
  echo
done

echo "=== sync_cloudflare_dns.sh finished ==="
