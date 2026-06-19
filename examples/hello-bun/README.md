# hello-bun — example project

Smallest possible Bun app that follows the deploy contract. The `hits` counter
lives in `$DATA_DIR/app.db`, so it survives deploys and is picked up by the
nightly sqlite backup fallback automatically (no `backup` script needed).

## Deploy it
On the server (as root), scaffold the slot:
```
sudo /home/deploy/common/bin/new-project.sh hello-bun hello.example.com
```
On your dev machine, in a copy of this folder:
```
git init && git add -A && git commit -m "hello-bun"
# ensure the entrypoints are executable IN GIT (critical — see note below)
git update-index --chmod=+x run build
git remote add prod deploy@<server-ip>:/home/deploy/projects/hello-bun/repo.git
git push prod main
```
Point `hello.example.com`'s DNS A record at the box; Caddy gets HTTPS on first
request. Test: `curl https://hello.example.com/` increments the counter.

## ⚠️ Executable bit
`run` (and `build`/`backup` if present) must be committed **executable**. The
server checks out your code with `git archive`, which preserves the git mode
bits — but only if you set them. On Linux `chmod +x run build` before committing
is enough; on Windows use `git update-index --chmod=+x run build`.
