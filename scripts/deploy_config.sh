#!/bin/bash
set -e

echo "=== deploy_config.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

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
    # если папка не пустая, предупредим
    if [ "$(ls -A "$workDir" 2>/dev/null | wc -l)" -gt 0 ]; then
      echo "[repo] WARNING: $workDir is not empty. git clone may fail if files conflict."
    fi
    git clone "$gitUrl" "$workDir"
  else
    echo "[repo] .git exists – updating existing repo..."
  fi

  # checkout нужной ветки и обновление
  (
    cd "$workDir"
    echo "[repo] Using branch: $branch"
    git fetch --all
    git checkout "$branch"
    git pull origin "$branch"
  )
  echo "[repo] <<< Repo ready for '$name'"
  echo
}

# --- helper: ensure deploy.sh exists & executable ---
ensure_deploy_script() {
  local name="$1"
  local workDir="$2"
  local deployScript="$3"

  # если не задан путь — дефолт
  if [ -z "$deployScript" ] || [ "$deployScript" = "null" ]; then
    deployScript="$workDir/deploy.sh"
  fi

  if [ ! -f "$deployScript" ]; then
    # если есть шаблон – копируем
    if [ -f "$SCRIPT_DIR/deploy.template.sh" ]; then
      echo "[deploy] deploy.sh not found for '$name', creating from template..."
      cp "$SCRIPT_DIR/deploy.template.sh" "$deployScript"
      chmod +x "$deployScript"
    else
      echo "[deploy] ERROR: deploy script '$deployScript' not found and template missing."
      return 1
    fi
  else
    chmod +x "$deployScript"
  fi

  echo "[deploy] Using deploy script: $deployScript"
  echo "$deployScript"
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

  # deployArgs: массив
  mapfile -t deployArgs < <(echo "$project_json" | jq -r '.deployArgs[]?')

  echo "[deploy_config] Project #$((i+1)) / $projects_count"
  echo "  Name     : $name"
  echo "  WorkDir  : $workDir"
  echo "  Git URL  : $gitUrl"
  echo "  Branch   : $branch"
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

  # 1) гарантируем наличие репозитория (git clone/pull)
  ensure_repo "$name" "$gitUrl" "$branch" "$workDir"

  # 2) гарантируем наличие deploy.sh (создаём из шаблона, если нет)
  script_path=$(ensure_deploy_script "$name" "$workDir" "$deployScript") || {
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

# запуск webhook.js (опционально)
if command -v node >/dev/null 2>&1; then
  read -r -p "Start webhook server now (node webhook.js)? [Y/n]: " wans
  wans=${wans:-Y}
  if [[ "$wans" =~ ^[Yy]$ ]]; then
    if [ -f "$ROOT_DIR/webhook.js" ]; then
      echo "[deploy_config] Starting webhook.js in background..."
      nohup node "$ROOT_DIR/webhook.js" >/var/log/webhook.log 2>&1 &
      echo "[deploy_config] webhook.js started (log: /var/log/webhook.log)"
    else
      echo "[deploy_config] WARNING: webhook.js not found at $ROOT_DIR/webhook.js"
    fi
  else
    echo "[deploy_config] Skipping webhook.js start."
  fi
else
  echo "[deploy_config] WARNING: 'node' not available – webhook.js cannot be started."
fi

echo
echo "=== Final status ==="

echo
echo "[status] Docker containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "[status] Listening TCP ports (filtered by possible webhook ports):"
ss -tln 2>/dev/null | awk 'NR==1 || /:4000 /'

echo
echo "=== deploy_config.sh finished ==="
