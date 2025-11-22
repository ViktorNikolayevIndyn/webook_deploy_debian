#!/bin/bash
set -e

# Global starter for this repo.
# It:
#   - detects repo root
#   - makes all .sh scripts executable
#   - manages env-bootstrap, SSH-setup and init flags+versions under config/
#   - optionally runs:
#       1) scripts/env-bootstrap.sh   (APT, Docker, tools)
#       2) scripts/enable_ssh.sh     (SSH user, sudo, docker group, sshd_config)
#       3) scripts/init.sh           (webhook + projects.json config)
#
# Must be run as root, because env-bootstrap and enable_ssh require apt/systemd.

### Version tags – bump them when you change logic in these scripts
ENV_BOOTSTRAP_VERSION="1.0.0"
SSH_VERSION="1.0.0"
INIT_VERSION="1.0.0"

if [ "$EUID" -ne 0 ]; then
  echo "[start] This script must be run as root (needed for apt, docker, ssh)."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "[start] Root dir: $ROOT_DIR"

CONFIG_DIR="$ROOT_DIR/config"
ENV_FLAG="$CONFIG_DIR/env_bootstrap.json"
SSH_FLAG="$CONFIG_DIR/ssh_state.json"
INIT_FLAG="$CONFIG_DIR/projects_state.json"

mkdir -p "$CONFIG_DIR"

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

ask_yes_no_default_no() {
  local msg="$1"
  local ans
  read -r -p "$msg [y/N]: " ans
  ans="${ans:-N}"
  case "$ans" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

# simple JSON "version" field reader (no jq dependency required here)
get_json_version_field() {
  # $1 = path to json file
  if [ ! -f "$1" ]; then
    echo ""
    return
  fi
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

write_env_flag() {
  cat > "$ENV_FLAG" <<EOF
{
  "initialized": true,
  "version": "$ENV_BOOTSTRAP_VERSION",
  "timestamp": "$(date -Iseconds)"
}
EOF
}

write_ssh_flag() {
  cat > "$SSH_FLAG" <<EOF
{
  "initialized": true,
  "version": "$SSH_VERSION",
  "timestamp": "$(date -Iseconds)"
}
EOF
}

write_init_flag() {
  cat > "$INIT_FLAG" <<EOF
{
  "initialized": true,
  "version": "$INIT_VERSION",
  "timestamp": "$(date -Iseconds)"
}
EOF
}

echo "[start] Making shell scripts executable..."

# Mark top-level .sh as executable
find "$ROOT_DIR" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;

# Mark scripts/ .sh as executable
if [ -d "$ROOT_DIR/scripts" ]; then
  find "$ROOT_DIR/scripts" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;
fi

echo "[start] Done chmod +x on shell scripts."

############################
# 1) Environment bootstrap #
############################

if [ -x "$ROOT_DIR/scripts/env-bootstrap.sh" ]; then
  if [ -f "$ENV_FLAG" ]; then
    echo "[start] Environment flag found: $ENV_FLAG"
    OLD_ENV_VER="$(get_json_version_field "$ENV_FLAG")"
    [ -n "$OLD_ENV_VER" ] && echo "[start] Stored env-bootstrap version: $OLD_ENV_VER"

    if [ "$OLD_ENV_VER" != "$ENV_BOOTSTRAP_VERSION" ]; then
      echo "[start] env-bootstrap script version changed: '$OLD_ENV_VER' -> '$ENV_BOOTSTRAP_VERSION'"
      if ask_yes_no_default_yes "[start] Re-run env-bootstrap.sh to re-apply environment?"; then
        echo "[start] Re-initializing environment..."
        rm -f "$ENV_FLAG"
        "$ROOT_DIR/scripts/env-bootstrap.sh"
        write_env_flag
        echo "[start] Environment flag updated at $ENV_FLAG"
      else
        echo "[start] Skipping env-bootstrap (version mismatch, but user skipped)."
      fi
    else
      # same version, normal behavior: default = N
      if ask_yes_no_default_no "[start] Umgebung already initialized. Run env-bootstrap.sh again?"; then
        echo "[start] Re-running env-bootstrap.sh..."
        "$ROOT_DIR/scripts/env-bootstrap.sh"
        write_env_flag
        echo "[start] Environment flag refreshed at $ENV_FLAG"
      else
        echo "[start] Skipping env-bootstrap (existing environment kept, same version)."
      fi
    fi
  else
    # No env flag yet
    if ask_yes_no_default_yes "[start] Run scripts/env-bootstrap.sh now (APT, Docker, tools)?"; then
      echo "[start] Running scripts/env-bootstrap.sh..."
      "$ROOT_DIR/scripts/env-bootstrap.sh"
      write_env_flag
      echo "[start] Environment flag created at $ENV_FLAG"
    else
      echo "[start] Skipping env-bootstrap (no env flag created)."
    fi
  fi
else
  echo "[start] scripts/env-bootstrap.sh not found or not executable. Skipping."
fi

################
# 2) SSH setup #
################

if [ -x "$ROOT_DIR/scripts/enable_ssh.sh" ]; then
  if [ -f "$SSH_FLAG" ]; then
    echo "[start] SSH flag found: $SSH_FLAG"
    OLD_SSH_VER="$(get_json_version_field "$SSH_FLAG")"
    [ -n "$OLD_SSH_VER" ] && echo "[start] Stored SSH-setup version: $OLD_SSH_VER"

    if [ "$OLD_SSH_VER" != "$SSH_VERSION" ]; then
      echo "[start] enable_ssh script version changed: '$OLD_SSH_VER' -> '$SSH_VERSION'"
      if ask_yes_no_default_yes "[start] Re-run enable_ssh.sh to re-apply SSH/user/docker-group setup?"; then
        echo "[start] Re-running enable_ssh.sh..."
        "$ROOT_DIR/scripts/enable_ssh.sh"
        write_ssh_flag
        echo "[start] SSH flag updated at $SSH_FLAG"
      else
        echo "[start] Skipping enable_ssh.sh (version mismatch, but user skipped)."
      fi
    else
      # same version, default = N
      if ask_yes_no_default_no "[start] SSH/user/docker-group already configured. Run enable_ssh.sh again?"; then
        echo "[start] Re-running enable_ssh.sh..."
        "$ROOT_DIR/scripts/enable_ssh.sh"
        write_ssh_flag
        echo "[start] SSH flag refreshed at $SSH_FLAG"
      else
        echo "[start] Skipping enable_ssh.sh (existing SSH config kept, same version)."
      fi
    fi
  else
    # No SSH flag yet
    if ask_yes_no_default_yes "[start] Run scripts/enable_ssh.sh now (SSH user, sudo, docker group)?"; then
      echo "[start] Running scripts/enable_ssh.sh..."
      "$ROOT_DIR/scripts/enable_ssh.sh"
      write_ssh_flag
      echo "[start] SSH flag created at $SSH_FLAG"
    else
      echo "[start] Skipping enable_ssh.sh (no SSH flag created)."
    fi
  fi
else
  echo "[start] scripts/enable_ssh.sh not found or not executable. Skipping."
fi

###################################
# 3) init.sh (webhook + projects) #
###################################

if [ -x "$ROOT_DIR/scripts/init.sh" ]; then
  if [ -f "$INIT_FLAG" ]; then
    echo "[start] Init flag found: $INIT_FLAG"
    OLD_INIT_VER="$(get_json_version_field "$INIT_FLAG")"
    [ -n "$OLD_INIT_VER" ] && echo "[start] Stored init version: $OLD_INIT_VER"

    if [ "$OLD_INIT_VER" != "$INIT_VERSION" ]; then
      echo "[start] init script version changed: '$OLD_INIT_VER' -> '$INIT_VERSION'"
      if ask_yes_no_default_yes "[start] Re-run scripts/init.sh to reconfigure webhook + projects?"; then
        echo "[start] Re-running init.sh..."
        "$ROOT_DIR/scripts/init.sh"
        write_init_flag
        echo "[start] Init flag updated at $INIT_FLAG"
      else
        echo "[start] Skipping init.sh (version mismatch, but user skipped)."
      fi
    else
      # same version, default = N
      if ask_yes_no_default_no "[start] Projects/webhook already configured. Run scripts/init.sh again?"; then
        echo "[start] Re-running init.sh..."
        "$ROOT_DIR/scripts/init.sh"
        write_init_flag
        echo "[start] Init flag refreshed at $INIT_FLAG"
      else
        echo "[start] Skipping scripts/init.sh (existing config kept, same version)."
      fi
    fi
  else
    # No init flag yet
    if ask_yes_no_default_yes "[start] Run scripts/init.sh now (configure webhook + projects.json)?"; then
      echo "[start] Running scripts/init.sh..."
      "$ROOT_DIR/scripts/init.sh"
      write_init_flag
      echo "[start] Init flag created at $INIT_FLAG"
    else
      echo "[start] Skipping scripts/init.sh (no init flag created)."
    fi
  fi
else
  echo "[start] scripts/init.sh not found or not executable. Skipping."
fi

echo
echo "[start] All steps finished (or skipped)."
echo "[start] Env flag   : $ENV_FLAG"
echo "[start] SSH flag   : $SSH_FLAG"
echo "[start] Init flag  : $INIT_FLAG"
echo "[start] You can re-run ./start.sh any time."


# === FINAL INTERACTIVE DEPLOY STEP ======================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo
echo "=== Final step: optional first deploy & webhook start ==="

# 1) Лёгкая проверка, что конфиг есть
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[start] WARNING: $CONFIG_FILE not found. Skipping deploy prompts."
  exit 0
fi

# 2) Показать короткое резюме окружения (опционально)
if [ -x "$SCRIPT_DIR/check_env.sh" ]; then
  echo
  echo "[start] Running quick environment check..."
  "$SCRIPT_DIR/check_env.sh" || true
fi

echo
echo "=== Projects from config ==="
jq -r '.projects[] | "- " + .name + " (branch=" + .branch + ", workDir=" + .workDir + ")"' "$CONFIG_FILE"
echo

# 3) Для каждого проекта спросить, запускать ли деплой
project_count="$(jq '.projects | length' "$CONFIG_FILE")"

if [ "$project_count" -eq 0 ]; then
  echo "[start] No projects defined in projects.json. Skipping deploy."
else
  i=0
  while [ "$i" -lt "$project_count" ]; do
    name="$(jq -r ".projects[$i].name" "$CONFIG_FILE")"
    workDir="$(jq -r ".projects[$i].workDir" "$CONFIG_FILE")"
    deployScript="$(jq -r ".projects[$i].deployScript" "$CONFIG_FILE")"

    echo
    echo "[start] Project #$((i+1)) / $project_count"
    echo "  Name     : $name"
    echo "  WorkDir  : $workDir"
    echo "  Script   : $deployScript"

    # Собираем deployArgs в массив (может быть 0, 1 или несколько)
    mapfile -t DEPLOY_ARGS < <(jq -r ".projects[$i].deployArgs[]?" "$CONFIG_FILE")

    if [ "${#DEPLOY_ARGS[@]}" -gt 0 ]; then
      echo "  Args     : ${DEPLOY_ARGS[*]}"
    else
      echo "  Args     : (none)"
    fi

    read -rp "Run initial deploy for '$name' now? [Y/n]: " ans
    ans="${ans:-Y}"

    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if [ ! -x "$deployScript" ]; then
        echo "[start] WARNING: deploy script '$deployScript' not found or not executable, skipping."
      else
        echo "[start] Running deploy for '$name'..."
        (
          cd "$workDir"
          "$deployScript" "${DEPLOY_ARGS[@]}"
        )
        echo "[start] Deploy for '$name' finished with exit code $?"
      fi
    else
      echo "[start] Skipping deploy for '$name'."
    fi

    i=$((i+1))
  done
fi

# 4) Вопрос про запуск webhook-сервера
echo
echo "=== Webhook config summary ==="
jq -r '.webhook | "- port=" + ( .port|tostring ) + ", path=" + .path + ", domain=" + .cloudflare.rootDomain + ", sub=" + .cloudflare.subdomain' "$CONFIG_FILE"

echo
read -rp "Start webhook server now? [Y/n]: " wans
wans="${wans:-Y}"

if [[ "$wans" =~ ^[Yy]$ ]]; then
  # Если есть systemd unit - используем его
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^webhook-deploy.service'; then
    echo "[start] Starting systemd service 'webhook-deploy.service'..."
    systemctl enable webhook-deploy.service >/dev/null 2>&1 || true
    systemctl restart webhook-deploy.service
    systemctl --no-pager status webhook-deploy.service || true
  else
    # fallback: напрямую запустить node webhook.js в фоне
    if command -v node >/dev/null 2>&1; then
      echo "[start] systemd unit not found, starting 'node webhook.js' in background..."
      (
        cd "$ROOT_DIR"
        nohup node webhook.js >/var/log/webhook-deploy.log 2>&1 &
      )
      echo "[start] Webhook started via node (log: /var/log/webhook-deploy.log)"
    else
      echo "[start] WARNING: node is not installed, cannot start webhook.js."
    fi
  fi
else
  echo "[start] Webhook start skipped by user."
fi

echo
echo "=== start.sh finished ==="
