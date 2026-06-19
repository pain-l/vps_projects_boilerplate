# The project contract

A project can be written in **any language**. To be deployable on this host, its
repository (which becomes the work tree) provides up to three executables at its
root. Only `run` is required.

## `run` — required
Starts the server in the **foreground** and binds `$HOST:$PORT`. Use `exec` so
systemd supervises the real process (and signals/restarts work correctly).

`$HOST` and `$PORT` come from the project's `.env`, which systemd loads before
starting the service. Bind to `$HOST` (always `127.0.0.1`) — Caddy is the only
public listener.

```bash
#!/usr/bin/env bash
# bun
exec /home/deploy/.bun/bin/bun server.ts
```
```bash
#!/usr/bin/env bash
# node
exec node server.js
```
```bash
#!/usr/bin/env bash
# python
exec python3 -m uvicorn app:app --host "$HOST" --port "$PORT"
```
```bash
#!/usr/bin/env bash
# go / rust (compiled in ./build)
exec ./bin/server
```

If no `run` exists, the launcher falls back to `bun server.ts` (so a plain bun
project works with no `run` file).

## `build` — optional
Installs dependencies and/or compiles. Runs on **every deploy**, inside the new
release directory, *before* the symlink swap — so a failing build never touches
the live version.

```bash
#!/usr/bin/env bash
exec /home/deploy/.bun/bin/bun install --frozen-lockfile   # bun
# npm ci                                                   # node
# pip install --user -r requirements.txt                   # python
# go build -o bin/server ./cmd/server                      # go
# cargo build --release && cp target/release/server bin/   # rust
```

If no `build` exists but a `package.json`/`bun.lock` is present, the framework
runs `bun install --frozen-lockfile` as a fallback. Otherwise the build is
skipped.

## `backup` — optional
Writes a snapshot of persistent state into `$BACKUP_DIR`. Runs nightly with
these variables exported: `DATA_DIR`, `BACKUP_DIR`, `DATE` (YYYY-MM-DD).

```bash
#!/usr/bin/env bash
set -eu
cp -f "$DATA_DIR/app.db" "$BACKUP_DIR/app-$DATE.db"
```

If no `backup` exists, the framework falls back to snapshotting every
`shared/*.db` with `sqlite3 .backup` (the zero-config case for SQLite apps).
Snapshots older than 14 days are pruned automatically.

## Persistent data — the one rule you must follow
The work tree is **replaced on every deploy**. Anything written into it is lost
on the next push. Write databases, uploads, caches, etc. to **`$DATA_DIR`**
(exported to your `run`/`build`/`backup` as
`/home/deploy/projects/<name>/shared`). It persists across deploys and is what
backups target.

```ts
const db = new Database(`${process.env.DATA_DIR}/app.db`);
```

## Environment your app receives
| Variable | Source | Notes |
|---|---|---|
| `PORT` | project `.env` | bind here |
| `HOST` | project `.env` | always `127.0.0.1` |
| `DATA_DIR` | set by `run-app.sh` | persistent storage dir |
| anything in `shared.env` | `common/env/shared.env` | shared across all apps |
| anything in `.env` | `projects/<name>/.env` | overrides shared on conflict |

## ⚠️ The executable bit
`run`, `build`, and `backup` must be committed to git **executable**. Deploys
check out your code with `git archive`, which preserves committed mode bits —
but only if you set them.

```bash
chmod +x run build backup          # on Linux/macOS, before committing
git update-index --chmod=+x run build backup   # on Windows
```

A non-executable `run` makes the launcher fall back to `bun server.ts`, which
will fail for non-bun apps — so this is the most common first-deploy mistake.
