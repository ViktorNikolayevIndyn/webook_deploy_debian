#!/bin/bash
set -e

echo "=== check_env.sh ==="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "[*] ROOT_DIR   = $ROOT_DIR"
echo "[*] CONFIG_DIR = $CONFIG_DIR"
echo

need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[WARN] '$bin' not found in PATH."
    return 1
  fi
  echo "[OK]   $bin binary found: $(command -v "$bin")"
  return 0
}

echo "== Binaries =="
need_bin docker || true
need_bin docker-compose || true
need_bin cloudflared || true
need_bin node || true
need_bin curl || true
need_bin jq || true
echo

echo "== Docker daemon & group =="
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "[OK]   Docker daemon is reachable (docker info OK)"
  else
    echo "[WARN] Docker daemon NOT reachable (docker info failed)"
  fi

  if getent group docker >/dev/null 2>&1; then
    echo "[OK]   Group 'docker' exists: $(getent group docker)"
  else
    echo "[WARN] Group 'docker' does not exist"
  fi
else
  echo "[WARN] docker not installed, skipping daemon check."
fi
echo

echo "== State / version flags =="
STATE_ENV="$CONFIG_DIR/env_bootstrap.json"
STATE_SSH="$CONFIG_DIR/ssh_state.json"
STATE_PROJ="$CONFIG_DIR/projects_state.json"

if [ -f "$STATE_ENV" ]; then
  echo "[OK]   env_bootstrap flag present: $STATE_ENV (version='$(jq -r '.version // "?"' "$STATE_ENV" 2>/dev/null || echo "?")')"
else
  echo "[WARN] env_bootstrap flag missing: $STATE_ENV"
fi

if [ -f "$STATE_SSH" ]; then
  echo "[OK]   ssh_state flag present: $STATE_SSH (version='$(jq -r '.version // "?"' "$STATE_SSH" 2>/dev/null || echo "?")')"
else
  echo "[WARN] ssh_state flag missing: $STATE_SSH"
fi

if [ -f "$STATE_PROJ" ]; then
  echo "[OK]   projects_state flag present: $STATE_PROJ (version='$(jq -r '.version // "?"' "$STATE_PROJ" 2>/dev/null || echo "?")')"
else
  echo "[WARN] projects_state flag missing: $STATE_PROJ"
fi
echo

echo "== Config: $CONFIG_FILE =="
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[WARN] Config file does not exist."
else
  echo "[OK]   Config file exists."

  PROJECTS_COUNT=$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  echo "[OK]   Projects count: $PROJECTS_COUNT"
  echo

  echo "-- Webhook config --"
  jq -r '
    if .webhook and .webhook.cloudflare then
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
    "- \(.name // "n/a") | branch=\(.branch // "n/a") | domain=\(.cloudflare.rootDomain // "n/a") | subdomain=\(.cloudflare.subdomain // "n/a") | workDir=\(.workDir // "n/a")"
  ' "$CONFIG_FILE"
fi
echo

echo "== Webhook port listening test =="

WEBHOOK_PORT=$(jq '.webhook.port // 4000' "$CONFIG_FILE" 2>/dev/null || echo 4000)
WEBHOOK_PATH=$(jq -r '.webhook.path // "/github"' "$CONFIG_FILE" 2>/dev/null || echo "/github")

echo "[*] Expected webhook port: $WEBHOOK_PORT, path: $WEBHOOK_PATH"

if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | grep -q ":$WEBHOOK_PORT "; then
    echo "[OK] Port $WEBHOOK_PORT is LISTENing according to ss -tln"
  else
    echo "[WARN] Port $WEBHOOK_PORT is NOT listed as listening in ss -tln"
  fi
else
  echo "[WARN] 'ss' not available, skipping port-listen check."
fi

if command -v nc >/dev/null 2>&1; then
  if echo -e "GET $WEBHOOK_PATH HTTP/1.0\r\n\r\n" | nc -w 2 127.0.0.1 "$WEBHOOK_PORT" >/dev/null 2>&1; then
    echo "[OK] TCP connect to 127.0.0.1:$WEBHOOK_PORT succeeded (nc)"
  else
    echo "[WARN] TCP connect to 127.0.0.1:$WEBHOOK_PORT failed (nc)"
  fi
else
  echo "[WARN] 'nc' not available, skipping TCP-connect test."
fi
echo

echo "== Docker containers =="
if command -v docker >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
else
  echo "[WARN] docker not installed."
fi
echo

echo "== Listening TCP ports (filtered by webhook port) =="
if command -v ss >/dev/null 2>&1; then
  ss -tln 2>/dev/null | awk "NR==1 || /:${WEBHOOK_PORT} /"
else
  echo "[WARN] 'ss' not available."
fi
echo

echo "== Systemd services status =="

# webhook-deploy.service
if command -v systemctl >/dev/null 2>&1; then
  echo "[status] webhook-deploy.service:"
  if systemctl list-unit-files | grep -q '^webhook-deploy.service'; then
    ACTIVE=$(systemctl is-active webhook-deploy.service || echo "unknown")
    ENABLED=$(systemctl is-enabled webhook-deploy.service 2>/dev/null || echo "unknown")
    echo "  active : $ACTIVE"
    echo "  enabled: $ENABLED"
    echo "  last log (journalctl -u webhook-deploy -n 3):"
    journalctl -u webhook-deploy.service -n 3 --no-pager 2>/dev/null || echo "    (no logs)"
  else
    echo "  (service not defined)"
  fi
  echo

  echo "[status] cloudflared-*.service:"
  CF_UNITS=$(systemctl list-units 'cloudflared-*.service' --no-legend 2>/dev/null || true)
  if [ -z "$CF_UNITS" ]; then
    echo "  No active cloudflared-* units."
  else
    echo "$CF_UNITS" | awk '{printf "  %-30s %s\n", $1, $3}'
  fi
else
  echo "[WARN] systemctl not available, skipping services status."
fi

echo
echo "=== check_env.sh finished ==="
