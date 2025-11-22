#!/bin/bash
set -e

# Environment bootstrap:
# - apt update / upgrade
# - install curl, git, jq
# - install Docker (if missing)
# NO SSH logic here.

if [ "$EUID" -ne 0 ]; then
  echo "[env] This script must be run as root."
  exit 1
fi

echo "[env] Updating APT..."
apt update -y
apt upgrade -y

echo "[env] Installing base tools (curl, git, jq)..."
apt install -y curl git jq

echo "[env] Installing Docker (if not installed)..."

if ! command -v docker >/dev/null 2>&1; then
  echo "[env] Docker not found, installing from official repo..."

  apt install -y ca-certificates gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
else
  echo "[env] Docker already installed."
fi

echo
echo "[env] Environment bootstrap finished."
echo "[env] Next steps:"
echo "  1) ./scripts/enable_ssh.sh   # create SSH user, sudo, docker group etc."
echo "  2) ./init.sh                 # configure webhook + projects.json"
