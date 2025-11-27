#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"

echo "=== manage_projects.sh ==="
echo

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[manage] ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[manage] ERROR: jq not found. Install: apt install -y jq"
  exit 1
fi

# Helper functions
list_projects() {
  echo "[manage] Projects in config:"
  jq -r '.projects[] | "  [\(.name)] - \(.repo) (\(.branch)) -> \(.workDir)"' "$CONFIG_FILE"
  echo
}

add_project() {
  echo "[manage] === Add new project ==="
  echo
  
  read -p "Project name: " NAME
  read -p "Git URL: " GIT_URL
  read -p "Branch [main]: " BRANCH
  BRANCH="${BRANCH:-main}"
  
  read -p "Work directory [/opt/$NAME]: " WORKDIR
  WORKDIR="${WORKDIR:-/opt/$NAME}"
  
  echo
  echo "Project type:"
  echo "  1) Docker application (Next.js, Node.js, NestJS, etc.)"
  echo "  2) Static files (HTML/CSS/JS)"
  read -p "Select [1]: " TYPE
  TYPE="${TYPE:-1}"
  
  if [ "$TYPE" = "2" ]; then
    read -p "Port for HTTP server [3005]: " PORT
    PORT="${PORT:-3005}"
    DEPLOY_ARGS="[\"$PORT\"]"
    
    # Copy static template
    mkdir -p "$WORKDIR"
    cp "$SCRIPT_DIR/deploy-static.template.sh" "$WORKDIR/deploy.sh"
    chmod +x "$WORKDIR/deploy.sh"
  else
    read -p "Deploy mode (dev/prod) [dev]: " MODE
    MODE="${MODE:-dev}"
    read -p "Port [3000]: " PORT
    PORT="${PORT:-3000}"
    DEPLOY_ARGS="[\"$MODE\"]"
    
    # Copy docker template
    mkdir -p "$WORKDIR"
    cp "$SCRIPT_DIR/deploy.template.sh" "$WORKDIR/deploy.sh"
    chmod +x "$WORKDIR/deploy.sh"
  fi
  
  read -p "Subdomain: " SUBDOMAIN
  read -p "Root domain [linkify.cloud]: " ROOT_DOMAIN
  ROOT_DOMAIN="${ROOT_DOMAIN:-linkify.cloud}"
  
  read -p "Tunnel name [$ROOT_DOMAIN]: " TUNNEL_NAME
  TUNNEL_NAME="${TUNNEL_NAME:-$ROOT_DOMAIN}"
  
  # Parse repo from git URL
  REPO=$(echo "$GIT_URL" | sed 's/.*[:/]\([^/]*\/[^/]*\)\.git/\1/' | sed 's/\.git$//')
  
  echo
  echo "Adding project:"
  echo "  Name: $NAME"
  echo "  Repo: $REPO"
  echo "  Branch: $BRANCH"
  echo "  WorkDir: $WORKDIR"
  echo "  Port: $PORT"
  echo "  Subdomain: $SUBDOMAIN.$ROOT_DOMAIN"
  echo
  
  read -p "Confirm? [Y/n]: " CONFIRM
  CONFIRM="${CONFIRM:-Y}"
  
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "[manage] Cancelled"
    return
  fi
  
  # Add to config
  TMP=$(mktemp)
  jq --arg name "$NAME" \
     --arg gitUrl "$GIT_URL" \
     --arg repo "$REPO" \
     --arg branch "$BRANCH" \
     --arg workDir "$WORKDIR" \
     --argjson deployArgs "$DEPLOY_ARGS" \
     --arg subdomain "$SUBDOMAIN" \
     --arg rootDomain "$ROOT_DOMAIN" \
     --argjson port "$PORT" \
     --arg tunnelName "$TUNNEL_NAME" \
     '.projects += [{
       name: $name,
       gitUrl: $gitUrl,
       repo: $repo,
       branch: $branch,
       workDir: $workDir,
       deployScript: ($workDir + "/deploy.sh"),
       deployArgs: $deployArgs,
       cloudflare: {
         enabled: true,
         rootDomain: $rootDomain,
         subdomain: $subdomain,
         localPort: $port,
         localPath: "/",
         protocol: "http",
         tunnelName: $tunnelName
       }
     }]' "$CONFIG_FILE" > "$TMP"
  
  mv "$TMP" "$CONFIG_FILE"
  echo "[manage] ✓ Project added"
  echo "[manage] Restart webhook: systemctl restart webhook-deploy"
}

modify_project() {
  echo "[manage] === Modify project ==="
  echo
  list_projects
  
  read -p "Project name to modify: " NAME
  
  # Check if exists
  if ! jq -e ".projects[] | select(.name==\"$NAME\")" "$CONFIG_FILE" >/dev/null; then
    echo "[manage] ERROR: Project '$NAME' not found"
    return 1
  fi
  
  echo
  echo "Leave empty to keep current value"
  echo
  
  CURRENT_BRANCH=$(jq -r ".projects[] | select(.name==\"$NAME\") | .branch" "$CONFIG_FILE")
  read -p "Branch [$CURRENT_BRANCH]: " NEW_BRANCH
  NEW_BRANCH="${NEW_BRANCH:-$CURRENT_BRANCH}"
  
  CURRENT_PORT=$(jq -r ".projects[] | select(.name==\"$NAME\") | .cloudflare.localPort" "$CONFIG_FILE")
  read -p "Port [$CURRENT_PORT]: " NEW_PORT
  NEW_PORT="${NEW_PORT:-$CURRENT_PORT}"
  
  CURRENT_SUB=$(jq -r ".projects[] | select(.name==\"$NAME\") | .cloudflare.subdomain" "$CONFIG_FILE")
  read -p "Subdomain [$CURRENT_SUB]: " NEW_SUB
  NEW_SUB="${NEW_SUB:-$CURRENT_SUB}"
  
  TMP=$(mktemp)
  jq "(.projects[] | select(.name==\"$NAME\") | .branch) = \"$NEW_BRANCH\" |
      (.projects[] | select(.name==\"$NAME\") | .cloudflare.localPort) = $NEW_PORT |
      (.projects[] | select(.name==\"$NAME\") | .cloudflare.subdomain) = \"$NEW_SUB\"" \
      "$CONFIG_FILE" > "$TMP"
  
  mv "$TMP" "$CONFIG_FILE"
  echo "[manage] ✓ Project modified"
  echo "[manage] Restart webhook: systemctl restart webhook-deploy"
}

delete_project() {
  echo "[manage] === Delete project ==="
  echo
  list_projects
  
  read -p "Project name to delete: " NAME
  
  # Check if exists
  if ! jq -e ".projects[] | select(.name==\"$NAME\")" "$CONFIG_FILE" >/dev/null; then
    echo "[manage] ERROR: Project '$NAME' not found"
    return 1
  fi
  
  echo
  read -p "Delete project '$NAME'? [y/N]: " CONFIRM
  
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "[manage] Cancelled"
    return
  fi
  
  TMP=$(mktemp)
  jq "del(.projects[] | select(.name==\"$NAME\"))" "$CONFIG_FILE" > "$TMP"
  mv "$TMP" "$CONFIG_FILE"
  
  echo "[manage] ✓ Project deleted from config"
  echo "[manage] Note: Files in workDir are NOT deleted"
  echo "[manage] Restart webhook: systemctl restart webhook-deploy"
}

# Main menu
case "${1:-}" in
  add)
    add_project
    ;;
  modify|edit)
    modify_project
    ;;
  delete|remove)
    delete_project
    ;;
  list|ls)
    list_projects
    ;;
  *)
    echo "Usage: $0 {add|modify|delete|list}"
    echo
    echo "Commands:"
    echo "  add     - Add new project to config"
    echo "  modify  - Modify existing project"
    echo "  delete  - Remove project from config"
    echo "  list    - List all projects"
    echo
    list_projects
    exit 1
    ;;
esac
