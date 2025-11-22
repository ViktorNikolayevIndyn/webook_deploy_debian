# webook_deploy_debian

Universal **GitHub → Webhook → Deploy** runner for Debian / Proxmox (LXC or bare metal).

This service listens to GitHub **push** events and triggers **deploy scripts** for multiple repositories and branches.  
It is designed to:

- Work on **Debian 11/12** (incl. Proxmox LXC).
- Deploy **Docker-based projects** (via `docker compose`).
- **Skip builds** when there are **no new commits**.
- Be configured only via a simple **JSON file**.

---

## 1. Repository layout

Recommended structure:

```text
webook_deploy_debian/
  README.md
  package.json
  .gitignore

  deploy.sh                 # universal deploy script (git + docker + skip-if-no-changes)

  config/
    projects.example.json   # template
    projects.json           # your real config (not committed)

  src/
    webhook.js              # main webhook server

  systemd/
    webhook.service.example # systemd unit template (optional)

  repos/
    <project-name>/
      <branch-1>/           # git clone of branch-1
      <branch-2>/           # git clone of branch-2
      docker-compose.yml    # shared compose for services
```

You clone your application repos into `repos/...` and configure how to deploy them via `config/projects.json`.

---

## 2. Requirements

- Debian 11/12 (or Proxmox LXC based on Debian).
- Node.js (v16+ recommended).
- `git`.
- `docker` + `docker compose`.
- Optional: Cloudflare Tunnel if you want HTTPS endpoint for webhook.

---

## 3. Install and run

### 3.1 Clone this webhook project

```bash
cd /opt
git clone https://github.com/ViktorNikolayevIndyn/webook_deploy_debian.git
cd webook_deploy_debian
```

### 3.2 Install Node.js dependencies

```bash
apt update
apt install -y nodejs npm
npm install
```

### 3.3 Make the deploy script executable

```bash
chmod +x ./deploy.sh
```

### 3.4 Prepare config folder

```bash
mkdir -p config
cp config/projects.example.json config/projects.json
```

Then edit `config/projects.json` according to the next section.

---

## 4. Configuration (`config/projects.json`)

This is the main configuration file.

Basic structure:

```json
{
  "port": 4000,
  "path": "/github",

  "rootDir": "<ABSOLUTE_ROOT_DIR_PATH>",
  "deployScript": "deploy.sh",

  "projects": [
    {
      "name": "<PROJECT_NAME_1>",
      "repo": "<GITHUB_FULL_REPO_NAME_1>",
      "branches": {
        "<BRANCH_NAME_1>": {
          "description": "Deploy config for <BRANCH_NAME_1> of <PROJECT_NAME_1>",
          "repoDir": "repos/<PROJECT_DIR_1>/<BRANCH_NAME_1>",
          "composeFile": "repos/<PROJECT_DIR_1>/docker-compose.yml",
          "service": "<DOCKER_SERVICE_NAME_1>",
          "enabled": true
        },
        "<BRANCH_NAME_2>": {
          "description": "Deploy config for <BRANCH_NAME_2> of <PROJECT_NAME_1>",
          "repoDir": "repos/<PROJECT_DIR_1>/<BRANCH_NAME_2>",
          "composeFile": "repos/<PROJECT_DIR_1>/docker-compose.yml",
          "service": "<DOCKER_SERVICE_NAME_2>",
          "enabled": true
        }
      }
    }
  ]
}
```

### 4.1 How to fill placeholders (short recap)

- `port`  
  HTTP port for the webhook server. Example: `4000`.

- `path`  
  URL path for webhook endpoint. Example: `"/github"` → `/github`.

- `rootDir`  
  Absolute path where this webhook project is located. Example:  
  `/opt/webook_deploy_debian`

- `deployScript`  
  Name or path to the deploy script, relative to `rootDir`, or absolute path.  
  Usually: `"deploy.sh"`.

- `projects`  
  List of projects handled by this webhook.

For each project:

- `name`  
  Internal name, just for logs. Example: `"linkify"`.

- `repo`  
  GitHub repo full name: `"<OWNER>/<REPO_NAME>"`.  
  Example: `"ViktorNikolayevIndyn/linkify"`.

- `branches`  
  Object where keys are branch names as on GitHub (`refs/heads/<BRANCH_NAME>`).

For each branch:

- `description`  
  Free text for humans.

- `repoDir`  
  Relative or absolute path to local git directory used for this branch.  
  If relative, it is resolved from `rootDir`.  
  Example: `"repos/linkify/dev"` → `/opt/webook_deploy_debian/repos/linkify/dev`.

- `composeFile`  
  Relative or absolute path to `docker-compose.yml` for this project.  
  Example: `"repos/linkify/docker-compose.yml"`.

- `service`  
  The name of the Docker Compose service to build and restart for this branch.  
  Example: `"app-dev"` or `"app-prod"`.

- `enabled`  
  `true` or `false`. If `false`, this branch is ignored.

### 4.2 Concrete example for one project with dev + prod

```json
{
  "port": 4000,
  "path": "/github",

  "rootDir": "/opt/webook_deploy_debian",
  "deployScript": "deploy.sh",

  "projects": [
    {
      "name": "linkify",
      "repo": "ViktorNikolayevIndyn/linkify",
      "branches": {
        "dev-branch-cloud": {
          "description": "Dev deploy for linkify",
          "repoDir": "repos/linkify/dev",
          "composeFile": "repos/linkify/docker-compose.yml",
          "service": "app-dev",
          "enabled": true
        },
        "prod-main": {
          "description": "Production deploy for linkify",
          "repoDir": "repos/linkify/prod",
          "composeFile": "repos/linkify/docker-compose.yml",
          "service": "app-prod",
          "enabled": true
        }
      }
    }
  ]
}
```

Directory structure:

```text
/opt/webook_deploy_debian
  deploy.sh
  config/projects.json
  repos/
    linkify/
      dev/              # git clone of dev-branch-cloud
      prod/             # git clone of prod-main
      docker-compose.yml
```

---

## 5. Universal deploy script (`deploy.sh`)

`deploy.sh` is a generic script that:

1. Goes into the project’s git directory.
2. Fetches the remote branch.
3. Compares local `HEAD` with `origin/<branch>`.
4. If there are no new commits → **skip build & restart**.
5. If there are new commits → `git reset --hard`, then `docker compose build` + `up -d`.

Example implementation:

```bash
#!/bin/bash
set -e

# Universal deploy script for Docker-based projects.
# Called by webhook.js as:
#   deploy.sh <REPO_DIR> <BRANCH_NAME> <COMPOSE_FILE> <SERVICE_NAME>

REPO_DIR="$1"
BRANCH_NAME="$2"
COMPOSE_FILE="$3"
SERVICE_NAME="$4"

if [ -z "$REPO_DIR" ] || [ -z "$BRANCH_NAME" ] || [ -z "$COMPOSE_FILE" ] || [ -z "$SERVICE_NAME" ]; then
  echo "Usage: $0 <REPO_DIR> <BRANCH_NAME> <COMPOSE_FILE> <SERVICE_NAME>"
  exit 1
fi

echo "=== DEPLOY START ==="
echo "Repo dir     : $REPO_DIR"
echo "Branch       : $BRANCH_NAME"
echo "Compose file : $COMPOSE_FILE"
echo "Service      : $SERVICE_NAME"
echo "===================="

if [ ! -d "$REPO_DIR" ]; then
  echo "[ERROR] Repo directory does not exist: $REPO_DIR"
  exit 1
fi

cd "$REPO_DIR"

if [ ! -d .git ]; then
  echo "[ERROR] This directory is not a git repository: $REPO_DIR"
  exit 1
fi

echo "--- Git fetch ---"
git fetch origin "$BRANCH_NAME"

LOCAL_REV="$(git rev-parse HEAD)"
REMOTE_REV="$(git rev-parse "origin/$BRANCH_NAME")"

echo "Local  HEAD : $LOCAL_REV"
echo "Remote HEAD : $REMOTE_REV"

if [ "$LOCAL_REV" = "$REMOTE_REV" ]; then
  echo "--- No changes detected. Skipping Docker build and restart. ---"
  echo "=== DEPLOY DONE (NO CHANGES) ==="
  exit 0
fi

echo "--- Changes detected. Resetting to origin/$BRANCH_NAME ---"
git reset --hard "origin/$BRANCH_NAME"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "[ERROR] docker compose file not found: $COMPOSE_FILE"
  exit 1
fi

echo "--- Docker build ---"
docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"

echo "--- Docker up -d ---"
docker compose -f "$COMPOSE_FILE" up -d "$SERVICE_NAME"

echo "=== DEPLOY DONE (UPDATED) ==="
```

---

## 6. Webhook server (`src/webhook.js`)

High-level behavior:

- Reads `config/projects.json`.
- Starts HTTP server on `port` and `path`.
- Waits for GitHub `push` events.
- From payload it reads:
  - `repository.full_name` (e.g. `ViktorNikolayevIndyn/linkify`)
  - `ref` (e.g. `refs/heads/dev-branch-cloud`)
- Matches repo + branch in `projects[...]`.
- For the matched branch, resolves:
  - `rootDir` + `deployScript`
  - `rootDir` + `repoDir`
  - `rootDir` + `composeFile`
- Runs:

```bash
deploy.sh <resolved_repoDir> <branchName> <resolved_composeFile> <service>
```

Logs are printed to stdout (and to `journalctl` if run as systemd service).

---

## 7. Run webhook manually (for testing)

```bash
cd /opt/webook_deploy_debian
node src/webhook.js
```

You should see something like:

```text
[webhook] Listening on port 4000, path=/github
```

Test via `curl`:

```bash
curl -X POST http://127.0.0.1:4000/github   -H "Content-Type: application/json"   -H "X-GitHub-Event: push"   -d '{
    "ref": "refs/heads/dev-branch-cloud",
    "repository": { "full_name": "ViktorNikolayevIndyn/linkify" }
  }'
```

You should see deploy logs in the terminal.

---

## 8. Run as systemd service

Example unit file: `systemd/webhook.service.example`

```ini
[Unit]
Description=GitHub webhook deploy runner
After=network.target

[Service]
WorkingDirectory=/opt/webook_deploy_debian
ExecStart=/usr/bin/node /opt/webook_deploy_debian/src/webhook.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
cp systemd/webhook.service.example /etc/systemd/system/webook-deploy.service

systemctl daemon-reload
systemctl enable --now webook-deploy.service
systemctl status webook-deploy.service
```

Logs:

```bash
journalctl -u webook-deploy.service -n 100 --no-pager
```

---

## 9. GitHub webhook configuration

For each repo:

1. Go to **Settings → Webhooks → Add webhook**.
2. **Payload URL**:
   - `http://your-server-ip:4000/github`  
   - or `https://your-webhook-domain/github` if behind Cloudflare Tunnel.
3. **Content type**: `application/json`.
4. **Which events**: `Just the push event`.

On each push to a configured branch, the webhook server runs the deploy script for the matching project/branch.

---

## 10. Optional: Cloudflare Tunnel

Example `config.yml` for Cloudflare Tunnel:

```yaml
ingress:
  - hostname: app.example.com
    service: http://localhost:3002
  - hostname: dev.example.com
    service: http://localhost:3001
  - hostname: webhook.example.com
    service: http://localhost:4000
  - service: http_status:404
```

Then restart your tunnel service, for example:

```bash
systemctl restart cloudflared-your-tunnel.service
```

Now GitHub can reach your webhook via:

```text
https://webhook.example.com/github
```
