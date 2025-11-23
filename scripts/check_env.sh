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

# --- helper: optional bin check ---
opt_warn_bin() {
  local bin="$1"
  local msg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[WARN] $bin not found: $msg"
  fi
}

# --- Binaries ---
echo "== Binaries =="

if command -v docker >/dev/null 2>&1; then
  echo "[OK]   docker binary found: $(command -v docker)"
else
  echo "[ERR]  docker not found in PATH"
fi

if command -v docker-compose >/dev/null 2>&1; then
  echo "[OK]   docker-compose found: $(command -v docker-compose)"
else
  echo "[WARN] docker-compose not found (ok if you use docker compose v2 plugin)"
fi

opt_warn_bin "cloudflared" "tunnels may not work yet"
opt_warn_bin "node" "webhook.js / node apps may not run"

if command -v curl >/dev/null 2>&1; then
  echo "[OK]   curl binary found: $(command -v curl)"
else
  echo "[WARN] curl not found (used for some tests/scripts)"
fi

if command -v jq >/dev/null 2>&1; then
  echo "[OK]   jq found (config/projects.json will be parsed nicely)"
else
  echo "[ERR]  jq not found (cannot parse JSON configs)"
fi

if command -v nc >/dev/null 2>&1; then
  echo "[OK]   nc (netcat) found – TCP test available"
else
  echo "[WARN] nc not found – TCP port test will be limited"
fi

echo

# --- Docker daemon & group ---
echo "== Docker daemon & group =="

if docker info >/dev/null 2>&1; then
  echo "[OK]   Docker daemon is reachable (docker info OK)"
else
  echo "[ERR]  Docker daemon NOT reachable (docker info failed)"
fi

if getent group docker >/dev/null 2>&1; then
  echo "[OK]   Group 'docker' exists: $(getent group docker)"
else
  echo "[WARN] Group 'docker' does not exist"
fi

echo

# --- State / version flags ---
echo "== State / version flags =="

ENV_STATE="$CONFIG_DIR/env_bootstrap.json"
SSH_STATE="$CONFIG_DIR/ssh_state.json"
PROJECTS_STATE="$CONFIG_DIR/projects_state.json"

if [ -f "$ENV_STATE" ]; then
  ver=$(jq -r '.version // "n/a"' "$ENV_STATE" 2>/dev/null || echo "n/a")
  echo "[OK]   env_bootstrap flag present: $ENV_STATE (version='$ver')"
else
  echo "[WARN] env_bootstrap.json not found (env-bootstrap may not have been run)"
fi

if [ -f "$SSH_STATE" ]; then
  ver=$(jq -r '.version // "n/a"' "$SSH_STATE" 2>/dev/null || echo "n/a")
  echo "[OK]   ssh_state flag present: $SSH_STATE (version='$ver')"
else
  echo "[WARN] ssh_state.json not found (enable_ssh.sh may not have been run)"
fi

if [ -f "$PROJECTS_STATE" ]; then
  ver=$(jq -r '.version // "n/a"' "$PROJECTS_STATE" 2>/dev/null || echo "n/a")
  cnt=$(jq -r '.projectsCount // "n/a"' "$PROJECTS_STATE" 2>/dev/null || echo "n/a")
  echo "[OK]   projects_state flag present: $PROJECTS_STATE (version='$ver', projects=$cnt)"
else
  echo "[WARN] projects_state.json not found (init.sh may not have finalized state)"
fi

echo

# --- Config summary ---
echo "== Config: $CONFIG_FILE =="

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[ERR]  Config file not found: $CONFIG_FILE"
  echo
  echo "=== check_env.sh finished ==="
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERR]  jq not available – cannot parse $CONFIG_FILE"
  echo
  echo "=== check_env.sh finished ==="
  exit 0
fi

projects_count=$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
echo "[OK]   Config file exists."
echo "[OK]   Projects count: $projects_count"
echo

# Webhook info
echo "-- Webhook config --"
has_webhook=$(jq 'has("webhook") and (.webhook|type=="object")' "$CONFIG_FILE" 2>/dev/null || echo "false")
if [ "$has_webhook" = "true" ]; then
  jq -r '
    "  port      : \(.webhook.port // "n/a")",
    "  path      : \(.webhook.path // "n/a")",
    "  domain    : \(.webhook.cloudflare.rootDomain // "n/a") (sub=\(.webhook.cloudflare.subdomain // "n/a"))",
    "  tunnel    : \(.webhook.cloudflare.tunnelName // "n/a")",
    "  protocol  : \(.webhook.cloudflare.protocol // "n/a")",
    "  localPath : \(.webhook.cloudflare.localPath // "n/a")"
  ' "$CONFIG_FILE"
else
  echo "  (no webhook config)"
fi

echo

# Projects summary
echo "-- Projects summary --"
if [ "$projects_count" -gt 0 ]; then
  jq -r '
    .projects[] |
    "- " +
    (.name // "n/a") +
    " | branch=" + (.branch // "n/a") +
    " | domain=" + (.cloudflare.rootDomain // "n/a") +
    " | subdomain=" + (.cloudflare.subdomain // "n/a") +
    " | workDir=" + (.workDir // "n/a")
  ' "$CONFIG_FILE"
else
  echo "  (no projects defined)"
fi

echo

# --- Cloudflare status block ---
echo "== Cloudflare tunnels =="

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[WARN] cloudflared not in PATH – tunnel management disabled on this host."
else
  echo "[OK]   cloudflared binary: $(command -v cloudflared)"
fi

CF_DIR="${HOME:-/root}/.cloudflared"
echo "[cf] Cloudflared dir: $CF_DIR"

if [ -d "$CF_DIR" ]; then
  creds_count=$(ls "$CF_DIR"/*.json 2>/dev/null | wc -l || echo 0)
  cfg_count=$(ls "$CF_DIR"/config-*.yml 2>/dev/null | wc -l || echo 0)
  echo "[cf] Credentials JSON files: $creds_count"
  echo "[cf] Config YAML files     : $cfg_count"
else
  echo "[cf] Directory $CF_DIR does not exist yet (no tunnels registered on this host?)."
fi

# Список tunnelName из конфига (webhook + проекты)
if command -v jq >/dev/null 2>&1; then
  tunnels_in_config=$(jq -r '
    [
      (.webhook.cloudflare.tunnelName // empty),
      (.projects[].cloudflare.tunnelName // empty)
    ]
    | map(select(. != "")) | unique[]?
  ' "$CONFIG_FILE" 2>/dev/null || true)

  if [ -z "$tunnels_in_config" ]; then
    echo "[cf] No tunnelName defined in projects.json (webhook/projects)."
  else
    echo "[cf] Tunnels referenced in config:"
    echo "$tunnels_in_config" | while read -r t; do
      [ -z "$t" ] && continue
      cred_ok="NO"
      cfg_ok="NO"

      if [ -f "$CF_DIR/$t.json" ]; then
        cred_ok="YES"
      fi

      # ищем config-<t>.yml или config-<t>-*.yml
      cfg_file=$(ls "$CF_DIR"/config-"$t"*.yml 2>/dev/null | head -n1 || true)
      if [ -n "$cfg_file" ]; then
        cfg_ok="YES"
      fi

      echo "  - tunnelName='$t' | credentials.json: $cred_ok | config-yml: $cfg_ok"
    done
  fi
else
  echo "[cf] jq not available – cannot read tunnels from config."
fi

echo

# --- Webhook port listening test ---
echo "== Webhook port listening test =="

WEBHOOK_PORT=$(jq -r '.webhook.port // 4000' "$CONFIG_FILE" 2>/dev/null || echo 4000)
WEBHOOK_PATH=$(jq -r '.webhook.path // "/github"' "$CONFIG_FILE" 2>/dev/null || echo "/github")

echo "[*] Expected webhook port: $WEBHOOK_PORT, path: $WEBHOOK_PATH"

if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | grep -q ":$WEBHOOK_PORT "; then
    echo "[OK] Port $WEBHOOK_PORT is listening (ss)."
  else
    echo "[WARN] Port $WEBHOOK_PORT is NOT listed as listening in ss -tln"
  fi
else
  echo "[WARN] ss not available – skipping listening check."
fi

if command -v nc >/dev/null 2>&1; then
  if echo -e "GET $WEBHOOK_PATH HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 2 127.0.0.1 "$WEBHOOK_PORT" >/dev/null 2>&1; then
    echo "[OK] TCP connect to 127.0.0.1:$WEBHOOK_PORT succeeded (nc)."
  else
    echo "[WARN] TCP connect to 127.0.0.1:$WEBHOOK_PORT failed (nc)."
  fi
else
  echo "[WARN] nc not available – skipping TCP connect test."
fi

echo
echo "=== check_env.sh finished ==="
