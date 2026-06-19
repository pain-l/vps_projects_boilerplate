#!/bin/bash
# Manually roll back a project to its kept previous release (KEEP=2 means there
# is exactly one previous to go back to). Runs as the deploy user.
#
#   rollback-app.sh <name>
#
# Swaps the  app  symlink to the most recent release that ISN'T the current one,
# restarts, and health-checks. Does not prune.
set -euo pipefail

NAME=${1:?usage: rollback-app.sh <name>}
ROOT="/home/deploy/projects/$NAME"
RELEASES="$ROOT/releases"
LIVE="$ROOT/app"
LOCK="$ROOT/.deploy.lock"

exec 9>"$LOCK"
flock 9

[ -L "$LIVE" ] || { echo "no live release for $NAME" >&2; exit 1; }
CURRENT=$(readlink -f "$LIVE")

PREV=""
for d in $(ls -1dt "$RELEASES"/*/ 2>/dev/null); do
  d=${d%/}
  [ "$(readlink -f "$d")" = "$CURRENT" ] && continue
  PREV=$d; break
done
[ -n "$PREV" ] || { echo "no previous release kept for $NAME — nothing to roll back to" >&2; exit 1; }

echo "--> Rolling back $NAME: $(basename "$CURRENT") -> $(basename "$PREV")"
ln -sfn "$PREV" "$LIVE.tmp"; mv -Tf "$LIVE.tmp" "$LIVE"
sudo /usr/bin/systemctl restart "app@$NAME"

PORT=$(grep -hoP '^PORT=\K[0-9]+' "$ROOT/.env" 2>/dev/null | head -1 || true)
for _ in $(seq 1 15); do
  if systemctl is-active --quiet "app@$NAME"; then
    if [ -z "$PORT" ] || (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      echo "--> Rolled back and healthy."; exit 0
    fi
  fi
  sleep 1
done
echo "!! Rolled back but health check failed — check journalctl -u app@$NAME" >&2
exit 1
