#!/usr/bin/env python3
"""Deterministic OpenAI-compatible fixture for Aider edit-recovery tests."""

import argparse
import json
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from socketserver import ThreadingTCPServer


BAD_EDIT = """calculator.py
```python
<<<<<<< SEARCH
    return left * right
=======
    return left + right
>>>>>>> REPLACE
```"""

GOOD_EDIT = """calculator.py
```python
<<<<<<< SEARCH
    return left - right
=======
    return left + right
>>>>>>> REPLACE
```"""


class Handler(BaseHTTPRequestHandler):
    calls = 0

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        messages = request.get("messages", [])
        unavailable = any(
            "must fail locally" in str(message.get("content", ""))
            for message in messages
        )
        if unavailable:
            body = json.dumps(
                {
                    "error": {
                        "message": "model 'gemma4:12b' not found",
                        "type": "invalid_request_error",
                    }
                }
            ).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        type(self).calls += 1
        content = BAD_EDIT if type(self).calls == 1 else GOOD_EDIT
        body = json.dumps(
            {
                "id": f"fixture-{type(self).calls}",
                "object": "chat.completion",
                "created": 0,
                "model": "mock-model",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": content},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 10,
                    "total_tokens": 20,
                },
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", type=Path, required=True)
    args = parser.parse_args()
    # ThreadingHTTPServer performs a reverse-DNS lookup during construction on
    # macOS. The TCP variant avoids that network-dependent startup behavior.
    server = ThreadingTCPServer(("127.0.0.1", 0), Handler)
    args.port_file.write_text(str(server.server_address[1]), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
