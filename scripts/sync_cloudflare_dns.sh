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

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf-dns] ERROR: projects.json not found at $CONFIG_FILE"
  exit 1
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[cf-dns] ERROR: cloudflared not found in PATH."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[cf-dns] ERROR: jq not found in PATH."
  exit 1
fi

# Cloudflare API creds из переменных окружения
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"

if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ]; then
  echo "[cf-dns] WARNING: CF_API_TOKEN или CF_ZONE_ID не заданы."
  echo "          DNS записи не будут создаваться, только будет показано что нужно создать."
  DO_APPLY=0
else
  DO_APPLY=1
fi

echo "[cf-dns] Detected files in /root/.cloudflared:"
ls -1 /root/.cloudflared 2>/dev/null || true
echo

# Собираем список tunnelName из конфига
mapfile -t TUNNELS < <(jq -r '
  [
    .webhook.cloudflare.tunnelName? ,
    (.projects[]?.cloudflare.tunnelName?)
  ]
  | map(select(. != null and . != ""))
  | unique[]
' "$CONFIG_FILE")

if [ "${#TUNNELS[@]}" -eq 0 ]; then
  echo "[cf-dns] No tunnelName entries found in config."
  exit 0
fi

echo "[cf-dns] Tunnels found in config:"
printf "  - %s\n" "${TUNNELS[@]}"
echo

# Helper: Cloudflare API call (создать/обновить CNAME)
cf_upsert_cname() {
  local name="$1"   # dev.linkify.cloud
  local target="$2" # <uuid>.cfargotunnel.com

  if [ "$DO_APPLY" -ne 1 ]; then
    echo "[cf-dns] (dry-run) CNAME $name -> $target (proxied=true)"
    return 0
  fi

  # Ищем существующую запись
  local resp id
  resp="$(
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${name}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json"
  )"

  id="$(echo "$resp" | jq -r '.result[0].id // empty')"

  if [ -n "$id" ]; then
    echo "[cf-dns] Updating existing CNAME $name -> $target (id=$id)..."
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${id}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data @- <<EOF >/dev/null
{
  "type": "CNAME",
  "name": "${name}",
  "content": "${target}",
  "ttl": 1,
  "proxied": true
}
EOF
  else
    echo "[cf-dns] Creating CNAME $name -> $target ..."
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data @- <<EOF >/dev/null
{
  "type": "CNAME",
  "name": "${name}",
  "content": "${target}",
  "ttl": 1,
  "proxied": true
}
EOF
  fi
}

# Для каждого tunnelName: находим его ID через cloudflared tunnel list
for TUN_NAME in "${TUNNELS[@]}"; do
  echo "[cf-dns] === Processing tunnelName='${TUN_NAME}' ==="

  # Получаем список туннелей в JSON
  TUN_JSON="$(cloudflared tunnel list --output json 2>/dev/null || true)"

  if [ -z "$TUN_JSON" ] || [ "$TUN_JSON" = "null" ]; then
    echo "[cf-dns]   ERROR: cloudflared tunnel list returned empty/null; is cert.pem configured?"
    echo
    continue
  fi

  TUN_ID="$(echo "$TUN_JSON" | jq -r ".[] | select(.name == \"${TUN_NAME}\") | .id" || true)"

  if [ -z "$TUN_ID" ] || [ "$TUN_ID" = "null" ]; then
    echo "[cf-dns]   ERROR: tunnel with name '${TUN_NAME}' not found in cloudflared tunnel list."
    echo "           Run: cloudflared tunnel create ${TUN_NAME}"
    echo
    continue
  fi

  TARGET="${TUN_ID}.cfargotunnel.com"
  echo "[cf-dns]   Found tunnel ID: ${TUN_ID}"
  echo "[cf-dns]   CNAME target:   ${TARGET}"
  echo

  # Собираем все хосты (webhook + projects), которые используют этот tunnelName
  mapfile -t HOSTS < <(jq -r --arg tn "$TUN_NAME" '
    [
      (if .webhook and .webhook.cloudflare and .webhook.cloudflare.tunnelName == $tn then
         (.webhook.cloudflare.subdomain + "." + .webhook.cloudflare.rootDomain)
       else empty end),
      (.projects[]? | select(.cloudflare.tunnelName == $tn)
        | (.cloudflare.subdomain + "." + .cloudflare.rootDomain))
    ]
    | map(select(. != null and . != ""))
    | unique[]
  ' "$CONFIG_FILE")

  if [ "${#HOSTS[@]}" -eq 0 ]; then
    echo "[cf-dns]   No hosts using tunnelName='${TUN_NAME}' in projects.json."
    echo
    continue
  fi

  echo "[cf-dns]   Hosts for this tunnel:"
  printf "      - %s\n" "${HOSTS[@]}"
  echo

  # Обновляем/создаём CNAME для каждого хоста
  for HOST in "${HOSTS[@]}"; do
    cf_upsert_cname "$HOST" "$TARGET"
  done

  echo
done

echo "=== sync_cloudflare_dns.sh finished ==="
