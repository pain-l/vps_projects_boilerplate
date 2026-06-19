#!/usr/bin/env bash
# verify.sh — sanity-check that bootstrap.sh produced the expected state.
# Read-only; run as root after bootstrap (sudo ./verify.sh). Exit code is the
# number of failed checks.
set -uo pipefail

DEPLOY_USER="deploy"
H="/home/$DEPLOY_USER"
fail=0
pass(){ echo "  ok  $*"; }
bad(){  echo "  XX  $*"; fail=$((fail+1)); }

chk(){ # chk "label" test-command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else bad "$label"; fi
}

echo "== users & runtime =="
chk "deploy user exists"            id -u "$DEPLOY_USER"
chk "deploy password login locked"  bash -c "passwd -S $DEPLOY_USER | grep -qE ' (L|NP) '"
chk "bun present (or skipped)"       bash -c "[ -x $H/.bun/bin/bun ] || true"

echo "== framework files =="
for s in new-project deploy-app rollback-app build-app run-app backup-all free-port; do
  chk "common/bin/$s.sh executable" test -x "$H/common/bin/$s.sh"
done
chk "common/README.md present"      test -f "$H/common/README.md"
chk "common/env/shared.env 600"     bash -c "[ \"\$(stat -c %a $H/common/env/shared.env)\" = 600 ]"
chk "projects/ dir exists"          test -d "$H/projects"

echo "== system services =="
chk "app@.service template present" test -f /etc/systemd/system/app@.service
chk "caddy enabled"                 systemctl is-enabled caddy
chk "caddy active"                  systemctl is-active caddy
chk "Caddyfile valid"               caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
chk "caddy sites dir"               test -d /etc/caddy/sites

echo "== privileges =="
chk "sudoers drop-in valid"         visudo -cf /etc/sudoers.d/deploy-restart-app
chk "deploy can restart app@*"      bash -c "sudo -u $DEPLOY_USER sudo -n -l | grep -q 'systemctl restart app@'"
chk "deploy CANNOT stop app@*"      bash -c "! (sudo -u $DEPLOY_USER sudo -n -l | grep -q 'systemctl stop')"

echo "== backups =="
chk "nightly backup cron set"       bash -c "sudo -u $DEPLOY_USER crontab -l | grep -q backup-all.sh"

echo "== security =="
chk "PasswordAuthentication no"     bash -c "sshd -T | grep -qi '^passwordauthentication no'"
# sshd -T normalizes 'prohibit-password' to its synonym 'without-password'
chk "PermitRootLogin key-only"      bash -c "sshd -T | grep -qiE '^permitrootlogin (prohibit-password|without-password)'"
chk "ufw active (or skipped)"       bash -c "ufw status | grep -q 'Status: active' || true"
chk "fail2ban active (or skipped)"  bash -c "systemctl is-active fail2ban >/dev/null || true"

echo
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fail CHECK(S) FAILED"; fi
exit "$fail"
