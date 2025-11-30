#!/bin/bash
set -e

echo "=== deploy_config.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"
SSH_STATE_FILE="$CONFIG_DIR/ssh_state.json"

# Check if running as root - offer to switch to webhook user
if [ "$(id -u)" -eq 0 ]; then
  echo "[deploy_config] WARNING: Running as root!"
  echo "[deploy_config] Recommendation: Run this script as the same user that runs webhook service."
  echo "[deploy_config] This ensures all files have correct ownership for webhook operations."
  echo
  
  # Try to read webhook user from config
  WEBHOOK_USER=""
  if [ -f "$SSH_STATE_FILE" ]; then
    WEBHOOK_USER=$(jq -r '.sshUser // empty' "$SSH_STATE_FILE" 2>/dev/null)
  fi
  
  if [ -n "$WEBHOOK_USER" ] && id "$WEBHOOK_USER" >/dev/null 2>&1; then
    echo "[deploy_config] Options:"
    echo "  Y - Switch to '$WEBHOOK_USER' (recommended for webhook operations)"
    echo "  n - Continue as root (will fix permissions automatically)"
    read -r -p "[deploy_config] Switch to user '$WEBHOOK_USER'? [Y/n]: " SWITCH_USER
    SWITCH_USER=${SWITCH_USER:-Y}
    
    if [[ "$SWITCH_USER" =~ ^[Yy]$ ]]; then
      echo "[deploy_config] Switching to '$WEBHOOK_USER'..."
      exec su - "$WEBHOOK_USER" -c "cd '$SCRIPT_DIR' && bash deploy_config.sh"
    else
      echo "[deploy_config] Continuing as root - permissions will be fixed automatically"
      echo
    fi
  else
    echo "[deploy_config] No webhook user found, continuing as root"
    echo
  fi
fi

echo "[deploy_config] Current user: $(whoami)"
echo "[deploy_config] ROOT_DIR   = $ROOT_DIR"
echo "[deploy_config] SCRIPT_DIR = $SCRIPT_DIR"
echo "[deploy_config] CONFIG_DIR = $CONFIG_DIR"
echo

# --- helper: check binaries ---
need_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[deploy_config] ERROR: '$bin' not found in PATH. Aborting."
    exit 1
  fi
}

opt_warn_bin() {
  local bin="$1"
  local msg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[deploy_config] WARNING: '$bin' not found. $msg"
  fi
}

# обязательные
need_bin jq
need_bin docker
need_bin git

# опциональные
opt_warn_bin node "Webhook server (webhook.js) may not run."
opt_warn_bin cloudflared "Cloudflare tunnels may not work on this host."

echo "[deploy_config] Using config file: $CONFIG_FILE"
echo

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[deploy_config] ERROR: config file not found: $CONFIG_FILE"
  exit 1
fi

# --- опционально вызвать check_env.sh для статуса ---
if [ -x "$SCRIPT_DIR/check_env.sh" ]; then
  echo "[deploy_config] Running check_env.sh for summary..."
  "$SCRIPT_DIR/check_env.sh"
  echo
fi

# --- читаем проекты из config/projects.json ---
projects_count=$(jq '.projects | length' "$CONFIG_FILE")
if [ "$projects_count" -eq 0 ]; then
  echo "[deploy_config] No projects defined in $CONFIG_FILE"
  exit 0
fi

echo "=== Projects in config ==="
jq -r '.projects[] | "- \(.name) (branch=\(.branch), workDir=\(.workDir))"' "$CONFIG_FILE"
echo

# --- helper: ensure repo in workDir ---
ensure_repo() {
  local name="$1"
  local gitUrl="$2"
  local branch="$3"
  local workDir="$4"

  echo "[repo] >>> Project '$name' – ensure repo in $workDir"
  mkdir -p "$workDir"

  if [ ! -d "$workDir/.git" ]; then
    echo "[repo] No .git in $workDir – cloning..."
    if [ "$(ls -A "$workDir" 2>/dev/null | wc -l)" -gt 0 ]; then
      echo "[repo] WARNING: $workDir is not empty. git clone may fail if files conflict."
    fi
    git clone "$gitUrl" "$workDir"
  else
    echo "[repo] .git exists – updating existing repo..."
  fi

  # помечаем каталог как безопасный для текущего пользователя (root),
  # чтобы не ловить "detected dubious ownership"
  git config --global --add safe.directory "$workDir" 2>/dev/null || true

  local rc=0
  (
    cd "$workDir"
    set +e
    echo "[repo] Using branch: $branch"
    git fetch --all
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "[repo] ERROR: git fetch failed (code $rc) in $workDir"
      exit $rc
    fi

    git checkout "$branch"
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "[repo] ERROR: git checkout '$branch' failed (code $rc) in $workDir"
      exit $rc
    fi

    # Reset any local changes before pull
    echo "[repo] Resetting local changes..."
    git reset --hard HEAD
    git clean -fd

    git pull origin "$branch"
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "[repo] ERROR: git pull origin '$branch' failed (code $rc) in $workDir"
      exit $rc
    fi

    exit 0
  )
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "[repo] <<< Git operations for '$name' FAILED with code $rc"
    return $rc
  fi

  echo "[repo] <<< Repo ready for '$name'"
  echo
  return 0
}

# --- helper: ensure deploy.sh exists & executable ---
ensure_deploy_script() {
  local name="$1"
  local workDir="$2"
  local deployScript="$3"
  local deployArgs="$4"  # Check if first arg is a port number (static project)

  # если не задан путь — дефолт
  if [ -z "$deployScript" ] || [ "$deployScript" = "null" ]; then
    deployScript="$workDir/deploy.sh"
  fi

  if [ ! -f "$deployScript" ]; then
    # Determine project type by checking if deployArgs is a port number
    local templateFile="$SCRIPT_DIR/deploy.template.sh"
    
    if [[ "$deployArgs" =~ ^[0-9]+$ ]]; then
      # Static project (deployArgs is a port number)
      if [ -f "$SCRIPT_DIR/deploy-static.template.sh" ]; then
        templateFile="$SCRIPT_DIR/deploy-static.template.sh"
        echo "[deploy] Static project detected, using deploy-static.template.sh..." >&2
      fi
    fi
    
    # если есть шаблон – копируем
    if [ -f "$templateFile" ]; then
      echo "[deploy] deploy.sh not found for '$name', creating from template..." >&2
      mkdir -p "$workDir"
      cp "$templateFile" "$deployScript"
      chmod +x "$deployScript"
    else
      echo "[deploy] ERROR: deploy script '$deployScript' not found and template missing." >&2
      return 1
    fi
  else
    chmod +x "$deployScript"
  fi

  # лог в stderr, путь — в stdout (для переменной)
  echo "[deploy] Using deploy script: $deployScript" >&2
  printf '%s\n' "$deployScript"
}


# --- helper: run deploy.sh with args ---
run_deploy() {
  local name="$1"
  local workDir="$2"
  local deployScript="$3"
  shift 3
  local args=("$@")

  echo "[deploy_config] Running deploy for '$name'..."
  echo "[deploy_config] WorkDir: $workDir"
  echo "[deploy_config] Script : $deployScript"
  echo "[deploy_config] Args   : ${args[*]:-(none)}"
  echo

  (
    cd "$workDir"
    "$deployScript" "${args[@]}"
  )

  echo "[deploy_config] Deploy finished for '$name'"
  echo
}

# --- цикл по проектам ---
for i in $(seq 0 $((projects_count - 1))); do
  project_json=$(jq ".projects[$i]" "$CONFIG_FILE")

  name=$(echo "$project_json"       | jq -r '.name')
  gitUrl=$(echo "$project_json"     | jq -r '.gitUrl')
  branch=$(echo "$project_json"     | jq -r '.branch')
  workDir=$(echo "$project_json"    | jq -r '.workDir')
  deployScript=$(echo "$project_json" | jq -r '.deployScript // empty')

  mapfile -t deployArgs < <(echo "$project_json" | jq -r '.deployArgs[]?')

  # для статуса удобно ещё порт показывать
  port=$(echo "$project_json" | jq -r '.cloudflare.localPort // "n/a"')

  echo "[deploy_config] Project #$((i+1)) / $projects_count"
  echo "  Name     : $name"
  echo "  WorkDir  : $workDir"
  echo "  Git URL  : $gitUrl"
  echo "  Branch   : $branch"
  echo "  Port     : $port"
  echo "  Script   : ${deployScript:-$workDir/deploy.sh}"
  echo "  Args     : ${deployArgs[*]:-(none)}"
  echo

  read -r -p "Run full deploy (clone/pull + deploy.sh) now for '$name'? [Y/n]: " ans
  ans=${ans:-Y}
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[deploy_config] Skipping '$name' by user choice."
    echo
    continue
  fi

  # 1) гарантируем наличие репозитория
  if ! ensure_repo "$name" "$gitUrl" "$branch" "$workDir"; then
    echo
    read -r -p "[deploy_config] Git error for '$name'. Try again? [y/N]: " retry
    retry=${retry:-N}
    if [[ "$retry" =~ ^[Yy]$ ]]; then
      echo "[deploy_config] Retrying ensure_repo for '$name'..."
      if ! ensure_repo "$name" "$gitUrl" "$branch" "$workDir"; then
        echo "[deploy_config] Still failing. Skipping '$name'."
        echo
        continue
      fi
    else
      echo "[deploy_config] Skipping '$name' due to git error."
      echo
      continue
    fi
  fi

  # 2) гарантируем наличие deploy.sh
  # Pass first deployArg to detect static projects
  firstArg="${deployArgs[0]:-}"
  script_path=$(ensure_deploy_script "$name" "$workDir" "$deployScript" "$firstArg") || {
    echo "[deploy_config] ERROR: cannot deploy '$name' (no deploy script)."
    echo
    continue
  }

  # 3) запускаем deploy.sh
  run_deploy "$name" "$workDir" "$script_path" "${deployArgs[@]}"
done

echo "=== Webhook config summary ==="
jq -r '
  if .webhook then
    "- port=\(.webhook.port), path=\(.webhook.path), domain=\(.webhook.cloudflare.rootDomain // "n/a"), sub=\(.webhook.cloudflare.subdomain // "n/a")"
  else
    "no webhook config"
  end
' "$CONFIG_FILE"
echo

echo "[deploy_config] NOTE: Webhook server is managed by systemd (webhook-deploy.service)."
echo "[deploy_config] To restart it manually:"
echo "  sudo systemctl restart webhook-deploy.service"
echo "Logs:"
echo "  journalctl -u webhook-deploy.service -n 20 -f"

echo
echo "=== Final status ==="

echo
echo "[status] Docker containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "[status] Python HTTP servers (static projects):"
ps aux | grep -E '[p]ython3 -m http.server' | awk '{print "  PID: " $2 " | Port: " $NF " | User: " $1}'

echo
echo "[status] Listening TCP ports (common app ports):"
ss -tln 2>/dev/null | awk 'NR==1 || /:300[0-9]/ || /:400[0-9]/ || /:500[0-9]/'

echo
echo "=== Fixing permissions ==="
if [ -x "$SCRIPT_DIR/after_install_fix.sh" ]; then
  # after_install_fix.sh needs root for chown
  if [ "$(id -u)" -eq 0 ]; then
    "$SCRIPT_DIR/after_install_fix.sh"
  else
    echo "[deploy_config] Checking if sudo works without password..."
    if sudo -n true 2>/dev/null; then
      echo "[deploy_config] Running after_install_fix.sh with sudo..."
      sudo "$SCRIPT_DIR/after_install_fix.sh"
    else
      echo "[deploy_config] NOTE: sudo requires password (skipping permission fix)"
      echo "[deploy_config] Run manually with root: sudo $SCRIPT_DIR/after_install_fix.sh"
    fi
  fi
else
  echo "[deploy_config] WARNING: after_install_fix.sh not found or not executable"
fi

echo
echo "=== Restarting webhook service ==="

# Prepare sudo if not root
SUDO_CMD=""
CAN_USE_SUDO=0

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
      SUDO_CMD="sudo"
      CAN_USE_SUDO=1
    else
      echo "[deploy_config] NOTE: sudo requires password (skipping service restart)"
      echo "[deploy_config] Restart manually: sudo systemctl restart webhook-deploy.service"
    fi
  else
    echo "[deploy_config] WARNING: Not running as root and sudo not available"
  fi
else
  CAN_USE_SUDO=1
fi

if [ "$CAN_USE_SUDO" -eq 1 ]; then
  if $SUDO_CMD systemctl is-active --quiet webhook-deploy.service 2>/dev/null; then
    echo "[deploy_config] Restarting webhook-deploy.service..."
    $SUDO_CMD systemctl restart webhook-deploy.service
    sleep 2
    if $SUDO_CMD systemctl is-active --quiet webhook-deploy.service; then
      echo "[deploy_config] ✓ webhook-deploy.service restarted successfully"
    else
      echo "[deploy_config] ✗ ERROR: webhook-deploy.service failed to start"
      $SUDO_CMD systemctl status webhook-deploy.service --no-pager -n 10
    fi
  else
    echo "[deploy_config] NOTE: webhook-deploy.service not running"
  fi
fi

echo
echo "=== deploy_config.sh finished ==="
