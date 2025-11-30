#!/bin/bash
set -e

echo "=== apply_optimizations.sh ==="
echo "Применение оптимизаций деплоя к существующим проектам"
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
PROJECTS_FILE="$CONFIG_DIR/projects.json"

echo "[opt] SCRIPT_DIR  = $SCRIPT_DIR"
echo "[opt] ROOT_DIR    = $ROOT_DIR"
echo "[opt] PROJECTS    = $PROJECTS_FILE"
echo

# Проверки
if [ ! -f "$PROJECTS_FILE" ]; then
  echo "[opt] ERROR: $PROJECTS_FILE not found"
  echo "[opt]        Run init.sh first to configure projects"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[opt] ERROR: jq not found. Install: apt install -y jq"
  exit 1
fi

# Вспомогательная функция
ask_yes_no() {
  local msg="$1"
  local default="${2:-n}"
  local ans
  
  if [ "$default" = "y" ]; then
    read -r -p "$msg [Y/n]: " ans
    ans="${ans:-Y}"
  else
    read -r -p "$msg [y/N]: " ans
    ans="${ans:-N}"
  fi
  
  case "$ans" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

# Читаем проекты
mapfile -t WORK_DIRS < <(jq -r '.projects[]?.workDir // empty' "$PROJECTS_FILE")

if [ "${#WORK_DIRS[@]}" -eq 0 ]; then
  echo "[opt] No projects found in $PROJECTS_FILE"
  exit 0
fi

echo "[opt] Found ${#WORK_DIRS[@]} project(s):"
for wd in "${WORK_DIRS[@]}"; do
  echo "  - $wd"
done
echo

# Функция применения оптимизаций к одному проекту
optimize_project() {
  local workDir="$1"
  local projectName=$(basename "$workDir")
  
  echo
  echo "========================================="
  echo "Project: $projectName"
  echo "WorkDir: $workDir"
  echo "========================================="
  
  if [ ! -d "$workDir" ]; then
    echo "[opt] WARNING: Directory not found: $workDir"
    return 1
  fi
  
  cd "$workDir"
  
  # 1. Обновить deploy.sh
  if ask_yes_no "[opt] Update deploy.sh with optimized version?" "y"; then
    if [ -f "$ROOT_DIR/scripts/deploy.template.sh" ]; then
      echo "[opt]   Backing up old deploy.sh..."
      [ -f "deploy.sh" ] && cp "deploy.sh" "deploy.sh.backup.$(date +%Y%m%d_%H%M%S)"
      
      echo "[opt]   Copying optimized deploy.sh..."
      cp "$ROOT_DIR/scripts/deploy.template.sh" "deploy.sh"
      chmod +x "deploy.sh"
      echo "[opt]   ✓ deploy.sh updated"
    else
      echo "[opt]   ERROR: Template not found: $ROOT_DIR/scripts/deploy.template.sh"
    fi
  fi
  
  # 2. Обновить Dockerfile
  if ask_yes_no "[opt] Replace Dockerfile with optimized multi-stage version?" "n"; then
    if [ -f "$SCRIPT_DIR/Dockerfile" ]; then
      echo "[opt]   Backing up old Dockerfile..."
      [ -f "Dockerfile" ] && cp "Dockerfile" "Dockerfile.backup.$(date +%Y%m%d_%H%M%S)"
      
      echo "[opt]   Copying optimized Dockerfile..."
      cp "$SCRIPT_DIR/Dockerfile" "Dockerfile"
      echo "[opt]   ✓ Dockerfile updated"
      
      echo "[opt]   ⚠ IMPORTANT: Review Dockerfile and adjust for your project:"
      echo "[opt]     - Check build commands (npm run build)"
      echo "[opt]     - Verify paths (public/, .next/, etc.)"
      echo "[opt]     - Update health check endpoint"
    else
      echo "[opt]   WARNING: Template not found: $SCRIPT_DIR/Dockerfile"
    fi
  fi
  
  # 3. Обновить docker-compose.yml
  if ask_yes_no "[opt] Replace docker-compose.yml with optimized version?" "n"; then
    if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
      echo "[opt]   Backing up old docker-compose.yml..."
      [ -f "docker-compose.yml" ] && cp "docker-compose.yml" "docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)"
      
      echo "[opt]   Copying optimized docker-compose.yml..."
      cp "$SCRIPT_DIR/docker-compose.yml" "docker-compose.yml"
      echo "[opt]   ✓ docker-compose.yml updated"
      
      echo "[opt]   ⚠ IMPORTANT: Review docker-compose.yml and adjust:"
      echo "[opt]     - Service names (app-dev, app-prod)"
      echo "[opt]     - Port mappings (3001, 3002)"
      echo "[opt]     - Volume paths (check your project structure)"
    else
      echo "[opt]   WARNING: Template not found: $SCRIPT_DIR/docker-compose.yml"
    fi
  fi
  
  # 4. Добавить .dockerignore
  if [ ! -f ".dockerignore" ]; then
    if ask_yes_no "[opt] Create .dockerignore file?" "y"; then
      if [ -f "$SCRIPT_DIR/.dockerignore" ]; then
        echo "[opt]   Creating .dockerignore..."
        cp "$SCRIPT_DIR/.dockerignore" ".dockerignore"
        echo "[opt]   ✓ .dockerignore created"
      else
        echo "[opt]   WARNING: Template not found: $SCRIPT_DIR/.dockerignore.example"
      fi
    fi
  else
    echo "[opt]   .dockerignore already exists - skipping"
  fi
  
  # 5. Пересобрать образ для создания кэша
  if ask_yes_no "[opt] Rebuild Docker images to create cache layers?" "n"; then
    echo "[opt]   Building images (this may take several minutes)..."
    
    if [ -f "docker-compose.yml" ]; then
      # Определяем service names из compose файла
      SERVICES=$(docker compose config --services 2>/dev/null || echo "")
      
      if [ -n "$SERVICES" ]; then
        echo "[opt]   Found services: $SERVICES"
        for svc in $SERVICES; do
          echo "[opt]   Building $svc..."
          docker compose build "$svc" || echo "[opt]   WARNING: Build failed for $svc"
        done
        echo "[opt]   ✓ Build complete - cache layers created"
      else
        echo "[opt]   WARNING: Could not detect services in docker-compose.yml"
      fi
    else
      echo "[opt]   WARNING: docker-compose.yml not found"
    fi
  fi
  
  echo "[opt] ✓ Optimizations applied to $projectName"
}

# Применяем оптимизации ко всем проектам
echo "[opt] Starting optimization process..."
echo

for wd in "${WORK_DIRS[@]}"; do
  [ -z "$wd" ] && continue
  
  if ask_yes_no "[opt] Optimize project: $wd?" "y"; then
    optimize_project "$wd"
  else
    echo "[opt] Skipping $wd"
  fi
done

echo
echo "========================================="
echo "=== apply_optimizations.sh finished ==="
echo "========================================="
echo
echo "[opt] Summary:"
echo "  - deploy.sh: умная проверка изменений (5-10 сек вместо 5-7 мин)"
echo "  - Dockerfile: multi-stage build с кэшированием"
echo "  - docker-compose.yml: volume mounting для hot reload"
echo "  - .dockerignore: исключение ненужных файлов из build context"
echo
echo "[opt] Next steps:"
echo "  1. Review and test changes in each project"
echo "  2. Make a test commit and push to verify fast deployment"
echo "  3. Check deploy logs: journalctl -u webhook-deploy.service -n 50"
echo "  4. Read OPTIMIZATION.md for more details"
echo
