#!/bin/bash
# Generic build step run by deploy-app.sh inside the NEW release dir, after the
# commit tree is exported and before the symlink swap.
#
#   build-app.sh <dir>
#
# Runs the project's OWN build so the framework stays language-agnostic. A
# project ships an executable  build  that installs deps and/or compiles.
# Examples of build:
#
#   #!/bin/bash   (bun)     exec /home/deploy/.bun/bin/bun install --frozen-lockfile
#   #!/bin/bash   (node)    exec npm ci
#   #!/bin/bash   (python)  exec pip install --user -r requirements.txt
#   #!/bin/bash   (go)      exec go build -o bin/server ./cmd/server
#   #!/bin/bash   (rust)    exec cargo build --release
#
# Fallback: no ./build but a package.json/bun.lock is present -> bun install,
# so pre-existing bun projects keep working. Otherwise the build is skipped.
set -eu

DIR=${1:?usage: build-app.sh <dir>}
cd "$DIR"

if [ -x ./build ]; then
  echo "--> running ./build"
  ./build
elif [ -f bun.lock ] || [ -f package.json ]; then
  echo "--> bun install --frozen-lockfile (fallback)"
  /home/deploy/.bun/bin/bun install --frozen-lockfile
else
  echo "--> no ./build and no package.json — skipping build"
fi
