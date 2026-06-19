# hello-python — example project

Smallest possible Python app (standard library only) that follows the deploy
contract — proof the host runs any language, not just Bun. The hit counter is a
plain text file in `$DATA_DIR`, and a custom `backup` script snapshots it nightly.

## Deploy it
```
# on the server (root):
sudo /home/deploy/common/bin/new-project.sh hello-python py.example.com

# on your dev machine, in a copy of this folder:
git init && git add -A && git commit -m "hello-python"
git update-index --chmod=+x run build backup   # commit the exec bit (see note)
git remote add prod deploy@<server-ip>:/home/deploy/projects/hello-python/repo.git
git push prod main
```

## ⚠️ Executable bit
`run`, `build` and `backup` must be committed **executable** (the server checks
out with `git archive`, which preserves committed mode bits). On Linux: `chmod
+x run build backup` before committing. On Windows: `git update-index --chmod=+x
run build backup`.
