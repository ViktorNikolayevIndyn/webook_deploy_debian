#!/bin/bash
set -e

echo "=== fix_permissions.sh ==="
echo "Исправление прав доступа для webhook сервиса под webuser"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
SSH_STATE="$CONFIG_DIR/ssh_state.json"
PROJECTS_FILE="$CONFIG_DIR/projects.json"

echo "[fix] ROOT_DIR    = $ROOT_DIR"
echo "[fix] CONFIG_DIR  = $CONFIG_DIR"
echo "[fix] SSH_STATE   = $SSH_STATE"
echo "[fix] PROJECTS    = $PROJECTS_FILE"
echo

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "[fix] ERROR: This script must be run as root."
  exit 1
fi

# Проверка jq
if ! command -v jq >/dev/null 2>&1; then
  echo "[fix] ERROR: jq not found. Install it first: apt install -y jq"
  exit 1
fi

# Проверка ssh_state.json
if [ ! -f "$SSH_STATE" ]; then
  echo "[fix] ERROR: $SSH_STATE not found."
  echo "[fix]        Run enable_ssh.sh first to create SSH user."
  exit 1
fi

# Читаем SSH пользователя
SSH_USER="$(jq -r '.sshUser // empty' "$SSH_STATE" 2>/dev/null || true)"
if [ -z "$SSH_USER" ]; then
  echo "[fix] ERROR: sshUser not found in ssh_state.json"
  exit 1
fi

# Читаем группы
GROUPS_STR="$(jq -r '.groups // empty' "$SSH_STATE" 2>/dev/null || true)"
PRIMARY_GROUP="$(echo "$GROUPS_STR" | cut -d',' -f1)"
if [ -z "$PRIMARY_GROUP" ]; then
  PRIMARY_GROUP="$SSH_USER"
fi

# Проверка пользователя
if ! id "$SSH_USER" >/dev/null 2>&1; then
  echo "[fix] ERROR: system user '$SSH_USER' not found."
  exit 1
fi

echo "[fix] Using: SSH_USER='$SSH_USER', PRIMARY_GROUP='$PRIMARY_GROUP'"
echo

# ========================================
# 1. Корневая папка проекта (webhook.js, node_modules, config)
# ========================================
echo "[fix] === Fixing ROOT_DIR: $ROOT_DIR ==="
if [ -d "$ROOT_DIR" ]; then
  echo "[fix]   chown -R ${SSH_USER}:${PRIMARY_GROUP} $ROOT_DIR"
  chown -R "${SSH_USER}:${PRIMARY_GROUP}" "$ROOT_DIR" || {
    echo "[fix] ERROR: Failed to chown $ROOT_DIR"
    exit 1
  }
  
  echo "[fix]   chmod 755 $ROOT_DIR"
  chmod 755 "$ROOT_DIR"
  
  echo "[fix] ✓ ROOT_DIR ownership fixed"
else
  echo "[fix] ERROR: $ROOT_DIR not found"
  exit 1
fi
echo

# ========================================
# 2. Config директория
# ========================================
echo "[fix] === Fixing CONFIG_DIR: $CONFIG_DIR ==="
if [ -d "$CONFIG_DIR" ]; then
  echo "[fix]   chown -R ${SSH_USER}:${PRIMARY_GROUP} $CONFIG_DIR"
  chown -R "${SSH_USER}:${PRIMARY_GROUP}" "$CONFIG_DIR"
  
  echo "[fix]   chmod 750 $CONFIG_DIR"
  chmod 750 "$CONFIG_DIR"
  
  # Специальные права для projects.json (должен читаться webhook.js)
  if [ -f "$PROJECTS_FILE" ]; then
    echo "[fix]   chmod 640 $PROJECTS_FILE"
    chmod 640 "$PROJECTS_FILE"
  fi
  
  echo "[fix] ✓ CONFIG_DIR ownership fixed"
else
  echo "[fix] WARNING: $CONFIG_DIR not found"
fi
echo

# ========================================
# 3. WorkDir для каждого проекта
# ========================================
if [ ! -f "$PROJECTS_FILE" ]; then
  echo "[fix] WARNING: $PROJECTS_FILE not found. Skipping project workDirs."
else
  echo "[fix] === Fixing project workDirs from projects.json ==="
  
  mapfile -t WORK_DIRS < <(jq -r '.projects[]?.workDir // empty' "$PROJECTS_FILE")
  
  if [ "${#WORK_DIRS[@]}" -eq 0 ]; then
    echo "[fix] No workDirs found in projects.json"
  else
    for WD in "${WORK_DIRS[@]}"; do
      [ -z "$WD" ] && continue
      
      # Пропускаем ROOT_DIR, уже обработан
      if [ "$WD" = "$ROOT_DIR" ]; then
        echo "[fix]   Skipping $WD (same as ROOT_DIR)"
        continue
      fi
      
      if [ -d "$WD" ]; then
        echo "[fix]   Processing: $WD"
        echo "[fix]     chown -R ${SSH_USER}:${PRIMARY_GROUP} $WD"
        chown -R "${SSH_USER}:${PRIMARY_GROUP}" "$WD"
        
        # Делаем deploy.sh исполняемым
        if [ -f "$WD/deploy.sh" ]; then
          echo "[fix]     chmod +x $WD/deploy.sh"
          chmod +x "$WD/deploy.sh"
        fi
        
        echo "[fix]   ✓ $WD fixed"
      else
        echo "[fix]   WARNING: Directory not found: $WD"
      fi
      echo
    done
  fi
fi

# ========================================
# 4. Проверка webhook сервиса
# ========================================
echo "[fix] === Checking webhook-deploy.service ==="
SERVICE_FILE="/etc/systemd/system/webhook-deploy.service"

if [ -f "$SERVICE_FILE" ]; then
  SERVICE_USER=$(grep '^User=' "$SERVICE_FILE" | cut -d'=' -f2 || echo "unknown")
  echo "[fix] Current service user: $SERVICE_USER"
  
  if [ "$SERVICE_USER" != "$SSH_USER" ]; then
    echo "[fix] WARNING: Service runs as '$SERVICE_USER', but should run as '$SSH_USER'"
    echo "[fix]          Rerun setup_webhook_service.sh to fix."
  else
    echo "[fix] ✓ Service user is correct"
  fi
else
  echo "[fix] WARNING: webhook-deploy.service not found"
  echo "[fix]          Run setup_webhook_service.sh to create it."
fi
echo

# ========================================
# Итоги
# ========================================
echo "=== fix_permissions.sh finished ==="
echo
echo "[fix] Summary:"
echo "  ROOT_DIR ownership  : ${SSH_USER}:${PRIMARY_GROUP}"
echo "  CONFIG_DIR ownership: ${SSH_USER}:${PRIMARY_GROUP}"
echo "  Webhook service user: $SERVICE_USER"
echo
echo "[fix] Next steps:"
echo "  1. If service user is wrong, run: ./scripts/setup_webhook_service.sh"
echo "  2. Restart webhook service: systemctl restart webhook-deploy.service"
echo "  3. Check status: systemctl status webhook-deploy.service"
echo "  4. Check logs: journalctl -u webhook-deploy.service -n 50"
echo
