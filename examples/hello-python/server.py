#!/usr/bin/env python3
# Minimal stdlib Python app demonstrating the project contract:
#   - binds $HOST:$PORT (injected by systemd from the project .env)
#   - persists state under $DATA_DIR (survives every deploy)
#   - exposes /health for the deploy health check
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8000"))
DATA_DIR = os.environ.get("DATA_DIR", ".")
COUNTER = os.path.join(DATA_DIR, "hits.txt")


def bump():
    n = 0
    try:
        with open(COUNTER) as f:
            n = int(f.read() or 0)
    except FileNotFoundError:
        pass
    n += 1
    with open(COUNTER, "w") as f:
        f.write(str(n))
    return n


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        n = bump()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"hello from python — hit #{n}\n".encode())

    def log_message(self, *args):  # quiet
        pass


if __name__ == "__main__":
    print(f"hello-python listening on {HOST}:{PORT}, data in {DATA_DIR}")
    HTTPServer((HOST, PORT), Handler).serve_forever()
