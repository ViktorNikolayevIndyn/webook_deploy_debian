#!/bin/bash
set -e

# This script enables SSH access for a non-root user:
# - installs openssh-server and sudo
# - creates or reuses a user (default: webuser)
# - sets password (with confirmation)
# - optionally adds user to sudo and docker groups
# - updates /etc/ssh/sshd_config (PasswordAuthentication, root login)
# - writes config/ssh_state.json so other scripts (check_env, install) know the SSH user
# Run as root.

# ---------- helpers ----------

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

# ---------- basic checks ----------

if [ "$EUID" -ne 0 ]; then
  echo "[ssh] This script must be run as root."
  exit 1
fi

# ---------- paths / state ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
STATE_FILE="$CONFIG_DIR/ssh_state.json"

mkdir -p "$CONFIG_DIR"

echo "=== SSH enable script ==="
echo "[ssh] ROOT_DIR   = $ROOT_DIR"
echo "[ssh] CONFIG_DIR = $CONFIG_DIR"
echo "[ssh] STATE_FILE = $STATE_FILE"
echo

# Если уже есть ssh_state.json → спросить, переиспользовать или переконфигурировать
if [ -f "$STATE_FILE" ]; then
  echo "[ssh] Found existing ssh_state.json:"
  # попробуем вытащить sshUser (jq, если есть)
  if command -v jq >/dev/null 2>&1; then
    OLD_USER="$(jq -r '.sshUser // empty' "$STATE_FILE" 2>/dev/null || true)"
  else
    OLD_USER="$(grep -oE '"sshUser"\s*:\s*"[A-Za-z0-9_-]+"' "$STATE_FILE" 2>/dev/null | sed 's/.*"sshUser"\s*:\s*"\([^"]*\)".*/\1/' || true)"
  fi

  [ -n "$OLD_USER" ] && echo "      sshUser = $OLD_USER"
  echo

  if ! ask_yes_no_default_no "[ssh] Reconfigure SSH user and update ssh_state.json?"; then
    echo "[ssh] Keeping existing SSH state, skipping SSH reconfiguration."
    echo "[ssh] Done."
    exit 0
  fi

  echo "[ssh] Proceeding with SSH reconfiguration..."
  echo
fi

# ---------- install base packages ----------

echo "[ssh] Installing openssh-server and sudo if needed..."
apt update -y
apt install -y openssh-server sudo

SSH_USER=""
USE_EXISTING=0

# ---------- ask for username ----------

while true; do
  read -r -p "[ssh] Username for SSH login [webuser]: " SSH_USER
  SSH_USER="${SSH_USER:-webuser}"

  if id "$SSH_USER" >/dev/null 2>&1; then
    echo "[ssh] User '$SSH_USER' already exists."
    if ask_yes_no_default_yes "[ssh] Use existing user '$SSH_USER'?"; then
      USE_EXISTING=1
      break
    else
      echo "[ssh] Choose another username."
    fi
  else
    break
  fi
done

# ---------- create user if needed ----------

if [ "$USE_EXISTING" -eq 0 ]; then
  echo "[ssh] Creating user '$SSH_USER'..."
  useradd -m -s /bin/bash "$SSH_USER"

  # password with confirmation
  while true; do
    echo -n "[ssh] Enter password for '$SSH_USER': "
    read -rs PASS1
    echo
    echo -n "[ssh] Repeat password: "
    read -rs PASS2
    echo

    if [ "$PASS1" != "$PASS2" ]; then
      echo "[ssh] Passwords do not match. Try again."
    elif [ -z "$PASS1" ]; then
      echo "[ssh] Password cannot be empty. Try again."
    else
      echo "$SSH_USER:$PASS1" | chpasswd
      unset PASS1 PASS2
      echo "[ssh] Password set."
      break
    fi
  done
else
  echo "[ssh] Using existing user '$SSH_USER', skipping creation."
fi

# ---------- sudo group ----------

if ask_yes_no_default_yes "[ssh] Add '$SSH_USER' to sudo group?"; then
  usermod -aG sudo "$SSH_USER"
  echo "[ssh] User '$SSH_USER' added to 'sudo' group."
else
  echo "[ssh] Skipping sudo group for '$SSH_USER'."
fi

# ---------- docker group ----------

echo "[ssh] Ensuring docker group exists..."
if ! getent group docker >/dev/null 2>&1; then
  groupadd docker
  echo "[ssh] Group 'docker' created."
fi

if ask_yes_no_default_yes "[ssh] Add '$SSH_USER' to docker group?"; then
  usermod -aG docker "$SSH_USER"
  echo "[ssh] User '$SSH_USER' added to 'docker' group."
else
  echo "[ssh] Skipping docker group for '$SSH_USER'."
fi

# ---------- sshd config ----------

SSHD_CONFIG="/etc/ssh/sshd_config"

if [ -f "$SSHD_CONFIG" ]; then
  echo "[ssh] Updating $SSHD_CONFIG ..."

  # Enable password auth
  if grep -qE '^[# ]*PasswordAuthentication' "$SSHD_CONFIG"; then
    sed -i 's/^[# ]*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
  else
    echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
  fi

  # Root login policy
  if ask_yes_no_default_yes "[ssh] Disable SSH password login for root (recommended)?"; then
    if grep -qE '^[# ]*PermitRootLogin' "$SSHD_CONFIG"; then
      sed -i 's/^[# ]*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    else
      echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
    fi
    echo "[ssh] Root password login disabled (PermitRootLogin prohibit-password)."
  else
    echo "[ssh] Keeping current root SSH login settings."
  fi

  echo "[ssh] Restarting SSH service..."
  systemctl restart ssh || systemctl restart sshd || true
else
  echo "[ssh] WARNING: $SSHD_CONFIG not found. SSH daemon config not updated."
fi

# ---------- write ssh_state.json ----------

echo
echo "[ssh] Writing SSH state to $STATE_FILE ..."

# groups as comma-separated
USER_GROUPS="$(id -nG "$SSH_USER" | tr ' ' ',')"

cat > "$STATE_FILE" <<EOF
{
  "version": "1.0.0",
  "sshUser": "$SSH_USER",
  "groups": "$USER_GROUPS",
  "timestamp": "$(date --iso-8601=seconds)",
  "host": "$(hostname)"
}
EOF

# Владелец: root, но права 640 → root читает, check_env читает, webuser не обязан.
chown root:root "$STATE_FILE"
chmod 640 "$STATE_FILE"

echo "[ssh] ssh_state.json written."

# ---------- summary ----------

echo
echo "=== SSH configuration summary ==="
echo "  User:   $SSH_USER"
echo "  id:     $(id "$SSH_USER")"
echo
echo "[ssh] Next step: test login from your workstation:"
echo "      ssh ${SSH_USER}@<SERVER_IP_OR_HOSTNAME>"
echo
echo "[ssh] If Docker commands fail for this user, re-login or run 'newgrp docker' in the session."
echo
echo "[ssh] Done."
