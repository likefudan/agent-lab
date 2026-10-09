"""A stand-in for the gateway process in the process-management tests.

Usage: fake_gateway.py <port> <mode> agent_lab.gateway
The last argument only makes the command line look like the real gateway's.
Modes: ok (ready, /healthz answers 503 as with no backend), exit (fail at start).
"""

from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

port, mode = int(sys.argv[1]), sys.argv[2]
run = Path(os.environ["AGENT_LAB_HOME"]) / "var/run"
if mode == "exit":
    print("cannot load the tokenizer", file=sys.stderr, flush=True)
    sys.exit(1)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.send_response(503)
        self.end_headers()
        self.wfile.write(b"unavailable")

    def log_message(self, format: str, *args: object) -> None:
        pass


server = HTTPServer(("127.0.0.1", port), Handler)
time.sleep(0.2)
(run / "gateway.queue.json").write_text(json.dumps({"pid": os.getpid(), "active": 0, "waiting": 0}))
(run / "gateway.ready.json").write_text(json.dumps({"pid": os.getpid(), "model_name": "m"}))
server.serve_forever()
