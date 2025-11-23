#!/bin/bash
set -e

echo "=== sync_cloudflare.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "[cf] ROOT_DIR    = $ROOT_DIR"
echo "[cf] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[cf] CONFIG_DIR  = $CONFIG_DIR"
echo "[cf] CONFIG_FILE = $CONFIG_FILE"
echo

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[cf] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

need_bin jq
need_bin cloudflared

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf] ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

# --- Проверяем cert.pem (cloudflared tunnel login уже делали?) ---
CLOUDFLARE_DIR="${HOME}/.cloudflared"
CERT_FILE="$CLOUDFLARE_DIR/cert.pem"

if [ ! -f "$CERT_FILE" ]; then
  echo "[cf] WARNING: $CERT_FILE not found."
  echo "  Run on this host once:"
  echo "    cloudflared tunnel login"
  echo "  Then rerun sync_cloudflare.sh."
  exit 1
fi

# --- Собираем список всех tunnelName из projects + webhook ---

TUNNELS_JSON=$(jq -r '
  [
    .projects[]? | .cloudflare.tunnelName? // empty,
    .webhook.cloudflare.tunnelName? // empty
  ]
  | map(select(. != "")) 
  | unique
' "$CONFIG_FILE")

echo "[cf] Tunnels found in config: $TUNNELS_JSON"
echo

mapfile -t TUNNELS < <(echo "$TUNNELS_JSON" | jq -r '.[]?')

if [ "${#TUNNELS[@]}" -eq 0 ]; then
  echo "[cf] No tunnelName specified in config. Nothing to do."
  exit 0
fi

echo "[cf] Detected tunnels in ${CLOUDFLARE_DIR}:"
ls -1 "$CLOUDFLARE_DIR" || true
echo

# --- Helper: собрать правила host -> service для одного туннеля ---
build_rules_for_tunnel() {
  local tunnelName="$1"

  # Правило для webhook (если он использует этот tunnelName)
  local webhook_rule
  webhook_rule=$(jq -r --arg T "$tunnelName" '
    if .webhook
       and .webhook.cloudflare
       and .webhook.cloudflare.enabled == true
       and (.webhook.cloudflare.tunnelName // "") == $T
    then
      "\(.webhook.cloudflare.subdomain).\(.webhook.cloudflare.rootDomain) http://127.0.0.1:\(.webhook.cloudflare.localPort)"
    else
      ""
    end
  ' "$CONFIG_FILE")

  # Правила для проектов с этим tunnelName
  mapfile -t project_rules < <(jq -r --arg T "$tunnelName" '
    .projects[]?
    | select(.cloudflare.enabled == true)
    | select((.cloudflare.tunnelName // "") == $T)
    | "\(.cloudflare.subdomain).\(.cloudflare.rootDomain) http://127.0.0.1:\(.cloudflare.localPort)"
  ' "$CONFIG_FILE")

  # Печатаем в stdout строки "host service"
  if [ -n "$webhook_rule" ] && [ "$webhook_rule" != "null" ]; then
    echo "$webhook_rule"
  fi

  if [ "${#project_rules[@]}" -gt 0 ]; then
    for r in "${project_rules[@]}"; do
      [ -n "$r" ] && echo "$r"
    done
  fi
}

# --- Основной цикл по tunnelName ---

for TUN in "${TUNNELS[@]}"; do
  echo "[cf] === Processing tunnelName='$TUN' ==="

  CREDS_JSON="${CLOUDFLARE_DIR}/${TUN}.json"
  if [ ! -f "$CREDS_JSON" ]; then
    echo "[cf] WARNING: credentials JSON not found: $CREDS_JSON"
    echo "  You probably need to run:"
    echo "    cloudflared tunnel create ${TUN}"
    echo "  and then rerun sync_cloudflare.sh."
    echo
    continue
  fi

  CFG_YML="${CLOUDFLARE_DIR}/config-${TUN}.yml"

  echo "[cf] Building ingress rules for tunnel '${TUN}' ..."
  mapfile -t RULES < <(build_rules_for_tunnel "$TUN")

  if [ "${#RULES[@]}" -eq 0 ]; then
    echo "[cf]   No routes found in config for tunnel '${TUN}'. Skipping YAML write."
    echo
    continue
  fi

  echo "[cf]   Routes:"
  for line in "${RULES[@]}"; do
    echo "    $line"
  done

  # Пишем YAML
  {
    echo "tunnel: ${TUN}"
    echo "credentials-file: ${CREDS_JSON}"
    echo "ingress:"
    # каждая строка: "host service"
    for line in "${RULES[@]}"; do
      host="${line%% *}"
      svc="${line#* }"
      echo "  - hostname: ${host}"
      echo "    service: ${svc}"
    done
    echo "  - service: http_status:404"
  } > "$CFG_YML"

  echo "[cf]   Written config: $CFG_YML"
  echo
done

echo "=== sync_cloudflare.sh finished ==="
echo
echo "[cf] You can run tunnels manually, e.g.:"
for TUN in "${TUNNELS[@]}"; do
  echo "  cloudflared --config ${CLOUDFLARE_DIR}/config-${TUN}.yml tunnel run ${TUN}"
done
echo
