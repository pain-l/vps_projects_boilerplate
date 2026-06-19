#!/usr/bin/env bash
#
# bootstrap.sh — turn a freshly installed Debian 13 (trixie) VPS into a
# multi-project, any-language, push-to-deploy host.
#
# Run as root on the fresh box:
#
#     git clone <this-repo> vps && cd vps/vps_projects_boilerplate
#     cp config.env.example config.env && nano config.env   # set ADMIN_SSH_PUBKEY
#     sudo ./bootstrap.sh
#
# What you get (mirrors the reference setup documented in docs/ARCHITECTURE.md):
#   - unprivileged `deploy` user; apps run as deploy, never root
#   - Bun runtime for deploy (optional)
#   - Caddy as the sole public listener (auto-HTTPS), one site file per project
#   - systemd template app@.service + language-agnostic launcher/build/deploy
#   - atomic push-to-deploy with health-check rollback (common/bin/*)
#   - nightly per-project backups via cron
#   - SSH hardening (key-only), UFW firewall, fail2ban, unattended-upgrades
#
# The script is IDEMPOTENT: safe to re-run. It never deletes project data.
#
# IMPORTANT: it disables SSH password login. It will REFUSE to do so unless a
# valid public key is installed first, so you cannot lock yourself out by
# running it — but make sure ADMIN_SSH_PUBKEY is the key you actually hold.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. setup, logging, config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$SCRIPT_DIR/files"

# fixed by design — the framework scripts in files/common/bin hardcode these.
# Do not change without editing those scripts too.
DEPLOY_USER="deploy"
DEPLOY_HOME="/home/$DEPLOY_USER"

c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'; c_ylw=$'\033[1;33m'; c_off=$'\033[0m'
step() { echo; echo "${c_blue}==>${c_off} $*"; }
ok()   { echo "${c_grn}  ok${c_off} $*"; }
warn() { echo "${c_ylw}  !!${c_off} $*" >&2; }
die()  { echo "${c_red}ERROR:${c_off} $*" >&2; exit 1; }
trap 'die "failed at line $LINENO. Nothing destructive runs after a failure; fix and re-run."' ERR

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./bootstrap.sh)"

CONFIG="$SCRIPT_DIR/config.env"
[ -f "$CONFIG" ] || die "missing $CONFIG — copy config.env.example to config.env and edit it."
# shellcheck disable=SC1090
source "$CONFIG"

# config defaults (only ADMIN_SSH_PUBKEY is mandatory)
SSH_PORT="${SSH_PORT:-22}"
TIMEZONE="${TIMEZONE:-UTC}"
INSTALL_BUN="${INSTALL_BUN:-true}"
HARDEN_SSH="${HARDEN_SSH:-true}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

# ---------------------------------------------------------------------------
# 1. preflight
# ---------------------------------------------------------------------------
step "Preflight checks"

. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
if [ "${ID:-}" != "debian" ]; then
  warn "this OS is '${ID:-unknown}', not debian — proceeding, but designed for Debian 13."
elif [ "${VERSION_ID:-}" != "13" ]; then
  warn "Debian ${VERSION_ID:-?} detected; this targets Debian 13 (trixie). Proceeding."
else
  ok "Debian 13 (trixie)"
fi

ADMIN_SSH_PUBKEY="${ADMIN_SSH_PUBKEY:-}"
[ -n "$ADMIN_SSH_PUBKEY" ] || die "ADMIN_SSH_PUBKEY is empty in config.env — required so SSH hardening can't lock you out."
case "$ADMIN_SSH_PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-*\ *) ok "ADMIN_SSH_PUBKEY looks valid" ;;
  *) die "ADMIN_SSH_PUBKEY does not look like an OpenSSH public key (expected 'ssh-ed25519 AAAA...')." ;;
esac
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die "SSH_PORT invalid: $SSH_PORT"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 2. base packages
# ---------------------------------------------------------------------------
step "Installing base packages"
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl git gnupg sqlite3 openssl \
  debian-keyring debian-archive-keyring apt-transport-https \
  ufw fail2ban unattended-upgrades >/dev/null
ok "base packages installed"

# ---------------------------------------------------------------------------
# 3. timezone
# ---------------------------------------------------------------------------
step "Setting timezone -> $TIMEZONE"
timedatectl set-timezone "$TIMEZONE" 2>/dev/null && ok "timezone set" || warn "could not set timezone (continuing)"

# ---------------------------------------------------------------------------
# 4. Caddy (official apt repo)
# ---------------------------------------------------------------------------
step "Installing Caddy"
if command -v caddy >/dev/null 2>&1; then
  ok "caddy already present ($(caddy version | head -1))"
else
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  ok "caddy installed ($(caddy version | head -1))"
fi

# ---------------------------------------------------------------------------
# 5. deploy user
# ---------------------------------------------------------------------------
step "Creating unprivileged '$DEPLOY_USER' user"
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  ok "user '$DEPLOY_USER' already exists"
else
  adduser --disabled-password --gecos "" "$DEPLOY_USER" >/dev/null
  ok "user '$DEPLOY_USER' created (password login disabled)"
fi
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_HOME/projects"

# ---------------------------------------------------------------------------
# 6. SSH authorized keys (root for admin, deploy for git push)
# ---------------------------------------------------------------------------
step "Installing SSH public key"
add_key() {  # add_key <authorized_keys_path> <owner>
  local f="$1" owner="$2"
  install -d -m 700 -o "$owner" -g "$owner" "$(dirname "$f")"
  touch "$f"; chown "$owner:$owner" "$f"; chmod 600 "$f"
  grep -qxF "$ADMIN_SSH_PUBKEY" "$f" || echo "$ADMIN_SSH_PUBKEY" >> "$f"
}
add_key /root/.ssh/authorized_keys root
add_key "$DEPLOY_HOME/.ssh/authorized_keys" "$DEPLOY_USER"
ok "key installed for root (admin) and $DEPLOY_USER (git push)"

# ---------------------------------------------------------------------------
# 7. Bun runtime (for deploy)
# ---------------------------------------------------------------------------
if [ "$INSTALL_BUN" = "true" ]; then
  step "Installing Bun for $DEPLOY_USER"
  if [ -x "$DEPLOY_HOME/.bun/bin/bun" ]; then
    ok "bun already installed"
  else
    sudo -u "$DEPLOY_USER" -H bash -c 'curl -fsSL https://bun.sh/install | bash' >/dev/null 2>&1
    [ -x "$DEPLOY_HOME/.bun/bin/bun" ] && ok "bun installed" || warn "bun install did not produce $DEPLOY_HOME/.bun/bin/bun"
  fi
else
  step "Skipping Bun install (INSTALL_BUN=$INSTALL_BUN)"
fi

# ---------------------------------------------------------------------------
# 8. common/ framework tree
# ---------------------------------------------------------------------------
step "Installing common/ framework"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_HOME/common" \
  "$DEPLOY_HOME/common/bin" "$DEPLOY_HOME/common/env"
for s in new-project deploy-app rollback-app build-app run-app backup-all free-port; do
  install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 755 \
    "$FILES/common/bin/$s.sh" "$DEPLOY_HOME/common/bin/$s.sh"
done
install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 644 "$FILES/common/README.md" "$DEPLOY_HOME/common/README.md"
# PORTS and shared.env: install only if absent so a re-run never clobbers edits
[ -f "$DEPLOY_HOME/common/PORTS" ]          || install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 644 "$FILES/common/PORTS" "$DEPLOY_HOME/common/PORTS"
[ -f "$DEPLOY_HOME/common/env/shared.env" ] || install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 600 "$FILES/common/env/shared.env" "$DEPLOY_HOME/common/env/shared.env"
ok "common/ installed"

# ---------------------------------------------------------------------------
# 9. systemd template
# ---------------------------------------------------------------------------
step "Installing systemd template app@.service"
install -o root -g root -m 644 "$FILES/systemd/app@.service" /etc/systemd/system/app@.service
systemctl daemon-reload
ok "app@.service installed"

# ---------------------------------------------------------------------------
# 10. Caddy config
# ---------------------------------------------------------------------------
step "Configuring Caddy"
install -d -o root -g root -m 755 /etc/caddy /etc/caddy/sites
install -o root -g root -m 644 "$FILES/caddy/Caddyfile" /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddyfile failed validation"
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
ok "caddy configured, enabled and running"

# ---------------------------------------------------------------------------
# 11. sudoers (deploy may restart its own services only)
# ---------------------------------------------------------------------------
step "Installing sudoers drop-in"
install -o root -g root -m 440 "$FILES/sudoers/deploy-restart-app" /etc/sudoers.d/deploy-restart-app
visudo -cf /etc/sudoers.d/deploy-restart-app >/dev/null || die "sudoers drop-in failed validation"
ok "deploy may 'systemctl restart app@*' (NOPASSWD), nothing else"

# ---------------------------------------------------------------------------
# 12. nightly backup cron (deploy)
# ---------------------------------------------------------------------------
step "Installing nightly backup cron"
CRON_LINE='0 3 * * * /home/deploy/common/bin/backup-all.sh >/dev/null 2>&1'
{ sudo -u "$DEPLOY_USER" crontab -l 2>/dev/null | grep -vF 'common/bin/backup-all.sh' || true; echo "$CRON_LINE"; } \
  | sudo -u "$DEPLOY_USER" crontab -
ok "backup-all.sh scheduled nightly at 03:00"

# ---------------------------------------------------------------------------
# 13. firewall (UFW)
# ---------------------------------------------------------------------------
if [ "$ENABLE_FIREWALL" = "true" ]; then
  step "Configuring UFW firewall"
  ufw allow "$SSH_PORT/tcp"   >/dev/null
  ufw allow 80/tcp            >/dev/null
  ufw allow 443/tcp           >/dev/null
  ufw default deny incoming   >/dev/null
  ufw default allow outgoing  >/dev/null
  ufw --force enable          >/dev/null
  ok "ufw enabled (allow: $SSH_PORT, 80, 443; deny other inbound)"
else
  step "Skipping firewall (ENABLE_FIREWALL=$ENABLE_FIREWALL)"
fi

# ---------------------------------------------------------------------------
# 14. fail2ban
# ---------------------------------------------------------------------------
if [ "$ENABLE_FAIL2BAN" = "true" ]; then
  step "Enabling fail2ban (sshd jail)"
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port    = $SSH_PORT
backend = systemd
maxretry = 5
bantime  = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  ok "fail2ban active on port $SSH_PORT"
else
  step "Skipping fail2ban (ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN)"
fi

# ---------------------------------------------------------------------------
# 15. unattended-upgrades
# ---------------------------------------------------------------------------
if [ "$ENABLE_UNATTENDED_UPGRADES" = "true" ]; then
  step "Enabling unattended security upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [ -n "$ADMIN_EMAIL" ]; then
    sed -i "s|^//\?Unattended-Upgrade::Mail .*|Unattended-Upgrade::Mail \"$ADMIN_EMAIL\";|" \
      /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
  fi
  systemctl enable unattended-upgrades >/dev/null 2>&1 || true
  ok "unattended-upgrades enabled"
else
  step "Skipping unattended-upgrades (ENABLE_UNATTENDED_UPGRADES=$ENABLE_UNATTENDED_UPGRADES)"
fi

# ---------------------------------------------------------------------------
# 16. SSH hardening (LAST — after the key is proven installed)
# ---------------------------------------------------------------------------
if [ "$HARDEN_SSH" = "true" ]; then
  step "Hardening SSH (key-only)"
  # lockout guard: refuse unless an authorized key exists
  [ -s /root/.ssh/authorized_keys ] || die "refusing to harden: /root/.ssh/authorized_keys is empty"

  # Named 00- so it is read BEFORE 50-cloud-init.conf. sshd uses the FIRST value
  # seen per keyword, and cloud-init's drop-in re-enables PasswordAuthentication;
  # a higher number (e.g. 99-) would be IGNORED. This ordering is the whole trick.
  HARDEN_FILE=/etc/ssh/sshd_config.d/00-hardening.conf
  {
    echo "# Managed by vps_projects_boilerplate/bootstrap.sh"
    echo "PasswordAuthentication no"
    echo "PermitRootLogin prohibit-password"
    echo "KbdInteractiveAuthentication no"
    echo "PubkeyAuthentication yes"
    [ "$SSH_PORT" != "22" ] && echo "Port $SSH_PORT"
  } > "$HARDEN_FILE"
  chmod 644 "$HARDEN_FILE"; chown root:root "$HARDEN_FILE"

  sshd -t || die "sshd config invalid — NOT reloading (your current session is safe)"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  ok "ssh hardened; effective values:"
  sshd -T | grep -iE '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication|port) ' | sed 's/^/     /'
  warn "Password login is now OFF. Keep an open session until you confirm key login works in a NEW terminal."
else
  step "Skipping SSH hardening (HARDEN_SSH=$HARDEN_SSH)"
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
PUBIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

${c_grn}====================================================================${c_off}
${c_grn} VPS ready.${c_off}  Multi-project, any-language, push-to-deploy host.
${c_grn}====================================================================${c_off}

 deploy user : $DEPLOY_USER  (apps run here, never root)
 projects in : $DEPLOY_HOME/projects/
 framework   : $DEPLOY_HOME/common/   (see its README.md)
 public IP   : ${PUBIP:-<unknown>}

 Add your first project (as root):
   sudo $DEPLOY_HOME/common/bin/new-project.sh <name> <domain> [port]

 Then from your dev machine (repo must contain an executable ./run):
   git remote add prod $DEPLOY_USER@${PUBIP:-<ip>}:$DEPLOY_HOME/projects/<name>/repo.git
   git push prod main

 Point the project's DNS A record at ${PUBIP:-this box} and Caddy issues HTTPS.

 Verify the install:   sudo ./verify.sh
 Full docs:            docs/ARCHITECTURE.md, docs/ADDING_A_PROJECT.md
EOF
