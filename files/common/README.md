# Server layout — multi-project box (any language)

Everything for one project lives under one named directory. Shared plumbing
(systemd template, launcher, deploy/build steps, backup script, sudoers)
handles any number of projects in any language with no per-project edits — each
project declares how to build and run via a few executables in its repo.

```
/home/deploy/
├── .bun/bin/bun                 bun runtime (used by projects that want it)
├── common/
│   ├── bin/
│   │   ├── deploy-app.sh        atomic deploy: checkout->build->swap->healthcheck->rollback
│   │   ├── rollback-app.sh      manual rollback to the kept previous release
│   │   ├── run-app.sh           ExecStart launcher: runs the project's ./run
│   │   ├── build-app.sh         build step: runs the project's ./build in the new release
│   │   ├── backup-all.sh        cron'd: nightly snapshot of every project
│   │   ├── free-port.sh         prints next free localhost port (3330-3399)
│   │   └── new-project.sh       scaffold a new project (RUN AS ROOT)
│   ├── env/shared.env           config/secrets shared by all apps (chmod 600)
│   └── PORTS                     port registry, one line per project
└── projects/
    └── <name>/
        ├── repo.git/            push target; post-receive calls deploy-app.sh
        ├── releases/<sha>/       each deploy's checkout (current + 1 previous kept)
        ├── app -> releases/<sha> live symlink (what systemd/run-app.sh use)
        ├── shared/              persistent data ($DATA_DIR): survives deploys
        ├── backups/             this project's snapshots only
        └── .env                 per-project secrets, OUTSIDE the work tree (chmod 600)
```

## The project contract (what each repo provides)
A project is language-agnostic. In the repo (which becomes the work tree) it ships:

- **`run`** — *required*, executable. Starts the server in the **foreground**
  and binds `$HOST:$PORT` (injected from `.env` by systemd). Examples:
  - bun:    `exec /home/deploy/.bun/bin/bun server.ts`
  - node:   `exec node server.js`
  - python: `exec python3 -m uvicorn app:app --host "$HOST" --port "$PORT"`
  - go/rust:`exec ./bin/server`
- **`build`** — *optional*, executable. Install deps / compile. Runs on every
  deploy, inside the new release, before the swap.
- **`backup`** — *optional*, executable. Snapshot `$DATA_DIR` into `$BACKUP_DIR`
  (env `DATE` provided). Runs nightly. If absent, the framework falls back to
  snapshotting `shared/*.db` with sqlite.

Bun fallbacks apply if `run`/`build` are absent (`run` → `bun server.ts`,
`build` → `bun install`) so legacy bun projects need no changes.

### Persistent data — IMPORTANT
The work tree is **replaced on every deploy** (atomic release swap), so anything
written into it is lost on the next push. Write databases, uploads, etc. to
**`$DATA_DIR`** (`projects/<name>/shared`, exported by `run-app.sh`). Backups
and pruning only ever touch `shared/` and `backups/`.

## Deploys (push-to-deploy, atomic, with rollback)
`git push prod main` triggers the post-receive hook → `deploy-app.sh <name> <sha>`:
1. takes a per-project lock (no overlapping deploys),
2. exports the commit into `releases/<sha>` and runs `build` there (off the live one),
3. atomically swaps the `app` symlink to the new release,
4. restarts `app@<name>` and health-checks (service active + `$PORT` accepting),
5. **on failure, swaps back to the previous release and restarts** = instant rollback,
6. on success, prunes releases keeping **current + 1 previous** (`KEEP=2`).

Manual rollback to the kept previous release:
```
sudo -u deploy /home/deploy/common/bin/rollback-app.sh <name>
```

## Shared plumbing
- **systemd**: one template `/etc/systemd/system/app@.service`. Manage a project
  with `systemctl {start,stop,restart,status} app@<name>`, logs with
  `journalctl -u app@<name>`. `%i` = project name. ExecStart calls
  `run-app.sh %i`, which `cd`s into the `app` symlink and execs the project's `./run`.
- **Caddy**: main `/etc/caddy/Caddyfile` is just `import sites/*.caddy`. One
  `/etc/caddy/sites/<name>.caddy` per project (its domain → its localhost port).
- **Backups**: single cron line runs `common/bin/backup-all.sh` nightly; each
  snapshot stays in that project's `backups/`, 14-day retention.
- **sudo**: `deploy` may run `systemctl restart app@*` (NOPASSWD) so deploy and
  rollback can restart their own service. Nothing else.

## Add a project
```
sudo /home/deploy/common/bin/new-project.sh <name> <domain> [port]
```
Then on your dev machine: ensure the repo has an executable `run` (and optional
`build`/`backup`), add the remote, and push:
```
git remote add prod deploy@<box>:/home/deploy/projects/<name>/repo.git
git push prod main          # checkout -> build -> swap -> health-check
```
Set real secrets in the project `.env`. The first push builds, starts, and
health-checks the service.

## env precedence
`common/env/shared.env` loads first, then `projects/<name>/.env` — so the
per-project file wins on any duplicate key (e.g. `PORT`).
