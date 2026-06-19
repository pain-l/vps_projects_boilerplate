# vps_projects_boilerplate

Turn a **freshly installed Debian 13 (trixie)** VPS into a lean, secure,
multi-project, **any-language**, **git push-to-deploy** host — with one script.

One box hosts many small apps. Each app lives in its own directory, gets its own
git remote, its own systemd service, and its own Caddy-served HTTPS domain.
`git push` builds and atomically swaps in the new version, health-checks it, and
rolls back automatically if it doesn't come up. No Docker, no Kubernetes, no
PaaS — just systemd, Caddy, and a handful of small shell scripts.

```
            ┌─────────── your dev machine ───────────┐
            │   git push prod main                    │
            └───────────────────┬─────────────────────┘
                                │ ssh (key only)
   ┌────────────────────────────▼──────────────────────────────┐
   │  VPS (Debian 13)                                           │
   │                                                            │
   │  Caddy :443/:80  ──reverse_proxy──▶ 127.0.0.1:<port>       │
   │   (auto-HTTPS, one site file per project)   │              │
   │                                             ▼              │
   │  systemd  app@<name>  ──▶ run-app.sh ──▶ project ./run     │
   │                                                            │
   │  push ─▶ post-receive ─▶ deploy-app.sh:                    │
   │           checkout → build → swap → health-check → rollback│
   │                                                            │
   │  apps run as the unprivileged `deploy` user, never root    │
   └────────────────────────────────────────────────────────────┘
```

## Quick start

On a brand-new Debian 13 box you can reach over SSH:

```bash
# 1. clone this repo onto the box (as root, or copy it up)
git clone <your-fork-url> vps && cd vps/vps_projects_boilerplate

# 2. configure — at minimum paste your SSH PUBLIC key
cp config.env.example config.env
nano config.env            # set ADMIN_SSH_PUBKEY="ssh-ed25519 AAAA..."

# 3. run it  (if ./bootstrap.sh isn't executable, use: sudo bash bootstrap.sh)
sudo ./bootstrap.sh

# 4. verify
sudo ./verify.sh
```

Then add your first project (see [docs/ADDING_A_PROJECT.md](docs/ADDING_A_PROJECT.md)):

```bash
sudo /home/deploy/common/bin/new-project.sh myapp myapp.example.com
# point myapp.example.com DNS at the box, then from your dev machine:
git remote add prod deploy@<server-ip>:/home/deploy/projects/myapp/repo.git
git push prod main
```

> ⚠️ **Don't lock yourself out.** `bootstrap.sh` disables SSH password login. It
> refuses to do so unless your `ADMIN_SSH_PUBKEY` is installed first, so running
> it can't lock you out — but make sure that key is one you actually hold, and
> keep your current SSH session open until you've confirmed key login works in a
> new terminal.

## What `bootstrap.sh` does

| # | Step | Result |
|---|------|--------|
| 1 | Preflight | verifies root, Debian 13, a valid public key |
| 2 | Base packages | git, curl, sqlite3, openssl, gnupg, ufw, fail2ban, unattended-upgrades |
| 3 | Timezone | `timedatectl set-timezone` |
| 4 | Caddy | official apt repo; the only public listener |
| 5 | `deploy` user | unprivileged, password login disabled |
| 6 | SSH keys | your key → root (admin) + deploy (git push) |
| 7 | Bun runtime | installed for deploy (optional) |
| 8 | `common/` framework | launcher, deploy/build/backup, new-project, free-port |
| 9 | systemd template | `app@.service` |
| 10 | Caddy config | `import sites/*.caddy`, enabled + running |
| 11 | sudoers | deploy may `systemctl restart app@*` and nothing else |
| 12 | Backup cron | nightly per-project snapshots, 14-day retention |
| 13 | Firewall (UFW) | allow SSH + 80 + 443, deny the rest |
| 14 | fail2ban | SSH brute-force protection |
| 15 | unattended-upgrades | automatic security patches |
| 16 | SSH hardening | key-only, `PermitRootLogin prohibit-password` |

The script is **idempotent** — re-run it any time. It never touches existing
project code or data (`PORTS` and `shared.env` are preserved on re-runs).

## Repository layout

```
vps_projects_boilerplate/
├── bootstrap.sh            the installer (run as root on the fresh box)
├── verify.sh               post-install sanity checks
├── config.env.example      copy to config.env and edit
├── docs/
│   ├── ARCHITECTURE.md     how the whole thing fits together + design rationale
│   ├── ADDING_A_PROJECT.md step-by-step: new project → first deploy → rollback
│   └── PROJECT_CONTRACT.md the run/build/backup contract every app implements
├── files/                  exactly what gets installed on the server
│   ├── common/{bin,env,PORTS,README.md}
│   ├── systemd/app@.service
│   ├── caddy/Caddyfile
│   └── sudoers/deploy-restart-app
└── examples/
    ├── hello-bun/          minimal Bun app following the contract
    └── hello-python/       minimal Python app (proves it's language-agnostic)
```

## Requirements
- A fresh **Debian 13 (trixie)** VPS with root SSH access.
- An SSH **key pair** on your machine (the public key goes in `config.env`).
- For each project: a domain (or subdomain) whose DNS A record you can point at
  the box, so Caddy can issue HTTPS.

## License
Use it however you like.
