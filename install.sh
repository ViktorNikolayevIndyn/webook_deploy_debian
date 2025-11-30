#!/bin/bash
set -e

echo "=== install.sh ==="

if [ "$EUID" -ne 0 ]; then
    echo "[install] This script must be run as root."
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
CONFIG_DIR="$ROOT_DIR/config"
SSH_STATE_FILE="$CONFIG_DIR/ssh_state.json"

echo "[install] ROOT_DIR   = $ROOT_DIR"
echo "[install] SCRIPT_DIR = $SCRIPT_DIR"
echo "[install] CONFIG_DIR = $CONFIG_DIR"
echo

mkdir -p "$CONFIG_DIR"

# --- Check/setup webuser and groups FIRST ---
echo "[install] Checking webhook user and groups..."

# Determine webhook user from existing config or use default
WEBHOOK_USER="webuser"
if [ -f "$SSH_STATE_FILE" ]; then
    WEBHOOK_USER=$(jq -r '.sshUser // "webuser"' "$SSH_STATE_FILE" 2>/dev/null || echo "webuser")
fi

# Check if user exists
if id "$WEBHOOK_USER" >/dev/null 2>&1; then
    echo "[install] ✓ User '$WEBHOOK_USER' exists"
    
    # Check groups
    NEEDS_GROUPS=0
    if ! groups "$WEBHOOK_USER" | grep -q '\bsudo\b'; then
        echo "[install] Adding '$WEBHOOK_USER' to sudo group..."
        usermod -aG sudo "$WEBHOOK_USER"
        NEEDS_GROUPS=1
    fi
    
    if ! groups "$WEBHOOK_USER" | grep -q '\bdocker\b'; then
        echo "[install] Adding '$WEBHOOK_USER' to docker group..."
        usermod -aG docker "$WEBHOOK_USER"
        NEEDS_GROUPS=1
    fi
    
    if [ "$NEEDS_GROUPS" -eq 0 ]; then
        echo "[install] ✓ User '$WEBHOOK_USER' already in sudo and docker groups"
    else
        echo "[install] ✓ Groups updated for '$WEBHOOK_USER'"
    fi
else
    echo "[install] ⚠ User '$WEBHOOK_USER' does not exist"
    echo "[install] Will be created during enable_ssh.sh"
fi

echo

# --- Cleaned Function 1 ---
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
# --- Cleaned Function 2 ---
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

need_bin() {
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "[cf] ERROR: '$bin' not found in PATH. Aborting."
        exit 1
    fi
}

need_bin jq

if [ -d "$SCRIPT_DIR" ]; then
    echo "[install] Making all scripts in $SCRIPT_DIR executable..."
    find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} \;
    echo "[install] chmod +x done."
    echo
fi

# 1) env-bootstrap (умgebung)
if [ -x "$SCRIPT_DIR/env-bootstrap.sh" ]; then
    if ask_yes_no_default_yes "[install] Run env-bootstrap.sh (packages, Docker install)?"; then
        "$SCRIPT_DIR/env-bootstrap.sh"
    else
        echo "[install] Skipping env-bootstrap.sh."
    fi
else
    echo "[install] WARNING: $SCRIPT_DIR/env-bootstrap.sh not found or not executable. Skipping env bootstrap."
fi
echo

# 2) enable_ssh
SSH_USER=""
if [ -x "$SCRIPT_DIR/enable_ssh.sh" ]; then
    if ask_yes_no_default_yes "[install] Run enable_ssh.sh (SSH user / sudo / docker group)?"; then
        "$SCRIPT_DIR/enable_ssh.sh"

        # --- АВТОМАТИЧЕСКОЕ ЧТЕНИЕ ИМЕНИ ПОЛЬЗОВАТЕЛЯ ИЗ SSH_STATE.JSON ---
        if [ -f "$SSH_STATE_FILE" ]; then
            SSH_USER=$(jq -r '.sshUser // empty' "$SSH_STATE_FILE" 2>/dev/null || true)
            if [ -n "$SSH_USER" ]; then
                echo "[install] Detected SSH user for ownership change: $SSH_USER"
            else
                echo "[install] WARNING: Found $SSH_STATE_FILE but sshUser field is empty."
            fi
        else
            echo "[install] WARNING: SSH state file not found at $SSH_STATE_FILE."
        fi
        # ------------------------------------------------------------------
    else
        echo "[install] Skipping enable_ssh.sh."
    fi
else
    echo "[install] WARNING: $SCRIPT_DIR/enable_ssh.sh not found or not executable. Skipping SSH setup."
fi
echo

# 3) init.sh (webhook + projects.json)
if [ -x "$SCRIPT_DIR/init.sh" ]; then
    if ask_yes_no_default_yes "[install] Run init.sh (configure webhook + projects)?"; then
        "$SCRIPT_DIR/init.sh"
    else
        echo "[install] Skipping init.sh."
    fi
else
    echo "[install] WARNING: $SCRIPT_DIR/init.sh not found or not executable. Skipping init.sh."
fi
echo

echo "[install] Base installation phase finished."
echo "         Config dir: $CONFIG_DIR"
echo "         You can inspect config/projects.json if needed."
echo

# 4) deploy_config.sh (деплой проектов + запуск webhook.js)
if [ -x "$SCRIPT_DIR/deploy_config.sh" ]; then
    if ask_yes_no_default_yes "[install] Run deploy_config.sh now (deploy projects & start webhook)?"; then
        echo "[install] Starting deploy_config.sh..."
        "$SCRIPT_DIR/deploy_config.sh"
    else
        echo "[install] Skipping deploy_config.sh."
    fi
else
    echo "[install] NOTE: scripts/deploy_config.sh not found yet."
    echo "       Once you add it, you can run: $SCRIPT_DIR/deploy_config.sh"
fi

echo

# 5) sync_cloudflare.sh (туннели + systemd)
if [ -x "$SCRIPT_DIR/sync_cloudflare.sh" ]; then
    if ask_yes_no_default_yes "[install] Run sync_cloudflare.sh now (tunnels + systemd units)?"; then
        echo "[install] Starting sync_cloudflare.sh..."
        "$SCRIPT_DIR/sync_cloudflare.sh"
    else
        echo "[install] Skipping sync_cloudflare.sh."
    fi
else
    echo "[install] NOTE: scripts/sync_cloudflare.sh not found. Cloudflare tunnels not auto-synced."
fi

echo

# 6) sync_cloudflare_dns.sh (DNS маршруты)
if [ -x "$SCRIPT_DIR/sync_cloudflare_dns.sh" ]; then
    if ask_yes_no_default_yes "[install] Run sync_cloudflare_dns.sh now (Cloudflare DNS routes)?"; then
        echo "[install] Starting sync_cloudflare_dns.sh..."
        "$SCRIPT_DIR/sync_cloudflare_dns.sh"
    else
        echo "[install] Skipping sync_cloudflare_dns.sh."
    fi
else
    echo "[install] NOTE: scripts/sync_cloudflare_dns.sh not found. DNS routes not auto-synced."
fi

echo
echo "[install] Final environment check (check_env.sh)..."
if [ -x "$SCRIPT_DIR/check_env.sh" ]; then
    "$SCRIPT_DIR/check_env.sh"
else
    echo "[install] WARNING: check_env.sh not found."
fi

echo
# ----------------------------------------------------------------------
## 🔑 Смена владельца рабочего каталога (Автоматическое решение проблемы прав)
# ----------------------------------------------------------------------

if [ -n "$SSH_USER" ]; then
    echo "[install] Collecting all unique work directories from projects.json..."
    
    # Находим все уникальные workDir из всех проектов
    WORK_DIRS=$(jq -r '
        # Собираем все workDir из массива projects
        .projects[]?.workDir
        | select(. != null and . != "")
    ' "$CONFIG_DIR/projects.json" 2>/dev/null || true)
    
    # Добавляем корневой каталог самого установщика (где лежит webhook.js и конфиги)
    WORK_DIRS="$WORK_DIRS $ROOT_DIR"
    
    # Убираем дубликаты и очищаем список (на случай, если workDir совпадает с ROOT_DIR)
    WORK_DIRS=$(echo "$WORK_DIRS" | tr ' ' '\n' | sort -u || true)

    if [ -z "$WORK_DIRS" ]; then
        echo "[install] WARNING: No valid workDir paths found in projects.json to change ownership."
    else
        echo "[install] Changing ownership of deployment directories to '$SSH_USER'..."
        
        for DIR in $WORK_DIRS; do
            if [ -d "$DIR" ]; then
                echo "[install]   > chown -R $SSH_USER:$SSH_USER $DIR"
                chown -R "$SSH_USER":"$SSH_USER" "$DIR" || {
                    echo "[install] ERROR: Failed to change ownership for $DIR. Check if user '$SSH_USER' exists."
                }
            else
                echo "[install]   > WARNING: Work directory $DIR not found (Skipping)."
            fi
        done
        
        echo "[install] Ownership change complete for all configured project directories."
    fi
else
    echo "[install] Skipping final ownership change: SSH user name could not be determined."
fi

# Offer to switch to webhook user and run deploy_config.sh
if [ -f "$SSH_STATE_FILE" ]; then
  SSH_USER=$(jq -r '.sshUser // empty' "$SSH_STATE_FILE" 2>/dev/null)
  
  if [ -n "$SSH_USER" ] && id "$SSH_USER" >/dev/null 2>&1; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Deploy projects as webhook user                              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo
    read -r -p "Switch to '$SSH_USER' and run deploy_config.sh now? [Y/n]: " SWITCH_USER
    SWITCH_USER=${SWITCH_USER:-Y}
    
    if [[ "$SWITCH_USER" =~ ^[Yy]$ ]]; then
      echo
      echo "[install] Switching to user '$SSH_USER' and running deploy_config.sh..."
      echo
      # Run as SSH_USER, then return to root for final cleanup
      su - "$SSH_USER" -c "cd '$SCRIPT_DIR' && bash deploy_config.sh"
      
      # Back to root - fix permissions and start services
      echo
      echo "=== Final cleanup (as root) ==="
      
      if [ -x "$SCRIPT_DIR/after_install_fix.sh" ]; then
        echo "[install] Fixing all permissions..."
        "$SCRIPT_DIR/after_install_fix.sh"
      fi
      
      # Start/restart webhook service
      if systemctl list-unit-files | grep -q webhook-deploy.service; then
        echo "[install] Starting webhook-deploy.service..."
        systemctl restart webhook-deploy.service
        systemctl enable webhook-deploy.service
        
        if systemctl is-active --quiet webhook-deploy.service; then
          echo "[install] ✓ Webhook service is running"
        else
          echo "[install] ✗ Webhook service failed to start"
          systemctl status webhook-deploy.service --no-pager -n 10
        fi
      fi
      
      echo
      echo "=== install.sh finished ==="
    else
      echo
      echo "[install] Skipped. Run manually:"
      echo "  sudo -u $SSH_USER $SCRIPT_DIR/deploy_config.sh"
      echo "  sudo $SCRIPT_DIR/after_install_fix.sh"
    fi
  fi
fi

echo
echo
echo "✓ Installation complete!"
echo
echo "📚 Documentation:"
echo "  - README.md              : Full documentation"
echo "  - README-lite.md         : Quick start guide"
echo "  - FAST-DEPLOY-RU.md      : Оптимизация деплоя (на русском)"
echo "  - OPTIMIZATION.md        : Performance tuning details"
echo
echo "⚡ Performance:"
echo "  Your deploy.sh includes smart change detection:"
echo "  - Code changes only → 5-10 seconds (60x faster)"
echo "  - Dependencies changed → 2-3 minutes (2x faster)"
echo "  - No changes → instant skip"
echo
echo "🔧 Useful commands:"
echo "  - Check environment  : ./scripts/check_env.sh"
echo "  - Fix permissions    : sudo ./scripts/fix_permissions.sh"
echo "  - Optimizations already included in deploy.template.sh"
echo "  - Restart webhook    : sudo systemctl restart webhook-deploy.service"
echo "  - View logs          : journalctl -u webhook-deploy.service -f"
echo