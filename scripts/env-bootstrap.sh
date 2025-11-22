#!/bin/bash
set -e

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

echo "[env] Environment bootstrap finished."
