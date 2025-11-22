#!/bin/bash
set -e

# === deploy_config.sh ===
# - Проверяет минимальное окружение (docker, jq, node/cloudflared – если есть)
# - Показывает проекты из config/projects.json
# - По каждому проекту спрашивает: запустить первый деплой или пропустить
# - Спрашивает, запускать ли webhook.js / webhook-deploy.service
# - В конце показывает краткий статус (docker / webhook / порт)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "=== deploy_config.sh ==="
echo "[deploy_config] ROOT_DIR   = $ROOT_DIR"
echo "[deploy_config] SCRIPT_DIR = $SCRIPT_DIR"
echo "[deploy_config] CONFIG_DIR = $CONFIG_DIR"
echo

# --- Минимальные проверки окружения ---

need_cmd() {
  local cmd="$1"
  local desc="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[deploy_config] ERROR: '$cmd' not found in PATH ($desc required)."
    return 1
  fi
  return 0
}

# Docker обязателен для деплоя
need_cmd docker "Docker engine" || {
  echo "[deploy_config] Aborting: docker is required."
  exit 1
}

# jq обязателен для работы с config/projects.json
need_cmd jq "JSON parsing (config/projects.json)" || {
  echo "[deploy_config] Aborting: jq is required."
  exit 1
}

# node и cloudflared – опционально, но выводим предупреждения
if ! command -v node >/dev/null 2>&1; then
  echo "[deploy_config] WARNING: 'node' not found. Webhook server (webhook.js) may not run."
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[deploy_config] WARNING: 'cloudflared' not found. Cloudflare tunnels may not work on this host."
fi

echo

# --- Проверка наличия конфига ---

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[deploy_config] ERROR: Config file not found: $CONFIG_FILE"
  echo "                 Run init.sh first: $SCRIPT_DIR/init.sh"
  exit 1
fi

echo "[deploy_config] Using config file: $CONFIG_FILE"
echo

# --- Запуск check_env.sh (если есть) для красивого резюме ---

if [ -x "$SCRIPT_DIR/check_env.sh" ]; then
  echo "[deploy_config] Running check_env.sh for summary..."
  "$SCRIPT_DIR/check_env.sh" || true
  echo
else
  echo "[deploy_config] NOTE: $SCRIPT_DIR/check_env.sh not found. Skipping extended env check."
  echo
fi

# --- Вывод краткого списка проектов ---

project_count="$(jq '(.projects // []) | length' "$CONFIG_FILE")"

echo "=== Projects in config ==="
if [ "$project_count" -eq 0 ]; then
  echo "[deploy_config] No projects defined in projects.json."
else
  jq -r '.projects[] | "- " + .name + " (branch=" + .branch + ", workDir=" + .workDir + ")"' "$CONFIG_FILE"
fi
echo

# --- Интерактивный деплой по каждому проекту ---

if [ "$project_count" -gt 0 ]; then
  i=0
  while [ "$i" -lt "$project_count" ]; do
    name="$(jq -r ".projects[$i].name" "$CONFIG_FILE")"
    workDir="$(jq -r ".projects[$i].workDir" "$CONFIG_FILE")"
    deployScript="$(jq -r ".projects[$i].deployScript" "$CONFIG_FILE")"

    echo
    echo "[deploy_config] Project #$((i+1)) / $project_count"
    echo "  Name     : $name"
    echo "  WorkDir  : $workDir"
    echo "  Script   : $deployScript"

    # Собрать deployArgs в массив (может быть пустой)
    mapfile -t DEPLOY_ARGS < <(jq -r ".projects[$i].deployArgs[]?" "$CONFIG_FILE")

    if [ "${#DEPLOY_ARGS[@]}" -gt 0 ]; then
      echo "  Args     : ${DEPLOY_ARGS[*]}"
    else
      echo "  Args     : (none)"
    fi

    read -rp "Run deploy now for '$name'? [Y/n]: " ans
    ans="${ans:-Y}"

    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if [ ! -x "$deployScript" ]; then
        echo "[deploy_config] WARNING: deploy script '$deployScript' not found or not executable. Skipping."
      else
        echo "[deploy_config] Running deploy for '$name'..."
        (
          cd "$workDir"
          "$deployScript" "${DEPLOY_ARGS[@]}"
        )
        echo "[deploy_config] Deploy for '$name' finished with exit code $?"
      fi
    else
      echo "[deploy_config] Skipping deploy for '$name'."
    fi

    i=$((i+1))
  done
fi

# --- Webhook config summary и запуск ---

echo
echo "=== Webhook config summary ==="
if jq -e '.webhook' "$CONFIG_FILE" >/dev/null 2>&1; then
  jq -r '.webhook | "- port=" + ( .port|tostring ) + ", path=" + .path + ", domain=" + .cloudflare.rootDomain + ", sub=" + .cloudflare.subdomain' "$CONFIG_FILE"
else
  echo "[deploy_config] No .webhook section in config."
fi

echo

read -rp "Start webhook server now? [Y/n]: " wans
wans="${wans:-Y}"

if [[ "$wans" =~ ^[Yy]$ ]]; then
  # Сначала пробуем systemd unit
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^webhook-deploy.service'; then
    echo "[deploy_config] Starting systemd service 'webhook-deploy.service'..."
    systemctl enable webhook-deploy.service >/dev/null 2>&1 || true
    systemctl restart webhook-deploy.service
    systemctl --no-pager status webhook-deploy.service || true
  else
    # fallback: напрямую node webhook.js
    if command -v node >/dev/null 2>&1; then
      echo "[deploy_config] systemd service not found. Starting 'node webhook.js' in background..."
      (
        cd "$ROOT_DIR"
        nohup node webhook.js >/var/log/webhook-deploy.log 2>&1 &
      )
      echo "[deploy_config] Webhook started via node (log: /var/log/webhook-deploy.log)"
    else
      echo "[deploy_config] WARNING: node is not installed. Cannot start webhook.js."
    fi
  fi
else
  echo "[deploy_config] Webhook start skipped by user."
fi

# --- Финальный статус ---

echo
echo "=== Final status ==="

echo
echo "[status] Docker containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || echo "[status] docker ps failed"

echo
if command -v systemctl >/dev/null 2>&1; then
  echo "[status] webhook-deploy.service:"
  if systemctl list-unit-files | grep -q '^webhook-deploy.service'; then
    systemctl is-enabled webhook-deploy.service 2>/dev/null || true
    systemctl is-active webhook-deploy.service 2>/dev/null || true
  else
    echo "  (service not defined)"
  fi
fi

echo
if command -v ss >/dev/null 2>&1; then
  echo "[status] Listening TCP ports (filtered by 4000):"
  ss -tlnp | grep ':4000' || echo "  Port 4000 not listening (or ss output empty)."
fi

echo
echo "=== deploy_config.sh finished ==="
