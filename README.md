# webook_deploy_debian

Universal GitHub webhook → deploy runner for Debian / Proxmox (LXC or bare metal).

This service listens for GitHub **push** events and runs project-specific deploy commands based on a simple JSON configuration.  
It is designed to be:

- **Repository-agnostic** – supports multiple GitHub repos and branches.
- **Deploy-agnostic** – runs any shell command (e.g. `deploy.sh`, `docker compose`, etc.).
- **Server-friendly** – works well on Debian 11/12, Proxmox LXC, and behind Cloudflare Tunnel.

---

## Features

- One webhook endpoint for **multiple repositories and branches**.
- Per-project configuration via `config/projects.json`.
- Branch-based deploy commands (e.g. dev vs prod).
- Simple Node.js HTTP server (no frameworks).
- Can be exposed safely via Cloudflare Tunnel.
- Runs as a systemd service.

---

## Repository layout

Recommended structure of this repo:

```text
webook_deploy_debian/
  package.json
  README.md
  .gitignore

  config/
    projects.example.json    # example config
    projects.json            # real config (not committed)

  src/
    webhook.js               # main webhook server
    deploy-runner.js         # (optional future extensions)

  systemd/
    webhook.service.example  # systemd unit template
