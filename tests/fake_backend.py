"""A stand-in for the backend process in the process-management tests.

Usage: fake_backend.py <port> <mode> agent_lab.backend.launch
The last argument only makes the command line look like the real backend's.
Modes: ok (load, then serve /health), exit (fail while loading), hang (never
become ready), ignore-term (like ok, but ignore SIGTERM), unhealthy (ready,
but /health answers 503).
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

port, mode = int(sys.argv[1]), sys.argv[2]
ready = Path(os.environ["AGENT_LAB_HOME"]) / "var/run/backend.ready.json"
print(f"fake backend starting in mode {mode}", flush=True)

if mode == "exit":
    print("Model type qwen9 not supported.", file=sys.stderr, flush=True)
    sys.exit(3)
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.send_response(503 if mode == "unhealthy" else 200)
        self.end_headers()
        self.wfile.write(b'{"status": "ok"}')

    def log_message(self, format: str, *args: object) -> None:
        pass


server = HTTPServer(("127.0.0.1", port), Handler)
if mode == "hang":
    time.sleep(3600)
time.sleep(0.3)  # "loading"
ready.write_text(json.dumps({"pid": os.getpid(), "load_seconds": 0.3, "tool_parser": None}))
server.serve_forever()
