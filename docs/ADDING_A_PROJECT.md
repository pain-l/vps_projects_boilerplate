# Adding a project

End-to-end: scaffold a slot on the server, wire up your repo, push, go live.

## 1. Scaffold the slot (on the server, as root)

```bash
sudo /home/deploy/common/bin/new-project.sh <name> <domain> [port]
# e.g.
sudo /home/deploy/common/bin/new-project.sh myapp myapp.example.com
```

This creates `/home/deploy/projects/myapp/` with `repo.git` (+ deploy hook),
`releases/`, `shared/`, `backups/`, and a starter `.env` (with `PORT`, `HOST`,
and a generated `APP_SECRET`). It also drops `/etc/caddy/sites/myapp.caddy`,
registers the port, and enables `app@myapp`. If you omit the port, the next free
one in 3330–3399 is chosen.

## 2. Point DNS

Create an **A record** for `<domain>` pointing at the server's public IP. Caddy
provisions a Let's Encrypt certificate automatically once the name resolves to
the box. (No DNS = no HTTPS; you can still test locally via the port.)

## 3. Prepare your repo

Your repo must satisfy [the contract](PROJECT_CONTRACT.md): at minimum an
executable `run`. Copy one of the `examples/` to start.

```bash
chmod +x run            # (and build / backup if you have them)
git add -A && git commit -m "init"
```

## 4. Add the remote and push

```bash
git remote add prod deploy@<server-ip>:/home/deploy/projects/myapp/repo.git
git push prod main
```

The push prints the deploy log: checkout → build → swap → restart →
health-check. If health passes you're live at `https://<domain>`. If it fails,
the deploy auto-rolls back to the previous release (or, on a first deploy,
reports the service is down — check `journalctl -u app@myapp`).

## 5. Set real secrets

Edit `/home/deploy/projects/myapp/.env` on the server for anything sensitive
(API keys, DB URLs). It's `chmod 600`, owned by deploy, and lives outside the
work tree so it's never in git. Restart to pick up changes:

```bash
sudo -u deploy sudo systemctl restart app@myapp
```

## Day-2 operations

| Task | Command |
|---|---|
| Status | `systemctl status app@myapp` |
| Logs (follow) | `journalctl -u app@myapp -f` |
| Restart | `sudo -u deploy sudo systemctl restart app@myapp` |
| Roll back one release | `sudo -u deploy /home/deploy/common/bin/rollback-app.sh myapp` |
| Manual backup now | `sudo -u deploy /home/deploy/common/bin/backup-all.sh` |
| List ports in use | `cat /home/deploy/common/PORTS` |
| Next free port | `sudo -u deploy /home/deploy/common/bin/free-port.sh` |

## Removing a project

```bash
sudo systemctl disable --now app@myapp
sudo rm /etc/caddy/sites/myapp.caddy && sudo systemctl reload caddy
sudo rm -rf /home/deploy/projects/myapp
sudo -u deploy sed -i '/^myapp\t/d' /home/deploy/common/PORTS
```

Back up `projects/myapp/shared/` first if you want to keep its data.

## Subsequent deploys

Just `git push prod main` again. Every push is a new atomic release with
automatic rollback; your data in `shared/` carries over untouched.
