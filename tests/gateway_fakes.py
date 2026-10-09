"""A fake mlx-lm backend and helpers to run it and the gateway in background threads."""

from __future__ import annotations

import asyncio
import json
import socket
import threading
import time
from collections.abc import AsyncIterator, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any

import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from agent_lab.gateway import translate
from agent_lab.gateway.app import Gateway, GatewaySettings, create_app
from agent_lab.gateway.keys import KeyStore
from agent_lab.gateway.server import uvicorn_config

MODEL = "test-model"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
        return port


@dataclass
class FakeBackend:
    """Answers like mlx_lm.server 0.32.0 when asked to stream (the gateway always asks)."""

    prefill_seconds: float = 0.0  # before the first chunk; sends ": keepalive" meanwhile
    chunk_seconds: float = 0.0  # between chunks
    pieces: list[str] = field(default_factory=lambda: ["Hello", " there", "."])
    reasoning: list[str] = field(default_factory=list)
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    finish_reason: str = "stop"
    status: int = 200
    healthy: bool = True
    requests: list[dict[str, Any]] = field(default_factory=list)
    started: int = 0
    finished: int = 0
    cancelled: int = 0
    stats: list[dict[str, Any]] = field(default_factory=list)  # like /agent-lab/requests

    def chunk(self, delta: dict[str, Any], finish: str | None = None) -> bytes:
        body = {
            "id": "chatcmpl-1",
            "system_fingerprint": "0.32.0-0.32.3-macOS-15-arm64-applegpu_g17",
            "object": "chat.completion.chunk",
            "model": "default_model",
            "created": 1700000000,
            "choices": [{"index": 0, "finish_reason": finish, "delta": delta}],
        }
        return f"data: {json.dumps(body)}\n\n".encode()

    async def events(self, prompt_tokens: int) -> AsyncIterator[bytes]:
        self.started += 1
        try:
            waited = 0.0
            while waited < self.prefill_seconds:
                await asyncio.sleep(0.05)
                waited += 0.05
                yield b": keepalive 1/2\n\n"
            for text in self.reasoning:
                yield self.chunk({"role": "assistant", "reasoning": text})
            for text in self.pieces:
                if self.chunk_seconds:
                    await asyncio.sleep(self.chunk_seconds)
                yield self.chunk({"role": "assistant", "content": text})
            for i, call in enumerate(self.tool_calls):
                entry = {"function": call, "type": "function", "id": f"call-{i}", "index": i}
                yield self.chunk({"role": "assistant", "tool_calls": [entry]})
            yield self.chunk({"role": "assistant"}, self.finish_reason)
            usage = {
                "id": "chatcmpl-1",
                "object": "chat.completion",
                "model": "default_model",
                "created": 1700000000,
                "choices": [],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": len(self.pieces),
                    "total_tokens": prompt_tokens + len(self.pieces),
                    "prompt_tokens_details": {"cached_tokens": 0},
                },
            }
            self.stats.append(
                {
                    "id": len(self.stats) + 1,
                    "prompt_tokens": prompt_tokens,
                    "cached_tokens": 0,
                    "generated_tokens": len(self.pieces),
                    "first_token_seconds": 0.01,
                    "total_seconds": 0.01 + 0.01 * len(self.pieces),
                    "metal_active_before_bytes": 1024**3,
                    "metal_peak_bytes": 2 * 1024**3,
                    "metal_active_after_bytes": 1024**3,
                    "metal_cache_after_bytes": 0,
                    "prompt_cache_before_bytes": 0,
                    "prompt_cache_before_entries": 0,
                }
            )
            yield f"data: {json.dumps(usage)}\n\n".encode()
            yield b"data: [DONE]\n\n"
            self.finished += 1
        except BaseException:
            self.cancelled += 1
            raise

    async def chat(self, request: Request) -> Response:
        body = await request.json()
        self.requests.append(body)
        if self.status != 200:
            return Response(b'{"error": "boom"}', status_code=self.status)
        tokens = WordCounter().count(body["messages"], body.get("tools"), {})
        return StreamingResponse(self.events(tokens), media_type="text/event-stream")

    async def request_stats(self, request: Request) -> Response:
        return JSONResponse({"requests": self.stats})

    async def health(self, request: Request) -> Response:
        return JSONResponse({"status": "ok"}, status_code=200 if self.healthy else 503)

    def app(self) -> Starlette:
        return Starlette(
            routes=[
                Route("/v1/chat/completions", self.chat, methods=["POST"]),
                Route("/health", self.health, methods=["GET"]),
                Route("/agent-lab/requests", self.request_stats, methods=["GET"]),
            ]
        )


class WordCounter:
    """Stands in for the tokenizer: one token per word, ten per tool."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def count(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None,
        template_args: dict[str, Any],
    ) -> int:
        self.calls.append({"tools": tools, "template_args": template_args})
        words = sum(len(str(m.get("content") or "").split()) for m in messages)
        return words + 10 * len(tools or [])


def rules(
    max_context: int = 1000, effort_variable: str | None = "reasoning_effort"
) -> translate.Rules:
    return translate.Rules(
        model_name=MODEL,
        limits=translate.Limits(
            max_context=max_context, max_output_tokens=200, min_output_tokens=50
        ),
        default_thinking=False,
        sampling=translate.Sampling(0.7, 0.8, 20),
        thinking_sampling=translate.Sampling(0.6, 0.95, 20),
        effort_variable=effort_variable,
    )


@contextmanager
def serving(app: Any, port: int) -> Iterator[None]:
    server = uvicorn.Server(uvicorn_config(app, port))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        if time.monotonic() > deadline:
            raise RuntimeError("server did not start")
        time.sleep(0.02)
    try:
        yield
    finally:
        server.should_exit = True
        thread.join(10)


@dataclass
class Running:
    gateway: Gateway
    backend: FakeBackend
    counter: WordCounter
    url: str
    backend_url: str


@contextmanager
def running_gateway(
    backend: FakeBackend,
    *,
    queue_size: int = 4,
    heartbeat_seconds: float = 15,
    max_context: int = 1000,
    backend_running: bool = True,
) -> Iterator[Running]:
    backend_port = free_port()
    gateway_port = free_port()
    settings = GatewaySettings(
        rules=rules(max_context),
        backend_url=f"http://127.0.0.1:{backend_port}",
        queue_size=queue_size,
        heartbeat_seconds=heartbeat_seconds,
    )
    counter = WordCounter()
    gateway = Gateway(settings, KeyStore(), counter)
    with serving(create_app(gateway), gateway_port):
        info = Running(
            gateway,
            backend,
            counter,
            f"http://127.0.0.1:{gateway_port}",
            f"http://127.0.0.1:{backend_port}",
        )
        if backend_running:
            with serving(backend.app(), backend_port):
                yield info
        else:
            yield info
