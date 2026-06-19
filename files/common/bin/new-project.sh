#!/bin/bash
# Scaffold a new project in the per-project layout. Language-agnostic: the
# project itself decides how to build and run (see the run/build contract). RUN
# AS ROOT.
#
#   new-project.sh <name> <domain> [port]
#
# Creates:  /home/deploy/projects/<name>/{repo.git,releases,shared,backups,.env}
#           /etc/caddy/sites/<name>.caddy   (reverse_proxy -> localhost:port)
#           enables app@<name>              (uses the shared systemd template)
#           registers the port in common/PORTS
#
# Atomic deploys: each push checks out into releases/<sha>, builds there, then
# atomically swaps the  app  symlink and health-checks (auto-rollback on fail).
# The work tree is replaced every deploy, so persistent data MUST live in
# shared/ — the app sees it as $DATA_DIR (exported by run-app.sh).
#
# In the project repo (which becomes the work tree) provide:
#   - run   (required, executable): start server in foreground, bind $HOST:$PORT.
#   - build (optional, executable): install deps / compile (runs each deploy).
#   - backup (optional, executable): snapshot $DATA_DIR into $BACKUP_DIR (nightly).
set -eu

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

NAME=${1:?usage: new-project.sh <name> <domain> [port]}
DOMAIN=${2:?usage: new-project.sh <name> <domain> [port]}

DEPLOY=deploy
HOME_DIR="/home/$DEPLOY"
ROOT="$HOME_DIR/projects/$NAME"

PORT=${3:-$(sudo -u "$DEPLOY" "$HOME_DIR/common/bin/free-port.sh")}

[ -e "$ROOT" ] && { echo "project '$NAME' already exists at $ROOT" >&2; exit 1; }

# --- project tree (owned by deploy). No app/ — first deploy creates the
#     app -> releases/<sha> symlink. ---
install -d -o "$DEPLOY" -g "$DEPLOY" "$ROOT" "$ROOT/releases" "$ROOT/shared" "$ROOT/backups"
sudo -u "$DEPLOY" git init --bare "$ROOT/repo.git" >/dev/null

# --- thin push-to-deploy hook: all logic lives in common/bin/deploy-app.sh so
#     future improvements need no re-scaffolding. ---
sudo -u "$DEPLOY" tee "$ROOT/repo.git/hooks/post-receive" >/dev/null <<EOF
#!/bin/bash
set -eu
NAME=$NAME
while read oldrev newrev ref; do
  if [ "\$ref" = "refs/heads/main" ]; then
    /home/deploy/common/bin/deploy-app.sh "\$NAME" "\$newrev"
  else
    echo "--> Received \$ref (stored, no deploy — only main deploys)."
  fi
done
EOF
sudo -u "$DEPLOY" chmod +x "$ROOT/repo.git/hooks/post-receive"

# --- starter .env (EDIT SECRETS AFTER) ---
sudo -u "$DEPLOY" tee "$ROOT/.env" >/dev/null <<EOF
PORT=$PORT
HOST=127.0.0.1
APP_SECRET=$(openssl rand -hex 32)
EOF
chown "$DEPLOY:$DEPLOY" "$ROOT/.env"
chmod 600 "$ROOT/.env"

# --- caddy site ---
tee "/etc/caddy/sites/$NAME.caddy" >/dev/null <<EOF
$DOMAIN {
	reverse_proxy localhost:$PORT {
		header_up X-Real-IP {remote_host}
	}
	encode gzip
}
EOF

# --- register port ---
echo "$NAME	$PORT" | sudo -u "$DEPLOY" tee -a "$HOME_DIR/common/PORTS" >/dev/null

# --- wire up services ---
systemctl enable "app@$NAME" >/dev/null
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy

cat <<EOF

Scaffolded '$NAME' on localhost:$PORT  ->  https://$DOMAIN
Next:
  1. point DNS A record for $DOMAIN at this box (Caddy gets HTTPS once it resolves)
  2. your repo must contain an executable  run  (and optionally  build / backup);
     write persistent data to \$DATA_DIR, never into the work tree
  3. add a git remote on your dev machine:
       git remote add prod $DEPLOY@$(hostname -I | awk '{print $1}'):$ROOT/repo.git
     then  git push prod main   (checks out -> builds -> swaps -> health-checks)
  4. set real secrets in $ROOT/.env  (APP_SECRET was pre-generated)

Rollback later:  sudo -u deploy /home/deploy/common/bin/rollback-app.sh $NAME
EOF
