#!/bin/bash
# Print the next free localhost app port. Scans each project's .env PORT= line.
# Range 3330-3399 (Caddy is the only public listener; apps bind localhost only).
set -eu

START=3330
END=3399

used=$(grep -hoP '^PORT=\K[0-9]+' /home/deploy/projects/*/.env 2>/dev/null | sort -u || true)

for p in $(seq "$START" "$END"); do
  if ! grep -qx "$p" <<<"$used"; then
    echo "$p"
    exit 0
  fi
done

echo "no free port in $START-$END" >&2
exit 1
