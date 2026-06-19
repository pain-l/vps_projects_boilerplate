# Architecture

A single small VPS hosting many independent apps, each deployed by `git push`.
The design goals, in order: **secure by default**, **language-agnostic**,
**no per-project plumbing edits**, and **safe deploys** (atomic + auto-rollback).

## The pieces

| Concern | Tool | Why |
|---|---|---|
| Public TLS termination | **Caddy** | automatic HTTPS, one tiny site file per project |
| Process supervision | **systemd** | one template unit covers every project; restarts, limits |
| Build & release | **shell scripts** in `common/bin` | no daemon, trivial to read and audit |
| Isolation | **`deploy` user** | apps never run as root; minimal sudo grant |
| Data safety | per-project `shared/` + nightly backups | data outlives ephemeral releases |

Everything lives under `/home/deploy`:

```
/home/deploy/
├── .bun/bin/bun                 bun runtime (optional; default fallback runtime)
├── common/
│   ├── bin/
│   │   ├── new-project.sh       scaffold a project (run as root)
│   │   ├── deploy-app.sh        atomic deploy + health-check + rollback + prune
│   │   ├── rollback-app.sh      manual rollback to the kept previous release
│   │   ├── build-app.sh         runs the project's ./build in the new release
│   │   ├── run-app.sh           systemd ExecStart → execs the project's ./run
│   │   ├── backup-all.sh        nightly: snapshot each project into its backups/
│   │   └── free-port.sh         next free localhost port in 3330–3399
│   ├── env/shared.env           env shared by all apps (loaded before each .env)
│   ├── PORTS                     human-readable port registry
│   └── README.md
└── projects/
    └── <name>/
        ├── repo.git/            bare repo; post-receive hook → deploy-app.sh
        ├── releases/<sha>/       one dir per deploy (current + 1 previous kept)
        ├── app -> releases/<sha> the LIVE symlink (what systemd uses)
        ├── shared/              persistent data, exposed to the app as $DATA_DIR
        ├── backups/             this project's snapshots (14-day retention)
        └── .env                 PORT / HOST / secrets (chmod 600, outside work tree)
```

System-level files the bootstrap installs:

```
/etc/systemd/system/app@.service       the template (%i = project name)
/etc/caddy/Caddyfile                    import sites/*.caddy
/etc/caddy/sites/<name>.caddy           one per project (domain → localhost port)
/etc/sudoers.d/deploy-restart-app       deploy may: systemctl restart app@*
```

## Request path

```
client ──HTTPS──▶ Caddy :443 ──reverse_proxy──▶ 127.0.0.1:<PORT> ──▶ app@<name>
```

Apps bind **127.0.0.1 only** (never a public interface); Caddy is the sole
public listener. Ports live in the range **3330–3399**, one per project, handed
out by `free-port.sh` and recorded in `PORTS`.

## Deploy flow (the heart of it)

`git push prod main` → the bare repo's `post-receive` hook → `deploy-app.sh <name> <sha>`:

1. **Lock** — `flock` on a per-project lock file; no two deploys overlap.
2. **Export** — `git archive <sha> | tar -x` into `releases/<sha>`. Uses the
   committed tree directly (no shared-index surprises) and never touches the
   currently-live release.
3. **Build** — `build-app.sh` runs the project's `./build` *inside the new
   release*, so a slow or failing build never affects the running version.
4. **Swap** — atomically repoint the `app` symlink at the new release
   (`ln -sfn` + `mv -T`, a single rename syscall).
5. **Restart + health-check** — `systemctl restart app@<name>`, then poll up to
   15s for the service to be `active` **and** the port to accept a TCP
   connection.
6. **Rollback on failure** — if it never comes up, swap the symlink back to the
   previous release, restart, and exit non-zero (the push output shows the
   failure). The broken release dir is removed.
7. **Prune on success** — keep the newest `KEEP=2` releases (current + one
   previous, for `rollback-app.sh`); delete older ones.

### Why a symlink + release dirs?
Atomic, reversible deploys. The running process keeps serving from its release
until the instant systemd restarts it on the new one; a bad build is caught
before it can replace a good version, and rollback is just another symlink swap.

### Why `shared/` and `$DATA_DIR`?
Because the work tree is replaced on every deploy, anything written *into* it
(a SQLite file, uploads) would vanish on the next push. `run-app.sh` exports
`DATA_DIR=/home/deploy/projects/<name>/shared` and the app writes its
persistent state there. Backups and pruning only ever touch `shared/` and
`backups/`, never releases.

## The systemd template

`app@.service` is a single parameterized unit (`%i` = project name):

- `WorkingDirectory=/home/deploy/projects/%i/app` (the live symlink)
- `ExecStart=/home/deploy/common/bin/run-app.sh %i` → execs the project's `./run`
- loads `common/env/shared.env` then `projects/%i/.env` (per-project wins)
- `User=deploy`, `MemoryMax=400M`, `NoNewPrivileges=true`, `PrivateTmp=true`,
  `Restart=always`

Manage any project with the usual verbs: `systemctl status|restart|stop app@<name>`,
`journalctl -u app@<name>`.

## Security model

- **No password SSH.** Key-only; `PermitRootLogin prohibit-password`. The
  hardening drop-in is named `00-hardening.conf` so it is read *before*
  `50-cloud-init.conf` — sshd uses the **first** value seen per keyword, and
  cloud-init re-enables password auth, so a higher-numbered file would be
  silently ignored. This ordering is load-bearing.
- **Unprivileged apps.** Everything runs as `deploy`. The only privilege it has
  is a single NOPASSWD sudoers rule: `systemctl restart app@*` — needed so the
  deploy hook can restart its own service. It cannot `stop`, cannot touch other
  units, cannot escalate.
- **Firewall.** UFW allows only SSH + 80 + 443 inbound.
- **fail2ban** bans SSH brute-forcers; **unattended-upgrades** applies security
  patches automatically.
- **Per-app limits.** `MemoryMax=400M` keeps one misbehaving app from taking
  down the box (tune per box/app).

## Deliberate limits (know these)

- The health check is **TCP-level** (port accepts a connection) plus
  `systemctl is-active`. An app that binds the port but returns 500s on real
  routes will pass. If you want stricter gating, have the app expose a health
  path and curl it for 2xx — easy to add to `deploy-app.sh`.
- A crash-looping `run` is caught (it never binds the port) and rolled back.
- `KEEP=2` means exactly one previous release is retained for rollback. Bump it
  in `deploy-app.sh` if you want deeper history.
- This targets a **single box**. There's no clustering, no zero-downtime
  multi-instance handoff (a restart is a sub-second blip). For most small
  apps that's the right trade.
