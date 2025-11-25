#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"
EXAMPLE_FILE="$SCRIPT_DIR/projects.example.json"
DEPLOY_TEMPLATE="$SCRIPT_DIR/deploy.template.sh"
SSH_STATE="$CONFIG_DIR/ssh_state.json"

mkdir -p "$CONFIG_DIR"

################################
#          Helpers             #
################################

prompt() {
  local msg="$1"
  local default="$2"
  local var
  if [ -n "$default" ]; then
    read -r -p "$msg [$default]: " var
    var="${var:-$default}"
  else
    read -r -p "$msg: " var
  fi
  echo "$var"
}

yes_no_default_no() {
  local msg="$1"
  local ans
  read -r -p "$msg [y/N]: " ans
  ans="${ans:-N}"
  case "$ans" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

yes_no_default_yes() {
  local msg="$1"
  local ans
  read -r -p "$msg [Y/n]: " ans
  ans="${ans:-Y}"
  case "$ans" in
    n|N) return 1 ;;
    *)   return 0 ;;
  esac
}

validate_subdomain() {
  local val="$1"
  # allowed: a-z0-9-
  if [[ "$val" =~ ^[a-z0-9-]+$ ]]; then
    return 0
  fi
  return 1
}

validate_path_token() {
  local val="$1"
  # allowed: a-z, 0-9, -, /
  if [[ "$val" =~ ^[a-z0-9/-]+$ ]]; then
    return 0
  fi
  return 1
}

parse_repo_from_git_url() {
  local url="$1"
  # git@github.com:User/Repo.git -> User/Repo
  # https://github.com/User/Repo.git -> User/Repo
  local tmp="$url"

  tmp="${tmp%.git}"

  if [[ "$tmp" == *:*/* ]]; then
    tmp="${tmp#*:}"
  elif [[ "$tmp" == *github.com/* ]]; then
    tmp="${tmp#*github.com/}"
  fi

  echo "$tmp"
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[init] jq not found. Please install first (or run scripts/env-bootstrap.sh)."
    exit 1
  fi
}

ensure_deploy_template() {
  if [ ! -f "$DEPLOY_TEMPLATE" ]; then
    echo "[init] ERROR: deploy.template.sh not found at $DEPLOY_TEMPLATE"
    exit 1
  fi

  if [ ! -f "$EXAMPLE_FILE" ]; then
    echo "[init] WARNING: projects.example.json not found at $EXAMPLE_FILE"
    # не критично – init.sh и так строит JSON с нуля
  fi
}

append_project_to_config() {
  local name="$1"
  local gitUrl="$2"
  local repo="$3"
  local branch="$4"
  local workDir="$5"
  local deployMode="$6"
  local rootDomain="$7"
  local subdomain="$8"
  local port="$9"
  local localPath="${10}"
  local protocol="${11}"
  local tunnelName="${12}"

  local tmp
  tmp="$(mktemp)"

  jq \
    --arg name "$name" \
    --arg gitUrl "$gitUrl" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg workDir "$workDir" \
    --arg deployMode "$deployMode" \
    --arg rootDomain "$rootDomain" \
    --arg subdomain "$subdomain" \
    --argjson port "$port" \
    --arg localPath "$localPath" \
    --arg protocol "$protocol" \
    --arg tunnelName "$tunnelName" \
    '
    .projects += [{
      name: $name,
      gitUrl: $gitUrl,
      repo: $repo,
      branch: $branch,
      workDir: $workDir,
      deployScript: ($workDir + "/deploy.sh"),
      deployArgs: [ $deployMode ],
      cloudflare: {
        enabled: true,
        rootDomain: $rootDomain,
        subdomain: $subdomain,
        localPort: $port,
        localPath: $localPath,
        protocol: $protocol,
        tunnelName: $tunnelName
      }
    }]
    ' "$CONFIG_FILE" > "$tmp"

  mv "$tmp" "$CONFIG_FILE"
}

set_webhook_config() {
  local port="$1"
  local path="$2"
  local secret="$3"
  local rootDomain="$4"
  local subdomain="$5"
  local localPath="$6"
  local protocol="$7"
  local tunnelName="$8"

  local tmp
  tmp="$(mktemp)"

  jq \
    --argjson port "$port" \
    --arg path "$path" \
    --arg secret "$secret" \
    --arg rootDomain "$rootDomain" \
    --arg subdomain "$subdomain" \
    --arg localPath "$localPath" \
    --arg protocol "$protocol" \
    --arg tunnelName "$tunnelName" \
    '
    .webhook = {
      port: $port,
      path: $path,
      secret: $secret,
      cloudflare: {
        enabled: true,
        rootDomain: $rootDomain,
        subdomain: $subdomain,
        localPort: $port,
        localPath: $localPath,
        protocol: $protocol,
        tunnelName: $tunnelName
      }
    }
    ' "$CONFIG_FILE" > "$tmp"

  mv "$tmp" "$CONFIG_FILE"
}

show_projects_summary() {
  echo
  echo "[init] Summary of configured projects (from $CONFIG_FILE):"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[init]   No config file found."
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '
      .projects[]? |
      "- " +
      (.name // "n/a") +
      " | branch=" + (.branch // "n/a") +
      " | domain=" + (.cloudflare.rootDomain // "n/a") +
      " | subdomain=" + (.cloudflare.subdomain // "n/a")
    ' "$CONFIG_FILE"
  else
    grep -E '"name"|\"branch\"' "$CONFIG_FILE" || true
  fi
}

################################
#          Start               #
################################

echo "[init] Root dir: $ROOT_DIR"
ensure_jq
ensure_deploy_template

# 1) Config file existence check
if [ -f "$CONFIG_FILE" ]; then
  echo "[init] Found existing config: $CONFIG_FILE"

  if yes_no_default_no "Overwrite existing config.json?"; then
    echo "[init] Overwriting with new empty structure."
    cat > "$CONFIG_FILE" <<EOF
{
  "webhook": {},
  "projects": []
}
EOF
  else
    if yes_no_default_yes "Append new projects to existing config?"; then
      echo "[init] Will append to existing config."
    else
      echo "[init] Aborting by user."
      exit 0
    fi
  fi
else
  echo "[init] No config found. Creating new $CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
{
  "webhook": {},
  "projects": []
}
EOF
fi

echo

################################
#      Webhook configuration   #
################################

# ---------- Webhook config ----------

echo "=== Webhook configuration ==="

HAS_WEBHOOK="no"
if [ -f "$CONFIG_FILE" ]; then
  HAS_WEBHOOK=$(jq -r 'if .webhook and .webhook.port then "yes" else "no" end' "$CONFIG_FILE")
fi

if [ "$HAS_WEBHOOK" = "yes" ]; then
  # читаем текущие значения
  CUR_PORT=$(jq -r '.webhook.port' "$CONFIG_FILE")
  CUR_PATH=$(jq -r '.webhook.path' "$CONFIG_FILE")
  CUR_SECRET=$(jq -r '.webhook.secret // ""' "$CONFIG_FILE")
  CUR_ROOT_DOMAIN=$(jq -r '.webhook.cloudflare.rootDomain // "linkify.cloud"' "$CONFIG_FILE")
  CUR_SUBDOMAIN=$(jq -r '.webhook.cloudflare.subdomain // "webhook"' "$CONFIG_FILE")
  CUR_LOCALPATH=$(jq -r '.webhook.cloudflare.localPath // "/github"' "$CONFIG_FILE")
  CUR_PROTOCOL=$(jq -r '.webhook.cloudflare.protocol // "http"' "$CONFIG_FILE")
  CUR_TUNNEL_NAME=$(jq -r '.webhook.cloudflare.tunnelName // ""' "$CONFIG_FILE")

  echo "[init] Existing webhook config detected:"
  echo "  port      : $CUR_PORT"
  echo "  path      : $CUR_PATH"
  echo "  domain    : $CUR_ROOT_DOMAIN (sub=$CUR_SUBDOMAIN)"
  echo "  localPath : $CUR_LOCALPATH"
  echo "  protocol  : $CUR_PROTOCOL"
  echo "  tunnel    : $CUR_TUNNEL_NAME"
  echo

  if yes_no_default_no "Reconfigure webhook settings?"; then
    # даём возможность изменить, но по умолчанию — старые значения
    WEBHOOK_PORT=$(prompt "Webhook port" "$CUR_PORT")
    WEBHOOK_PATH=$(prompt "Webhook path" "$CUR_PATH")

    # секрет: пустой ввод = оставить старый
    NEW_SECRET=$(prompt "Webhook secret (leave empty to keep current)" "")
    if [ -z "$NEW_SECRET" ]; then
      WEBHOOK_SECRET="$CUR_SECRET"
    else
      WEBHOOK_SECRET="$NEW_SECRET"
    fi

    WEBHOOK_ROOT_DOMAIN=$(prompt "Root domain for webhook (e.g. linkify.cloud)" "$CUR_ROOT_DOMAIN")

    while true; do
      WEBHOOK_SUBDOMAIN=$(prompt "Webhook subdomain (e.g. webhook)" "$CUR_SUBDOMAIN")
      if validate_subdomain "$WEBHOOK_SUBDOMAIN"; then
        break
      else
        echo "Invalid subdomain: only [a-z0-9-] allowed."
      fi
    done

    while true; do
      WEBHOOK_LOCALPATH=$(prompt "Webhook localPath (internal path, usually same as path)" "$CUR_LOCALPATH")
      if validate_path_token "$WEBHOOK_LOCALPATH"; then
        break
      else
        echo "Invalid localPath: only a-z0-9- and / allowed."
      fi
    done

    WEBHOOK_PROTOCOL=$(prompt "Webhook protocol" "$CUR_PROTOCOL")

    # имя туннеля: по умолчанию текущее
    WEBHOOK_TUNNEL_NAME=$(prompt "Cloudflare tunnel name for rootDomain $WEBHOOK_ROOT_DOMAIN (optional)" "$CUR_TUNNEL_NAME")

    set_webhook_config \
      "$WEBHOOK_PORT" \
      "$WEBHOOK_PATH" \
      "$WEBHOOK_SECRET" \
      "$WEBHOOK_ROOT_DOMAIN" \
      "$WEBHOOK_SUBDOMAIN" \
      "$WEBHOOK_LOCALPATH" \
      "$WEBHOOK_PROTOCOL" \
      "$WEBHOOK_TUNNEL_NAME"

    echo
    echo "[init] Webhook config updated."
    echo
  else
    echo "[init] Keeping existing webhook config as is."
    WEBHOOK_ROOT_DOMAIN="$CUR_ROOT_DOMAIN"
    WEBHOOK_TUNNEL_NAME="$CUR_TUNNEL_NAME"
    echo
  fi
else
  # вебхук ещё не настроен → обычный мастер
  WEBHOOK_PORT=$(prompt "Webhook port" "4000")
  WEBHOOK_PATH=$(prompt "Webhook path" "/github")
  WEBHOOK_SECRET=$(prompt "Webhook secret (empty allowed)" "")

  WEBHOOK_ROOT_DOMAIN=$(prompt "Root domain for webhook (e.g. linkify.cloud)" "linkify.cloud")

  while true; do
    WEBHOOK_SUBDOMAIN=$(prompt "Webhook subdomain (e.g. webhook)" "webhook")
    if validate_subdomain "$WEBHOOK_SUBDOMAIN"; then
      break
    else
      echo "Invalid subdomain: only [a-z0-9-] allowed."
    fi
  done

  while true; do
    WEBHOOK_LOCALPATH=$(prompt "Webhook localPath (internal path, usually same as path)" "$WEBHOOK_PATH")
    if validate_path_token "$WEBHOOK_LOCALPATH"; then
      break
    else
      echo "Invalid localPath: only a-z0-9- and / allowed."
    fi
  done

  WEBHOOK_PROTOCOL=$(prompt "Webhook protocol" "http")
  WEBHOOK_TUNNEL_NAME=$(prompt "Cloudflare tunnel name for rootDomain $WEBHOOK_ROOT_DOMAIN (optional)" "")

  set_webhook_config \
    "$WEBHOOK_PORT" \
    "$WEBHOOK_PATH" \
    "$WEBHOOK_SECRET" \
    "$WEBHOOK_ROOT_DOMAIN" \
    "$WEBHOOK_SUBDOMAIN" \
    "$WEBHOOK_LOCALPATH" \
    "$WEBHOOK_PROTOCOL" \
    "$WEBHOOK_TUNNEL_NAME"

  echo
  echo "[init] Webhook config saved."
  echo
fi

# map rootDomain -> tunnelName (cache)
declare -A ROOTDOMAIN_TUNNEL
if [ -n "$WEBHOOK_ROOT_DOMAIN" ] && [ -n "$WEBHOOK_TUNNEL_NAME" ]; then
  ROOTDOMAIN_TUNNEL["$WEBHOOK_ROOT_DOMAIN"]="$WEBHOOK_TUNNEL_NAME"
fi

################################
#       Project wizard loop    #
################################

while true; do
  echo "=== New project configuration ==="

  PROJECT_NAME=$(prompt "Project name (internal identifier, e.g. linkify-dev)" "")
  if [ -z "$PROJECT_NAME" ]; then
    echo "Project name cannot be empty."
    continue
  fi

  GIT_URL=$(prompt "Git URL (e.g. git@github.com:User/Repo.git)" "")
  if [ -z "$GIT_URL" ]; then
    echo "Git URL cannot be empty."
    continue
  fi

  DETECTED_REPO="$(parse_repo_from_git_url "$GIT_URL")"
  REPO_FIELD=$(prompt "Detected repo owner/name" "$DETECTED_REPO")

  BRANCH=$(prompt "Branch name" "main")

  DEFAULT_WORKDIR="/opt/${PROJECT_NAME}"
  WORKDIR=$(prompt "Project workDir on server" "$DEFAULT_WORKDIR")

  DEPLOY_MODE=$(prompt "Deploy mode argument (e.g. dev, prod)" "dev")

  ROOT_DOMAIN="$WEBHOOK_ROOT_DOMAIN"
  echo "Root domain for this project: $ROOT_DOMAIN (taken from webhook rootDomain)"

  while true; do
    SUBDOMAIN=$(prompt "Subdomain ONLY (e.g. dev for dev.${ROOT_DOMAIN})" "dev")
    if validate_subdomain "$SUBDOMAIN"; then
      break
    else
      echo "Invalid subdomain: only [a-z0-9-] allowed."
    fi
  done

  PORT=$(prompt "Local port (container/service port on host)" "3000")
  if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo "Invalid port, using 3000."
    PORT=3000
  fi

  while true; do
    LOCAL_PATH=$(prompt "Local path (for Cloudflare service, usually /)" "/")
    if validate_path_token "$LOCAL_PATH"; then
      break
    else
      echo "Invalid localPath: only a-z0-9- and / allowed."
    fi
  done

  PROTOCOL=$(prompt "Protocol (http/https)" "http")

  if [ -n "${ROOTDOMAIN_TUNNEL[$ROOT_DOMAIN]}" ]; then
    DEFAULT_TUNNEL="${ROOTDOMAIN_TUNNEL[$ROOT_DOMAIN]}"
  else
    DEFAULT_TUNNEL=""
  fi

  TUNNEL_NAME=$(prompt "Cloudflare tunnel name for rootDomain $ROOT_DOMAIN (optional)" "$DEFAULT_TUNNEL")
  if [ -n "$TUNNEL_NAME" ] && [ -z "${ROOTDOMAIN_TUNNEL[$ROOT_DOMAIN]}" ]; then
    ROOTDOMAIN_TUNNEL["$ROOT_DOMAIN"]="$TUNNEL_NAME"
  fi

  echo
  echo "Summary for this project:"
  echo "  Name        : $PROJECT_NAME"
  echo "  Git URL     : $GIT_URL"
  echo "  Repo        : $REPO_FIELD"
  echo "  Branch      : $BRANCH"
  echo "  WorkDir     : $WORKDIR"
  echo "  Deploy mode : $DEPLOY_MODE"
  echo "  Root domain : $ROOT_DOMAIN"
  echo "  Subdomain   : $SUBDOMAIN"
  echo "  Port        : $PORT"
  echo "  Local path  : $LOCAL_PATH"
  echo "  Protocol    : $PROTOCOL"
  echo "  Tunnel name : $TUNNEL_NAME"
  echo

  if yes_no_default_yes "Add this project to config?"; then
    append_project_to_config \
      "$PROJECT_NAME" \
      "$GIT_URL" \
      "$REPO_FIELD" \
      "$BRANCH" \
      "$WORKDIR" \
      "$DEPLOY_MODE" \
      "$ROOT_DOMAIN" \
      "$SUBDOMAIN" \
      "$PORT" \
      "$LOCAL_PATH" \
      "$PROTOCOL" \
      "$TUNNEL_NAME"

    echo "[init] Project added."
  else
    echo "[init] Project discarded."
  fi

  echo
  if yes_no_default_yes "Configure another project?"; then
    echo
    continue
  else
    break
  fi
done

echo
show_projects_summary
echo "[init] Done."
echo "[init] Final config: $CONFIG_FILE"
echo "You can inspect it with: cat $CONFIG_FILE | jq"

################################
#   Ownership & state files    #
################################

# Определяем пользователя для владения projects.json (из ssh_state или webuser)
APP_USER="webuser"
if [ -f "$SSH_STATE" ] && command -v jq >/dev/null 2>&1; then
  u="$(jq -r '.sshUser // empty' "$SSH_STATE" 2>/dev/null || true)"
  if [ -n "$u" ]; then
    APP_USER="$u"
  fi
fi

# Права на каталог и config-файл
chown "$APP_USER":"$APP_USER" "$CONFIG_DIR" "$CONFIG_FILE" 2>/dev/null || true
chmod 750 "$CONFIG_DIR" 2>/dev/null || true
chmod 640 "$CONFIG_FILE" 2>/dev/null || true

PROJECTS_STATE="$CONFIG_DIR/projects_state.json"
PROJECTS_COUNT=$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo 0)

cat > "$PROJECTS_STATE" <<EOF
{
  "version": "1.0.0",
  "projectsCount": $PROJECTS_COUNT,
  "timestamp": "$(date --iso-8601=seconds)",
  "host": "$(hostname)"
}
EOF

chown root:root "$PROJECTS_STATE" 2>/dev/null || true
chmod 640 "$PROJECTS_STATE" 2>/dev/null || true

echo "[init] projects_state.json written to $PROJECTS_STATE"
