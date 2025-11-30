#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "  CLEAR ALL - Full System Reset"
echo "=========================================="
echo ""
echo "This will:"
echo "  1. Stop all services (webhook, cloudflared)"
echo "  2. Remove all Docker containers and images"
echo "  3. Delete all project directories (/opt/linkify-*, /opt/helloStaticPage)"
echo "  4. Backup and restore config/projects.json"
echo "  5. Optionally run install.sh again"
echo ""
echo "⚠️  WARNING: This is destructive! All deployments will be removed."
echo ""

# Ask for backup confirmation
read -r -p "Create backup of projects.json? [Y/n]: " BACKUP_CONFIG
BACKUP_CONFIG=${BACKUP_CONFIG:-Y}

BACKUP_FILE=""
if [[ "$BACKUP_CONFIG" =~ ^[Yy]$ ]]; then
  BACKUP_FILE="/tmp/projects.json.backup.$(date +%Y%m%d_%H%M%S)"
  if [ -f "$ROOT_DIR/config/projects.json" ]; then
    cp "$ROOT_DIR/config/projects.json" "$BACKUP_FILE"
    echo "✓ Backup created: $BACKUP_FILE"
  else
    echo "⚠ No projects.json found to backup"
    BACKUP_FILE=""
  fi
fi

echo ""
read -r -p "Continue with cleanup? [y/N]: " CONFIRM_CLEANUP
if [[ ! "$CONFIRM_CLEANUP" =~ ^[Yy]$ ]]; then
  echo "❌ Cleanup cancelled"
  exit 0
fi

echo ""
echo "=== Step 1: Stopping services ==="

# Stop webhook service
if systemctl is-active --quiet webhook-deploy.service 2>/dev/null; then
  echo "[stop] Stopping webhook-deploy.service..."
  sudo systemctl stop webhook-deploy.service || true
  sudo systemctl disable webhook-deploy.service || true
  echo "✓ webhook-deploy.service stopped"
else
  echo "✓ webhook-deploy.service not running"
fi

# Stop cloudflared services
for service in $(systemctl list-units --type=service --all | grep cloudflared | awk '{print $1}'); do
  echo "[stop] Stopping $service..."
  sudo systemctl stop "$service" || true
  sudo systemctl disable "$service" || true
  echo "✓ $service stopped"
done

echo ""
echo "=== Step 2: Removing Docker containers and images ==="

# Get all linkify and hello containers
CONTAINERS=$(docker ps -a --filter "name=linkify" --filter "name=hello" -q 2>/dev/null || true)
if [ -n "$CONTAINERS" ]; then
  echo "[docker] Stopping containers..."
  docker stop $CONTAINERS 2>/dev/null || true
  echo "[docker] Removing containers..."
  docker rm $CONTAINERS 2>/dev/null || true
  echo "✓ Containers removed"
else
  echo "✓ No containers to remove"
fi

# Remove images
IMAGES=$(docker images --filter "reference=linkify*" --filter "reference=hello*" -q 2>/dev/null || true)
if [ -n "$IMAGES" ]; then
  echo "[docker] Removing images..."
  docker rmi -f $IMAGES 2>/dev/null || true
  echo "✓ Images removed"
else
  echo "✓ No images to remove"
fi

# Clean up unused Docker resources
echo "[docker] Cleaning up unused resources..."
docker system prune -f 2>/dev/null || true
echo "✓ Docker cleanup complete"

echo ""
echo "=== Step 3: Removing project directories ==="

# Remove all project directories
for proj_dir in /opt/linkify-* /opt/helloStaticPage /opt/webook_deploy_debian; do
  if [ -d "$proj_dir" ]; then
    # Skip webook_deploy_debian (current script location)
    if [ "$proj_dir" = "/opt/webook_deploy_debian" ]; then
      echo "[skip] Keeping $proj_dir (current installation)"
      continue
    fi
    
    echo "[remove] Deleting $proj_dir..."
    sudo rm -rf "$proj_dir" || true
    echo "✓ $proj_dir removed"
  fi
done

echo ""
echo "=== Step 4: Removing systemd service files ==="

# Remove service files
if [ -f "/etc/systemd/system/webhook-deploy.service" ]; then
  echo "[remove] Deleting webhook-deploy.service file..."
  sudo rm -f /etc/systemd/system/webhook-deploy.service
  echo "✓ Service file removed"
fi

for service_file in /etc/systemd/system/cloudflared*.service; do
  if [ -f "$service_file" ]; then
    echo "[remove] Deleting $service_file..."
    sudo rm -f "$service_file"
    echo "✓ $(basename $service_file) removed"
  fi
done

sudo systemctl daemon-reload
echo "✓ Systemd reloaded"

echo ""
echo "=== Step 5: Restoring configuration ==="

if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
  cp "$BACKUP_FILE" "$ROOT_DIR/config/projects.json"
  echo "✓ projects.json restored from backup"
  echo "  Backup file: $BACKUP_FILE"
else
  echo "⚠ No backup to restore"
fi

echo ""
echo "=========================================="
echo "  ✓ CLEANUP DONE"
echo "=========================================="
echo ""
echo "Removed:"
echo "  - All Docker containers and images"
echo "  - All project directories (except webook_deploy_debian)"
echo "  - All systemd services"
echo ""
if [ -n "$BACKUP_FILE" ]; then
  echo "Preserved:"
  echo "  - config/projects.json (restored from backup)"
fi
echo ""

# Ask to run install.sh
read -r -p "Run install.sh to reinstall everything? [Y/n]: " RUN_INSTALL
RUN_INSTALL=${RUN_INSTALL:-Y}

if [[ "$RUN_INSTALL" =~ ^[Yy]$ ]]; then
  echo ""
  echo "=== Running install.sh ==="
  cd "$ROOT_DIR"
  bash install.sh
else
  echo ""
  echo "✓ Cleanup complete. Run 'bash install.sh' manually when ready."
fi
