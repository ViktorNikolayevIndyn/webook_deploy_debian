# Git Webhook Deploy – Lite Guide

This is the **short version** of the docs for the Debian/Proxmox webhook deploy setup.

---

## What it does

- Listens for **Git webhooks** (push events).
- For each push, matches a **project** by repo + branch.
- Runs that project’s `deploy.sh` (usually Docker build + up).
- Stores all config in `config/projects.json`.
- Has helpers to:
  - prepare environment (`env-bootstrap.sh`),
  - create SSH user (`enable_ssh.sh`),
  - configure projects (`init.sh`),
  - check environment (`check_env.sh`).

---

## Files you care about

```text
start.sh                 # entry point, runs all steps
webhook.js               # webhook HTTP server (Node.js)
config/projects.json     # generated config (init.sh)
config/projects.example.json  # example with placeholders
scripts/env-bootstrap.sh # install tools (Docker, etc.)
scripts/enable_ssh.sh    # SSH user + groups
scripts/init.sh          # config wizard (webhook + projects)
scripts/check_env.sh     # environment & config checks
scripts/deploy.template.sh  # copied to each project as deploy.sh
```

---

## 1. First run (on a fresh Debian / LXC)

```bash
cd /opt
git clone git@github.com:ViktorNikolayevIndyn/webook_deploy_debian.git
cd webook_deploy_debian
chmod +x start.sh
sudo ./start.sh
```

`start.sh` will:

1. Offer to run `scripts/env-bootstrap.sh` → install tools, write `config/env_bootstrap.json`.
2. Offer to run `scripts/enable_ssh.sh` → create SSH user, add to `sudo`/`docker`, write `config/ssh_state.json`.
3. Offer to run `scripts/init.sh` → interactive config → write `config/projects.json` and `config/projects_state.json`.

> Script versions are tracked inside `start.sh`.  
> When you change logic, bump the version there; next run will suggest re‑running that step.

---

## 2. Configure projects (init.sh)

`init.sh` asks for:

- Webhook:
  - port (default `4000`)
  - path (default `/github`)
  - optional secret
  - Cloudflare metadata (rootDomain, subdomain, tunnelName, etc.)

- For each project:
  - internal name
  - git URL (SSH recommended)
  - branch name
  - workDir on server (`/opt/<project>`)
  - deploy mode (`dev` / `prod`…) → stored in `deployArgs`
  - Cloudflare metadata (rootDomain, subdomain, port, path, tunnelName)

Result: `config/projects.json` + one `deploy.sh` per `workDir` (from `deploy.template.sh`).

---

## 3. Customize deploy.sh per project

In each `workDir`, edit `deploy.sh`:

- update branch names if needed,
- add `npm`/`yarn` steps,
- add `docker compose build / up` commands.

This is where your real deployment logic lives.

**⚡ Performance note:** The template includes smart change detection - it only rebuilds when necessary (package.json, Dockerfile changes). Code-only changes trigger a quick restart (~5-10 sec instead of 5-7 min). See `FAST-DEPLOY-RU.md` or `OPTIMIZATION.md` for details.

---

## 4. Run webhook server

Install dependencies and start:

```bash
cd /opt/webook_deploy_debian
npm install
node webhook.js
```

Or create a systemd service that runs:

```bash
ExecStart=/usr/bin/node /opt/webook_deploy_debian/webhook.js
WorkingDirectory=/opt/webook_deploy_debian
```

Webhook URL (example, if Cloudflare points it):

```text
https://webhook.linkify.cloud/github
```

Make sure the secret matches `config.webhook.secret` (if you use one).

---

## 5. Cloudflare (manual)

- Create Cloudflare Tunnels yourself.
- Map domains/subdomains to the local ports defined in `projects.json`, e.g.:

  - `dev.linkify.cloud` → `http://127.0.0.1:3001`
  - `app.linkify.cloud` → `http://127.0.0.1:3002`
  - `webhook.linkify.cloud` → `http://127.0.0.1:4000/github`

- Use `tunnelName` in JSON only as a label, not for automation.

---

## 6. Check environment

```bash
./scripts/check_env.sh
# or with SSH user:
./scripts/check_env.sh webuser
```

It checks:

- Docker, cloudflared, node, curl, jq in PATH.
- Docker daemon reachability.
- Presence/versions of:
  - `env_bootstrap.json`
  - `ssh_state.json`
  - `projects_state.json`
- Webhook config + project summary from `projects.json`.
- Whether the webhook port is listening.

---

## 7. Typical Git flow

1. Developer pushes to `dev-branch-cloud` or `prod-main`.
2. Git provider sends webhook to `https://webhook.<rootDomain>/github`.
3. `webhook.js` matches repo + branch in `projects.json`.
4. Runs the project’s `deploy.sh` with the configured `deployArgs`.
5. Your Docker stack redeploys automatically.


