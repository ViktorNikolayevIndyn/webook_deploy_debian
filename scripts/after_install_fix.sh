#!/bin/bash
set -e

echo "=== after_install_fix.sh ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
SSH_STATE="$CONFIG_DIR/ssh_state.json"
PROJECTS_FILE="$CONFIG_DIR/projects.json"

echo "[after] ROOT_DIR    = $ROOT_DIR"
echo "[after] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[after] CONFIG_DIR  = $CONFIG_DIR"
echo "[after] SSH_STATE   = $SSH_STATE"
echo "[after] PROJECTS    = $PROJECTS_FILE"
echo

# jq должен быть, но если нет — просто выходим без падения
if ! command -v jq >/dev/null 2>&1; then
  echo "[after] WARNING: jq not found. Skipping permission fix."
  exit 0
fi

if [ ! -f "$SSH_STATE" ]; then
  echo "[after] WARNING: $SSH_STATE not found. Skipping permission fix."
  exit 0
fi

# читаем sshUser и строку групп
sshUser="$(jq -r '.sshUser // empty' "$SSH_STATE")"
groupsStr="$(jq -r '.groups // empty' "$SSH_STATE")"

if [ -z "$sshUser" ]; then
  echo "[after] WARNING: sshUser not found in ssh_state.json. Skipping."
  exit 0
fi

# первая группа из списка "webuser,sudo,docker"
primaryGroup="$(echo "$groupsStr" | cut -d',' -f1)"
if [ -z "$primaryGroup" ]; then
  primaryGroup="$sshUser"
fi

# проверяем, что пользователь и группа существуют
if ! id "$sshUser" >/dev/null 2>&1; then
  echo "[after] WARNING: system user '$sshUser' not found. Skipping."
  exit 0
fi

if ! getent group "$primaryGroup" >/dev/null 2>&1; then
  echo "[after] WARNING: primary group '$primaryGroup' not found. Using user group '$sshUser'."
  primaryGroup="$sshUser"
fi

echo "[after] Using sshUser='$sshUser', primaryGroup='$primaryGroup'"
echo

# читаем workDir всех проектов из projects.json
workDirs=()
if [ -f "$PROJECTS_FILE" ]; then
  mapfile -t workDirs < <(jq -r '.projects[]?.workDir // empty' "$PROJECTS_FILE")
else
  echo "[after] WARNING: $PROJECTS_FILE not found. No workDirs to fix."
fi

if [ "${#workDirs[@]}" -eq 0 ]; then
  echo "[after] No workDirs found in projects.json. Nothing to chown."
  echo "=== after_install_fix.sh finished ==="
  exit 0
fi

# проходим по каждому workDir
for wd in "${workDirs[@]}"; do
  [ -z "$wd" ] && continue

  echo "[after] Processing workDir: $wd"

  if [ -d "$wd" ]; then
    echo "[after]  -> chown -R ${sshUser}:${primaryGroup} $wd"
    chown -R "${sshUser}:${primaryGroup}" "$wd"

    if [ -f "$wd/deploy.sh" ]; then
      echo "[after]  -> chmod +x $wd/deploy.sh"
      chmod +x "$wd/deploy.sh"
    fi
  else
    echo "[after]  NOTE: directory not found: $wd (skipping)"
  fi

  echo
done

echo "=== after_install_fix.sh finished ==="
