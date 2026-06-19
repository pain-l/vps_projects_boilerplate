// Minimal Bun + bun:sqlite app demonstrating the project contract:
//   - binds $HOST:$PORT (injected by systemd from the project .env)
//   - persists state under $DATA_DIR (survives every deploy / release swap)
//   - exposes /health for the deploy health check
import { Database } from "bun:sqlite";

const PORT = Number(process.env.PORT ?? 3000);
const HOST = process.env.HOST ?? "127.0.0.1";
const DATA_DIR = process.env.DATA_DIR ?? ".";

const db = new Database(`${DATA_DIR}/app.db`);
db.run("CREATE TABLE IF NOT EXISTS hits (n INTEGER NOT NULL)");
if (!(db.query("SELECT count(*) AS c FROM hits").get() as any).c) {
  db.run("INSERT INTO hits (n) VALUES (0)");
}

Bun.serve({
  port: PORT,
  hostname: HOST,
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/health") return new Response("ok");
    db.run("UPDATE hits SET n = n + 1");
    const n = (db.query("SELECT n FROM hits").get() as any).n;
    return new Response(`hello from bun — hit #${n}\n`);
  },
});

console.log(`hello-bun listening on ${HOST}:${PORT}, data in ${DATA_DIR}`);
