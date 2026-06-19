#!/bin/bash
# Atomic, language-agnostic deploy with health-check rollback. Called by a
# project's post-receive hook (runs as the deploy user).
#
#   deploy-app.sh <name> <newrev>
#
# Flow:
#   1. serialize with a per-project lock (no overlapping deploys)
#   2. export the pushed commit's tree into releases/<sha> (NEVER touches the
#      live release — git archive, no shared-index games)
#   3. build INSIDE the new release (off the live one) via build-app.sh
#   4. atomically swap the  app -> releases/<sha>  symlink
#   5. restart app@<name>, then health-check (service active + port accepting)
#   6. on failure: swap back to the previous release + restart = instant rollback
#   7. on success: prune old releases, keeping current + 1 previous (KEEP=2)
#
# Persistent data lives in projects/<name>/shared (exposed to the app as
# $DATA_DIR by run-app.sh), so it survives release swaps and pruning.
set -euo pipefail

NAME=${1:?usage: deploy-app.sh <name> <newrev>}
NEWREV=${2:?usage: deploy-app.sh <name> <newrev>}

ROOT="/home/deploy/projects/$NAME"
GIT_DIR="$ROOT/repo.git"
RELEASES="$ROOT/releases"
LIVE="$ROOT/app"                 # symlink -> releases/<sha>; what systemd uses
LOCK="$ROOT/.deploy.lock"
KEEP=2                           # current + 1 previous

mkdir -p "$RELEASES" "$ROOT/shared"

# --- 1. serialize deploys ---
exec 9>"$LOCK"
flock 9

SHORT=${NEWREV:0:12}
REL="$RELEASES/$SHORT"

# --- 2. export commit tree into a fresh release dir ---
echo "--> Preparing release $SHORT"
rm -rf "$REL"
mkdir -p "$REL"
git --git-dir="$GIT_DIR" archive --format=tar "$NEWREV" | tar -x -C "$REL"

# --- 3. build in the new release ---
/home/deploy/common/bin/build-app.sh "$REL"

# remember the live target for rollback (empty on first deploy)
PREV=""
if [ -L "$LIVE" ]; then PREV=$(readlink -f "$LIVE" || true); fi

# --- 4. atomic symlink swap ---
ln -sfn "$REL" "$LIVE.tmp"
mv -Tf "$LIVE.tmp" "$LIVE"

# --- 5. restart + health check ---
echo "--> Restarting app@$NAME"
sudo /usr/bin/systemctl restart "app@$NAME"

PORT=$(grep -hoP '^PORT=\K[0-9]+' "$ROOT/.env" 2>/dev/null | head -1 || true)
ok=0
for _ in $(seq 1 15); do
  if systemctl is-active --quiet "app@$NAME"; then
    if [ -z "$PORT" ] || (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      ok=1; break
    fi
  fi
  sleep 1
done

# --- 6. rollback on failure ---
if [ "$ok" != 1 ]; then
  echo "!! Health check FAILED for app@$NAME (port ${PORT:-?})"
  if [ -n "$PREV" ] && [ -d "$PREV" ] && [ "$PREV" != "$REL" ]; then
    echo "!! Rolling back to $(basename "$PREV")"
    ln -sfn "$PREV" "$LIVE.tmp"; mv -Tf "$LIVE.tmp" "$LIVE"
    sudo /usr/bin/systemctl restart "app@$NAME"
    echo "!! Rolled back. Deploy of $SHORT ABORTED."
  else
    echo "!! No previous release to roll back to — service is DOWN."
  fi
  rm -rf "$REL"
  exit 1
fi
echo "--> $SHORT healthy."

# --- 7. prune: keep newest KEEP release dirs (current + previous) ---
CURRENT=$(basename "$(readlink -f "$LIVE")")
ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  [ "$(basename "$old")" = "$CURRENT" ] && continue
  echo "--> pruning old release $(basename "$old")"
  rm -rf "$old"
done

echo "--> Deployed $NAME @ $SHORT."
