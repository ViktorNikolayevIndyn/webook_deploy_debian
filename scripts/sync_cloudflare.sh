#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[cf] This script must be run as root (systemd + /root/.cloudflared)."
  exit 1
fi

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

ask_yes_no_default_yes() {
  local msg="$1"
  local ans
  read -r -p "$msg [Y/n]: " ans
  ans="${ans:-Y}"
  case "$ans" in
    n|N) return 1 ;;
    *)   return 0 ;;
  esac
}

need_bin jq
need_bin cloudflared

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[cf] ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

CLOUDFLARE_DIR="${HOME}/.cloudflared"
CERT_FILE="$CLOUDFLARE_DIR/cert.pem"

if [ ! -f "$CERT_FILE" ]; then
  echo "[cf] WARNING: $CERT_FILE not found."
  echo "  Run on this host once:"
  echo "    cloudflared tunnel login"
  echo "  Then rerun sync_cloudflare.sh."
  exit 1
fi

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

echo "[cf] Detected files in ${CLOUDFLARE_DIR}:"
ls -1 "$CLOUDFLARE_DIR" || true
echo

CF_TUNNELS_JSON="$(cloudflared tunnel list --output json 2>/dev/null || echo "[]")"

get_credentials_file_for_tunnel() {
  local tunnelName="$1"

  local tid
  tid="$(echo "$CF_TUNNELS_JSON" | jq -r --arg N "$tunnelName" '
    map(select(.name == $N)) | if length==0 then "" else .[0].id end
  ')"

  if [ -z "$tid" ] || [ "$tid" = "null" ]; then
    echo "[cf] Tunnel '$tunnelName' not found in 'cloudflared tunnel list'."
    if ask_yes_no_default_yes "[cf] Create tunnel '$tunnelName' now?"; then
      cloudflared tunnel create "$tunnelName"
      CF_TUNNELS_JSON="$(cloudflared tunnel list --output json 2>/dev/null || echo "[]")"
      tid="$(echo "$CF_TUNNELS_JSON" | jq -r --arg N "$tunnelName" '
        map(select(.name == $N)) | if length==0 then "" else .[0].id end
      ')"
      if [ -z "$tid" ] || [ "$tid" = "null" ]; then
        echo "[cf] ERROR: tunnel '$tunnelName' still not visible after create. Check manually."
        return 1
      fi
    else
      echo "[cf] Skipping tunnel '$tunnelName' (not created)."
      return 1
    fi
  fi

  local cred_by_id="${CLOUDFLARE_DIR}/${tid}.json"
  local cred_by_name="${CLOUDFLARE_DIR}/${tunnelName}.json"
  local chosen=""

  if [ -f "$cred_by_id" ] && [ -f "$cred_by_name" ] && [ "$cred_by_id" != "$cred_by_name" ]; then
    echo "[cf] Found two possible credentials for '$tunnelName':"
    echo "  - by ID   : $cred_by_id"
    echo "  - by name : $cred_by_name"
    if ask_yes_no_default_yes "[cf] Use ID-based credentials ($cred_by_id) as default and ignore name-based file?"; then
      chosen="$cred_by_id"
    else
      chosen="$cred_by_name"
    fi
  elif [ -f "$cred_by_id" ]; then
    chosen="$cred_by_id"
  elif [ -f "$cred_by_name" ]; then
    chosen="$cred_by_name"
  else
    echo "[cf] ERROR: No credentials JSON found for tunnel '$tunnelName'."
    echo "  Expected one of:"
    echo "    $cred_by_id"
    echo "    $cred_by_name"
    echo "  Try running:"
    echo "    cloudflared tunnel create $tunnelName"
    return 1
  fi

  echo "$chosen"
}

build_rules_for_tunnel() {
  local tunnelName="$1"

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

  mapfile -t project_rules < <(jq -r --arg T "$tunnelName" '
    .projects[]?
    | select(.cloudflare.enabled == true)
    | select((.cloudflare.tunnelName // "") == $T)
    | "\(.cloudflare.subdomain).\(.cloudflare.rootDomain) http://127.0.0.1:\(.cloudflare.localPort)"
  ' "$CONFIG_FILE")

  if [ -n "$webhook_rule" ] && [ "$webhook_rule" != "null" ]; then
    echo "$webhook_rule"
  fi

  if [ "${#project_rules[@]}" -gt 0 ]; then
    for r in "${project_rules[@]}"; do
      [ -n "$r" ] && echo "$r"
    done
  fi
}

for TUN in "${TUNNELS[@]}"; do
  echo "[cf] === Processing tunnelName='${TUN}' ==="

  CREDS_JSON="$(get_credentials_file_for_tunnel "$TUN" || echo "")"
  if [ -z "$CREDS_JSON" ]; then
    echo "[cf] Skipping tunnel '${TUN}' due to missing credentials."
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

  {
    echo "tunnel: ${TUN}"
    echo "credentials-file: ${CREDS_JSON}"
    echo "ingress:"
    for line in "${RULES[@]}"; do
      host="${line%% *}"
      svc="${line#* }"
      echo "  - hostname: ${host}"
      echo "    service: ${svc}"
    done
    echo "  - service: http_status:404"
  } > "$CFG_YML"

  echo "[cf]   Written config: $CFG_YML"

  # --- systemd service для туннеля ---
  SERVICE_NAME="cloudflared-${TUN}.service"
  SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

  if ask_yes_no_default_yes "[cf] Create/Update systemd service '${SERVICE_NAME}' and enable it?"; then
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Cloudflare Tunnel - ${TUN}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=/usr/bin/cloudflared --config ${CFG_YML} tunnel run ${TUN}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    echo "[cf]   systemd unit written: ${SERVICE_PATH}"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    echo "[cf]   Service ${SERVICE_NAME} enabled and restarted."
  else
    echo "[cf]   Skipping systemd service for '${TUN}'."
  fi

  echo
done

echo "=== sync_cloudflare.sh finished ==="
echo
echo "[cf] You can still run tunnels manually, e.g.:"
for TUN in "${TUNNELS[@]}"; do
  echo "  cloudflared --config ${CLOUDFLARE_DIR}/config-${TUN}.yml tunnel run ${TUN}"
done
echo
