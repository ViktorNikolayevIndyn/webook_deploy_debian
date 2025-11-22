#!/bin/bash
set -e

# Simple environment sanity check for this repo:
# - Docker / cloudflared / node / curl
# - env/ssh/init flags + versions
# - projects.json existence + basic summary
# - webhook port listening (from config)
#
# Usage:
#   ./scripts/check_env.sh              # без проверки конкретного пользователя
#   ./scripts/check_env.sh webuser      # дополнительно проверит группы для webuser

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"
ENV_FLAG="$CONFIG_DIR/env_bootstrap.json"
SSH_FLAG="$CONFIG_DIR/ssh_state.json"
INIT_FLAG="$CONFIG_DIR/projects_state.json"

SSH_USER="${1:-}"   # optional: SSH user to check group membership

# ---------- helpers ----------

COLOR_OK="\033[32m"
COLOR_WARN="\033[33m"
COLOR_ERR="\033[31m"
COLOR_RESET="\033[0m"

ok()   { echo -e "${COLOR_OK}[OK]${COLOR_RESET}   $*"; }
warn() { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
err()  { echo -e "${COLOR_ERR}[ERR]${COLOR_RESET}  $*"; }

# simple JSON "version" field reader (no jq required)
get_json_version_field() {
  # $1 = path to json file
  if [ ! -f "$1" ]; then
    echo ""
    return
  fi
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

echo "=== check_env.sh ==="
echo "[*] ROOT_DIR   = $ROOT_DIR"
echo "[*] CONFIG_DIR = $CONFIG_DIR"
echo

# ---------- commands / binaries ----------

echo "== Binaries =="

if has_cmd docker; then
  ok "docker binary found: $(command -v docker)"
else
  err "docker NOT found in PATH"
fi

if has_cmd docker-compose; then
  ok "docker-compose binary found: $(command -v docker-compose)"
else
  warn "docker-compose not found (ok if you use docker compose v2 plugin)"
fi

if has_cmd cloudflared; then
  ok "cloudflared binary found: $(command -v cloudflared)"
else
  warn "cloudflared not found in PATH (tunnels may not work yet)"
fi

if has_cmd node; then
  ok "node binary found: $(command -v node)"
else
  warn "node not found in PATH (webhook.js / node apps may not run)"
fi

if has_cmd curl; then
  ok "curl binary found: $(command -v curl)"
else
  warn "curl not found in PATH"
fi

if has_cmd jq; then
  ok "jq found (config/projects.json will be parsed nicely)"
else
  warn "jq NOT found – JSON info will be very limited"
fi

echo

# ---------- Docker daemon & group ----------

echo "== Docker daemon & group =="

if has_cmd docker; then
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon is reachable (docker info OK)"
  else
    err "Docker daemon NOT reachable (docker info failed)"
  fi
else
  err "Skipping docker daemon check (docker command missing)"
fi

if getent group docker >/dev/null 2>&1; then
  ok "Group 'docker' exists: $(getent group docker)"
else
  warn "Group 'docker' does NOT exist"
fi

if [ -n "$SSH_USER" ]; then
  echo
  echo "== SSH user / groups check ($SSH_USER) =="

  if id "$SSH_USER" >/dev/null 2>&1; then
    ok "User '$SSH_USER' exists: $(id "$SSH_USER")"

    USER_GROUPS="$(id -nG "$SSH_USER" 2>/dev/null || true)"

    if echo " $USER_GROUPS " | grep -qw "sudo"; then
      ok "User '$SSH_USER' is in group 'sudo'"
    else
      warn "User '$SSH_USER' is NOT in group 'sudo'"
    fi

    if echo " $USER_GROUPS " | grep -qw "docker"; then
      ok "User '$SSH_USER' is in group 'docker'"
    else
      warn "User '$SSH_USER' is NOT in group 'docker'"
    fi
  else
    err "User '$SSH_USER' does NOT exist"
  fi
fi

echo

# ---------- Flags: env / ssh / init ----------

echo "== State / version flags =="

if [ -f "$ENV_FLAG" ]; then
  ENV_VER="$(get_json_version_field "$ENV_FLAG")"
  ok "env_bootstrap flag present: $ENV_FLAG (version='$ENV_VER')"
else
  warn "env_bootstrap flag NOT found: $ENV_FLAG  (env-bootstrap.sh may not have been run)"
fi

if [ -f "$SSH_FLAG" ]; then
  SSH_VER="$(get_json_version_field "$SSH_FLAG")"
  ok "ssh_state flag present: $SSH_FLAG (version='$SSH_VER')"
else
  warn "ssh_state flag NOT found: $SSH_FLAG (enable_ssh.sh may not have been run)"
fi

if [ -f "$INIT_FLAG" ]; then
  INIT_VER="$(get_json_version_field "$INIT_FLAG")"
  ok "projects_state flag present: $INIT_FLAG (version='$INIT_VER')"
else
  warn "projects_state flag NOT found: $INIT_FLAG (init.sh may not have been run)"
fi

echo

# ---------- projects.json & webhook summary ----------

echo "== Config: $CONFIG_FILE =="

if [ ! -f "$CONFIG_FILE" ]; then
  err "Config file not found: $CONFIG_FILE"
  echo
  echo "=== check_env.sh finished (no projects.json) ==="
  exit 0
fi

ok "Config file exists."

if has_cmd jq; then
  PROJECT_COUNT="$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  ok "Projects count: $PROJECT_COUNT"

  echo
  echo "-- Webhook config --"
  jq -r '
    .webhook as $w |
    "  port      : \($w.port // "n/a")",
    "  path      : \($w.path // "n/a")",
    "  domain    : \(($w.cloudflare.rootDomain // "n/a") + " (sub=" + ($w.cloudflare.subdomain // "n/a") + ")")",
    "  tunnel    : \($w.cloudflare.tunnelName // "n/a")",
    "  protocol  : \($w.cloudflare.protocol // "n/a")",
    "  localPath : \($w.cloudflare.localPath // "n/a")"
  ' "$CONFIG_FILE"

  echo
  echo "-- Projects summary --"
  jq -r '
    .projects[]? |
    "- " +
    (.name // "n/a") +
    " | branch=" + (.branch // "n/a") +
    " | domain=" + (.cloudflare.rootDomain // "n/a") +
    " | subdomain=" + (.cloudflare.subdomain // "n/a") +
    " | workDir=" + (.workDir // "n/a")
  ' "$CONFIG_FILE"

else
  warn "jq not available – showing raw grep on projects.json"
  grep -E '"name"|\"branch\"|\"rootDomain\"|\"subdomain\"' "$CONFIG_FILE" || true
fi

echo

# ---------- webhook port listening test ----------

echo "== Webhook port listening test =="

WEBHOOK_PORT=""
WEBHOOK_PATH="/"

if has_cmd jq; then
  WEBHOOK_PORT="$(jq -r '.webhook.port // empty' "$CONFIG_FILE" 2>/dev/null || true)"
  WEBHOOK_PATH="$(jq -r '.webhook.path // "/github"' "$CONFIG_FILE" 2>/dev/null || echo "/github")"
fi

if [ -z "$WEBHOOK_PORT" ]; then
  warn "Webhook port not found in config (or jq missing) – skipping port check."
else
  echo "[*] Expected webhook port: $WEBHOOK_PORT, path: $WEBHOOK_PATH"

  # Try ss first
  if has_cmd ss; then
    if ss -tln | grep -q ":$WEBHOOK_PORT "; then
      ok "Port $WEBHOOK_PORT appears to be LISTENING (ss -tln)"
    else
      warn "Port $WEBHOOK_PORT is NOT listed as listening in ss -tln"
    fi
  else
    warn "ss command not available, skipping LISTEN check via ss."
  fi

  # Try simple TCP connect using nc if available
  if has_cmd nc; then
    if nc -z 127.0.0.1 "$WEBHOOK_PORT" >/dev/null 2>&1; then
      ok "TCP connect to 127.0.0.1:$WEBHOOK_PORT succeeded (nc)"
    else
      warn "TCP connect to 127.0.0.1:$WEBHOOK_PORT failed (nc)"
    fi
  else
    warn "nc (netcat) not available, skipping TCP connect test."
  fi
fi

echo
echo "=== check_env.sh finished ==="
