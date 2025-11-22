#!/bin/bash
set -e

# check_install_node.sh
# Проверяет наличие node и npm.
# Если чего-то нет — устанавливает через apt-get (Debian/Ubuntu).

echo "=== check_install_node.sh ==="

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[check] ROOT_DIR = $ROOT_DIR"

# --- проверка root ---

if [ "$(id -u)" -ne 0 ]; then
  echo "[check] WARNING: not running as root. Auto-install via apt-get will not work."
  echo "[check] You can still install manually: apt-get update && apt-get install -y nodejs npm"
  exit 0
fi

# --- проверка apt-get ---

if ! command -v apt-get >/dev/null 2>&1; then
  echo "[check] WARNING: apt-get not found. This script only supports Debian/Ubuntu."
  exit 0
fi

HAS_NODE=0
HAS_NPM=0

# --- node ---

if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node -v 2>/dev/null || echo 'unknown')"
  echo "[check] Node.js already installed: $NODE_VER"
  HAS_NODE=1
else
  echo "[check] Node.js not found."
fi

# --- npm ---

if command -v npm >/dev/null 2>&1; then
  NPM_VER="$(npm -v 2>/dev/null || echo 'unknown')"
  echo "[check] npm already installed: $NPM_VER"
  HAS_NPM=1
else
  echo "[check] npm not found."
fi

# --- установка, если нужно ---

if [ "$HAS_NODE" -eq 1 ] && [ "$HAS_NPM" -eq 1 ]; then
  echo "[check] Nothing to install. Node.js and npm already present."
  echo "=== check_install_node.sh finished ==="
  exit 0
fi

echo "[check] Updating apt package index..."
apt-get update -y

if [ "$HAS_NODE" -eq 0 ] && [ "$HAS_NPM" -eq 0 ]; then
  echo "[check] Installing nodejs and npm..."
  apt-get install -y nodejs npm
elif [ "$HAS_NODE" -eq 1 ] && [ "$HAS_NPM" -eq 0 ]; then
  echo "[check] Installing npm..."
  apt-get install -y npm
elif [ "$HAS_NODE" -eq 0 ] && [ "$HAS_NPM" -eq 1 ]; then
  echo "[check] Installing nodejs..."
  apt-get install -y nodejs
fi

# --- финальная проверка ---

if command -v node >/dev/null 2>&1; then
  echo "[check] Node.js installed OK: $(node -v 2>/dev/null || echo 'unknown')"
else
  echo "[check] ERROR: Node.js still not found after installation attempt."
fi

if command -v npm >/dev/null 2>&1; then
  echo "[check] npm installed OK: $(npm -v 2>/dev/null || echo 'unknown')"
else
  echo "[check] ERROR: npm still not found after installation attempt."
fi

echo "=== check_install_node.sh finished ==="
