#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
CONFIG_FILE="$CONFIG_DIR/projects.json"
EXAMPLE_FILE="$CONFIG_DIR/projects.example.json"
DEPLOY_TEMPLATE="$ROOT_DIR/deploy.template.sh"

mkdir -p "$CONFIG_DIR"

# ---------- Helpers ----------

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
  # дефис внутри [] должен быть в начале/конце, иначе он диапазон
  if [[ "$val" =~ ^[a-z0-9/-]+$ ]]; then
    return 0
  fi
  return 1
}


parse_repo_from_git_url() {
  local url="$1"
  # Examples:
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

copy_deploy_template_if_missing() {
  local workDir="$1"

  mkdir -p "$workDir"

  if [ -f "$workDir/deploy.sh" ]; then
    echo "[init] deploy.sh already exists in $workDir – keeping existing file."
  else
    echo "[init] Copying deploy.template.sh to $workDir/deploy.sh"
    cp "$DEPLOY_TEMPLATE" "$workDir/deploy.sh"
    chmod +x "$workDir/deploy.sh"
  fi
}

# ---------- Start ----------

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

# ---------- Webhook config ----------

echo "=== Webhook configuration ==="

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

# localPath для webhook – обычно тот же path
while true; do
  WEBHOOK_LOCALPATH=$(prompt "Webhook localPath (internal path, usually same as path)" "$WEBHOOK_PATH")
  if validate_path_token "$WEBHOOK_LOCALPATH"; then
    break
  else
    echo "Invalid localPath: only a-z0-9- and / allowed."
  fi
done

WEBHOOK_PROTOCOL=$(prompt "Webhook protocol" "http")

# Cloudflare tunnel name for this rootDomain (можно оставить пустым)
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

# map rootDomain -> tunnelName (кэш, чтобы не спрашивать каждый раз)
declare -A ROOTDOMAIN_TUNNEL
if [ -n "$WEBHOOK_ROOT_DOMAIN" ] && [ -n "$WEBHOOK_TUNNEL_NAME" ]; then
  ROOTDOMAIN_TUNNEL["$WEBHOOK_ROOT_DOMAIN"]="$WEBHOOK_TUNNEL_NAME"
fi

# ---------- Project wizard loop ----------

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

  # workDir default: /opt/<project_name>
  DEFAULT_WORKDIR="/opt/${PROJECT_NAME}"
  WORKDIR=$(prompt "Project workDir on server" "$DEFAULT_WORKDIR")

  # deploy mode (goes into deployArgs[0])
  DEPLOY_MODE=$(prompt "Deploy mode argument (e.g. dev, prod)" "dev")

  ROOT_DOMAIN=$(prompt "Root domain for this project (e.g. linkify.cloud, 1ait.eu)" "$WEBHOOK_ROOT_DOMAIN")

  # subdomain – validate
  while true; do
    SUBDOMAIN=$(prompt "Subdomain for this project (e.g. dev, app, api)" "dev")
    if validate_subdomain "$SUBDOMAIN"; then
      break
    else
      echo "Invalid subdomain: only [a-z0-9-] allowed."
    fi
  done

  # port – numeric
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

  # Tunnel name: reuse per rootDomain if available
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

    copy_deploy_template_if_missing "$WORKDIR"
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
echo "[init] Done."
echo "[init] Final config: $CONFIG_FILE"
echo "You can inspect it with: cat $CONFIG_FILE | jq"
