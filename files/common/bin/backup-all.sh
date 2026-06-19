#!/bin/bash
# Back up EVERY project into that project's OWN backups/ dir. Runs as the
# deploy user from cron. Each project stays isolated — no mixing.
#
# Persistent data lives in projects/<name>/shared (= the app's $DATA_DIR), NOT
# in the work tree (which is replaced every deploy). Two modes per project:
#   1. Custom: if the work tree ships an executable  app/backup , run it with
#      DATA_DIR / BACKUP_DIR / DATE exported. The script decides what a snapshot
#      means (any db, any language). Language-agnostic opt-in.
#   2. Fallback: otherwise snapshot every shared/*.db with sqlite3 .backup (the
#      zero-config common case for bun:sqlite projects).
# Projects with neither an app/backup nor any shared/*.db are simply skipped.
set -eu

PROJECTS=/home/deploy/projects
KEEP_DAYS=14

# Don't depend on inherited cwd (cron / sudo -u may start us somewhere deploy
# can't chdir back into, which makes find warn). Anchor to a readable dir.
cd /

shopt -s nullglob
DATE=$(date +%F)

for dir in "$PROJECTS"/*/; do
  name=$(basename "$dir")
  app="${dir}app"          # symlink -> current release
  shared="${dir}shared"
  bdir="${dir}backups"
  [ -d "$shared" ] || continue

  if [ -x "$app/backup" ]; then
    mkdir -p "$bdir"
    ( cd "$app" && DATA_DIR="$shared" BACKUP_DIR="$bdir" DATE="$DATE" ./backup )
    find "$bdir" -type f -mtime +$KEEP_DAYS -delete
    continue
  fi

  # fallback: sqlite snapshot of each shared/*.db
  dbs=("$shared"/*.db)
  [ ${#dbs[@]} -gt 0 ] || continue
  mkdir -p "$bdir"
  for dbfile in "${dbs[@]}"; do
    base=$(basename "$dbfile" .db)
    out="$bdir/${base}-${DATE}.db"
    # .backup is a safe online copy even while the app holds the db open.
    sqlite3 "$dbfile" ".backup '$out'"
  done
  # prune snapshots older than KEEP_DAYS for THIS project only
  find "$bdir" -name '*.db' -mtime +$KEEP_DAYS -delete
done
