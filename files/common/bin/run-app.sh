#!/bin/bash
# Generic service launcher used by app@<name>.service ExecStart.
#
#   run-app.sh <name>
#
# Runs the project's OWN entrypoint so the framework stays language-agnostic.
# A project just ships an executable  app/run  that starts its server in the
# foreground and binds $HOST:$PORT (those come from the project .env, which
# systemd has already loaded into the environment). Examples of app/run:
#
#   #!/bin/bash            (bun)        exec /home/deploy/.bun/bin/bun server.ts
#   #!/bin/bash            (node)       exec node server.js
#   #!/bin/bash            (python)     exec python -m uvicorn app:app --host "$HOST" --port "$PORT"
#   #!/bin/bash            (go/rust)    exec ./bin/server
#
# Fallback: if there's no app/run but there is a server.ts, run it with bun so
# pre-existing bun projects keep working with no changes.
set -eu

NAME=${1:?usage: run-app.sh <name>}
APP="/home/deploy/projects/$NAME/app"

# Persistent data dir, stable across release swaps. The app MUST write its db,
# uploads, etc. here (NOT in the work tree, which is replaced every deploy).
export DATA_DIR="/home/deploy/projects/$NAME/shared"
mkdir -p "$DATA_DIR"

cd "$APP"

if [ -x ./run ]; then
  exec ./run
elif [ -f server.ts ]; then
  exec /home/deploy/.bun/bin/bun server.ts
else
  echo "run-app.sh: no executable ./run and no server.ts in $APP" >&2
  exit 1
fi
