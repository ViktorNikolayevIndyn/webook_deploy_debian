#!/bin/bash
set -e

echo "=== check_env.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "[*] ROOT_DIR   = $ROOT_DIR"
echo "[*] CONFIG_DIR = $CONFIG_DIR"
echo

need_bin() {
  local bin="$1"
  local label="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[WARN] $label not found in PATH."
    return 1
  else
    echo "[OK]   $label found: $(command -v "$bin")"
    return 0
  fi
}

echo "== Binaries =="
need_bin docker "docker"
if ! command -v docker-compose >/dev/null 2>&1; then
  echo "[WARN] docker-compose not found (ok if you use 'docker compose' v2 plugin)"
else
  echo "[OK]   docker-compose found: $(command -v docker-compose)"
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[WARN] cloudflared not found in PATH (Cloudflare tunnels may not work yet)"
else
  echo "[OK]   cloudflared found: $(command -v cloudflared)"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[WARN] node not found in PATH (webhook.js / Node apps may not run)"
else
  echo "[OK]   node found: $(command -v node)"
fi

need_bin curl "curl" || true
need_bin jq "jq" || true
echo

echo "== Docker daemon & group =="
if docker info >/dev/null 2>&1; then
  echo "[OK]   Docker daemon is reachable (docker info OK)"
else
  echo "[WARN] Docker daemon not reachable. Check 'systemctl status docker'."
fi

if getent group docker >/dev/null 2>&1; then
  echo "[OK]   Group 'docker' exists: $(getent group docker)"
else
  echo "[WARN] Group 'docker' does NOT exist yet."
fi
echo

echo "== State / version flags =="
for f in env_bootstrap ssh_state projects_state; do
  path="$CONFIG_DIR/${f}.json"
  if [ -f "$path" ]; then
    ver=$(jq -r '.version // "n/a"' "$path" 2>/dev/null || echo "n/a")
    echo "[OK]   ${f} flag present: $path (version='${ver}')"
  else
    echo "[WARN] ${f}.json not found in $CONFIG_DIR"
  fi
done
echo

echo "== Config: $CONFIG_FILE =="
if [ -f "$CONFIG_FILE" ]; then
  echo "[OK]   Config file exists."
  projects_count=$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  echo "[OK]   Projects count: $projects_count"
else
  echo "[WARN] Config file does not exist."
  projects_count=0
fi
echo

if [ -f "$CONFIG_FILE" ]; then
  echo "-- Webhook config --"
  jq -r '
    if .webhook then
      "  port      : \(.webhook.port // "n/a")\n" +
      "  path      : \(.webhook.path // "n/a")\n" +
      "  domain    : \(.webhook.cloudflare.rootDomain // "n/a") (sub=\(.webhook.cloudflare.subdomain // "n/a"))\n" +
      "  tunnel    : \(.webhook.cloudflare.tunnelName // "n/a")\n" +
      "  protocol  : \(.webhook.cloudflare.protocol // "n/a")\n" +
      "  localPath : \(.webhook.cloudflare.localPath // "n/a")"
    else
      "  (no webhook config)"
    end
  ' "$CONFIG_FILE"
  echo

  echo "-- Projects summary --"
  jq -r '
    .projects[]? |
    "- \(.name // "n/a") | branch=\(.branch // "n/a") | " +
    "domain=\(.cloudflare.rootDomain // "n/a") | " +
    "subdomain=\(.cloudflare.subdomain // "n/a") | " +
    "workDir=\(.workDir // "n/a")"
  ' "$CONFIG_FILE"
  echo
fi

echo "== Webhook port listening test =="
if [ -f "$CONFIG_FILE" ]; then
  webhook_port=$(jq -r '.webhook.port // 4000' "$CONFIG_FILE" 2>/dev/null || echo 4000)
else
  webhook_port=4000
fi

echo "[*] Expected webhook port: $webhook_port"

if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | grep -q ":${webhook_port} "; then
    echo "[OK] Port ${webhook_port} is LISTENING (ss -tln)"
  else
    echo "[WARN] Port ${webhook_port} is NOT listed as listening in ss -tln"
  fi
else
  echo "[WARN] 'ss' not found, skipping low-level port check."
fi

if command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "$webhook_port" >/dev/null 2>&1; then
    echo "[OK] TCP connect to 127.0.0.1:${webhook_port} succeeded (nc)"
  else
    echo "[WARN] TCP connect to 127.0.0.1:${webhook_port} failed (nc)"
  fi
else
  echo "[WARN] 'nc' not found, skipping TCP connect test."
fi
echo

# ===========================
# == Cloudflare diagnostics ==
# ===========================
echo "== Cloudflare =="

CF_DIR="/root/.cloudflared"

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[WARN] cloudflared binary not found. Cloudflare tunnels disabled."
else
  echo "[OK]   cloudflared binary present."
fi

if [ -d "$CF_DIR" ]; then
  echo "[OK]   Cloudflare directory exists: $CF_DIR"
else
  echo "[WARN] Cloudflare directory not found: $CF_DIR"
fi

CERT="$CF_DIR/cert.pem"
if [ -f "$CERT" ]; then
  echo "[OK]   cert.pem present: $CERT"
else
  echo "[WARN] cert.pem not found in $CF_DIR"
  echo "       Run on this host: cloudflared tunnel login"
fi

# Список туннелей из config
if [ -f "$CONFIG_FILE" ]; then
  tunnels_from_config="$(
    jq -r '
      [
        .webhook.cloudflare.tunnelName?,
        (.projects[]?.cloudflare.tunnelName?)
      ]
      | map(select(. != null and . != ""))
      | unique[]
      | .[]
    ' "$CONFIG_FILE" 2>/dev/null || true
  )"

  if [ -n "$tunnels_from_config" ]; then
    echo
    echo "[Cloudflare] Tunnels referenced in projects.json:"
    echo "$tunnels_from_config" | sed 's/^/  - /'
  else
    echo "[Cloudflare] No tunnelName entries in projects.json."
  fi
else
  tunnels_from_config=""
fi

echo
echo "[Cloudflare] cloudflared tunnel list (if any):"
if command -v cloudflared >/dev/null 2>&1; then
  cloudflared tunnel list || true
else
  echo "  (cloudflared not installed)"
fi

# Проверим наличие config-<tunnel>.yml и systemd-юнитов
if [ -n "$tunnels_from_config" ]; then
  echo
  echo "[Cloudflare] Per-tunnel config & services:"
  for TUN_NAME in $tunnels_from_config; do
    CFG_YML="$CF_DIR/config-${TUN_NAME}.yml"
    UNIT="cloudflared-${TUN_NAME}.service"

    if [ -f "$CFG_YML" ]; then
      echo "  [OK]  config-${TUN_NAME}.yml present: $CFG_YML"
    else
      echo "  [WARN] config-${TUN_NAME}.yml missing in $CF_DIR"
    fi

    if systemctl list-unit-files "$UNIT" >/dev/null 2>&1; then
      STATE="$(systemctl is-enabled "$UNIT" 2>/dev/null || echo "disabled")"
      ACTIVE="$(systemctl is-active "$UNIT" 2>/dev/null || echo "inactive")"
      echo "  [UNIT] ${UNIT}: enabled=${STATE}, active=${ACTIVE}"
    else
      echo "  [UNIT] ${UNIT} not defined."
    fi
  done
fi

echo
echo "=== check_env.sh finished ==="
