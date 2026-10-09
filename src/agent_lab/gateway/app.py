"""The gateway's ASGI app (design sections 6.3 and 7.3).

Endpoints: ``POST /v1/chat/completions``, ``GET /v1/models``, ``GET /healthz``;
everything else is 404. Every ``/v1`` request needs a valid API key, including
requests from 127.0.0.1 (cloudflared connects from this machine too).

A chat request is checked and counted before it waits for the backend, so a
request that would not fit never reaches it. The backend is always asked to
stream, also for clients that did not ask to: that way, when a client goes away
the gateway closes the backend connection and mlx-lm stops generating at its
next write, and the queue moves on.

Streaming responses start at once (headers, then ``: keep-alive`` comments
every ``heartbeat_seconds`` while nothing else is sent), so Cloudflare's
100-second idle limit never cuts a request that is queued or prefilling.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Route
from starlette.types import Receive, Scope, Send

from agent_lab.gateway import translate
from agent_lab.gateway.keys import KeyStore
from agent_lab.gateway.queue import QueueFull, RequestQueue
from agent_lab.gateway.tokens import PromptCounter
from agent_lab.gateway.translate import ApiError

log = logging.getLogger("agent_lab.gateway")
request_log = logging.getLogger("agent_lab.gateway.requests")

MAX_BODY_BYTES = 16 * 1024 * 1024  # a full 32K-token prompt with tools is well under 1MB
HEALTH_TIMEOUT = 2.0
CONNECT_TIMEOUT = 5.0
KEEP_ALIVE = b": keep-alive\n\n"
CLIENT_CLOSED = 499  # nginx's code for "the client went away", used in the log only
SSE_HEADERS = {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "X-Accel-Buffering": "no",
}


@dataclass(frozen=True)
class GatewaySettings:
    rules: translate.Rules
    backend_url: str  # http://127.0.0.1:8100
    queue_size: int
    heartbeat_seconds: float


@dataclass
class RequestRecord:
    """What the request log line says; never any part of the bodies."""

    key: str = "-"
    status: int = 0
    stream: bool | None = None
    effort: str = "-"
    prompt_tokens: int | None = None
    max_tokens: int | None = None
    backend_prompt_tokens: int | None = None
    cached_tokens: int | None = None
    completion_tokens: int | None = None
    finish_reason: str | None = None
    queue_seconds: float | None = None
    started: float = field(default_factory=time.monotonic)

    def write(self) -> None:
        def fmt(value: Any) -> str:
            if value is None:
                return "-"
            if isinstance(value, bool):
                return "true" if value else "false"
            if isinstance(value, float):
                return f"{value:.2f}"
            return str(value)

        fields = {
            "key": self.key,
            "status": self.status,
            "stream": self.stream,
            "effort": self.effort,
            "prompt_tokens": self.prompt_tokens,
            "backend_prompt_tokens": self.backend_prompt_tokens,
            "cached_tokens": self.cached_tokens,
            "completion_tokens": self.completion_tokens,
            "max_tokens": self.max_tokens,
            "finish": self.finish_reason,
            "queue_s": self.queue_seconds,
            "duration_s": time.monotonic() - self.started,
        }
        request_log.info(" ".join(f"{k}={fmt(v)}" for k, v in fields.items()))
        if (
            self.prompt_tokens is not None
            and self.backend_prompt_tokens is not None
            and self.prompt_tokens != self.backend_prompt_tokens
        ):
            log.warning(
                "prompt token count mismatch: gateway %d, backend %d",
                self.prompt_tokens,
                self.backend_prompt_tokens,
            )


class BackendError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message

    def api_error(self) -> ApiError:
        kind = "server_error" if self.status >= 500 else "invalid_request_error"
        return ApiError(self.status, self.message, code=None, type_=kind)


def error_response(error: ApiError, headers: dict[str, str] | None = None) -> JSONResponse:
    return JSONResponse(error.body(), status_code=error.status, headers=headers)


def _sse(data: dict[str, Any]) -> bytes:
    return f"data: {json.dumps(data, ensure_ascii=False)}\n\n".encode()


class Gateway:
    def __init__(
        self,
        settings: GatewaySettings,
        keys: KeyStore,
        counter: PromptCounter,
        on_queue_change: Callable[[int, int], None] | None = None,
    ) -> None:
        self.settings = settings
        self.rules = settings.rules
        self.keys = keys
        self.counter = counter
        self.queue = RequestQueue(settings.queue_size, on_queue_change)
        self.created = int(time.time())
        # trust_env=False: never send local requests through http_proxy and friends.
        self.client = httpx.AsyncClient(
            base_url=settings.backend_url,
            trust_env=False,
            timeout=httpx.Timeout(None, connect=CONNECT_TIMEOUT),
        )

    # -- helpers ------------------------------------------------------------

    def authenticate(self, request: Request) -> str:
        header = request.headers.get("authorization", "")
        scheme, _, key = header.partition(" ")
        name = self.keys.check(key.strip()) if scheme.lower() == "bearer" and key else None
        if name is None:
            raise ApiError(
                401,
                "Incorrect or missing API key. Send it as `Authorization: Bearer <key>`.",
                code="invalid_api_key",
            )
        return name

    async def read_json(self, request: Request) -> Any:
        length = request.headers.get("content-length")
        if length is not None and length.isdigit() and int(length) > MAX_BODY_BYTES:
            raise ApiError(413, "the request body is too large")
        chunks = []
        size = 0
        async for chunk in request.stream():
            size += len(chunk)
            if size > MAX_BODY_BYTES:
                raise ApiError(413, "the request body is too large")
            chunks.append(chunk)
        try:
            return json.loads(b"".join(chunks))
        except ValueError:
            raise ApiError(400, "the request body is not valid JSON") from None

    def model_entry(self) -> dict[str, Any]:
        return {
            "id": self.rules.model_name,
            "object": "model",
            "created": self.created,
            "owned_by": "agent-lab",
        }

    def public_chunk(self, chunk: dict[str, Any]) -> dict[str, Any]:
        """The backend's chunk as clients see it: our model name, no server details."""
        chunk["model"] = self.rules.model_name
        chunk.pop("system_fingerprint", None)
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta")
            # mlx-lm calls it "reasoning"; many clients read "reasoning_content".
            if isinstance(delta, dict) and "reasoning" in delta:
                delta["reasoning_content"] = delta["reasoning"]
        return chunk

    async def backend_chunks(
        self, body: dict[str, Any], record: RequestRecord
    ) -> AsyncIterator[dict[str, Any]]:
        """Wait for the backend, then yield its stream's JSON chunks (usage included)."""
        queued = time.monotonic()
        async with self.queue.slot():
            record.queue_seconds = time.monotonic() - queued
            try:
                async with self.client.stream("POST", "/v1/chat/completions", json=body) as resp:
                    if resp.status_code != 200:
                        # Its message can name local paths; it goes to the log, not the client.
                        text = (await resp.aread())[:500].decode("utf-8", "replace")
                        log.error("the backend answered %d: %s", resp.status_code, text)
                        status = 502 if resp.status_code >= 500 else 400
                        raise BackendError(
                            status,
                            f"the model server rejected the request (HTTP {resp.status_code})",
                        )
                    async for line in resp.aiter_lines():
                        if not line.startswith("data:"):
                            continue  # blank lines and mlx-lm's own keepalive comments
                        data = line[5:].strip()
                        if data == "[DONE]":
                            return
                        chunk = json.loads(data)
                        if not isinstance(chunk, dict):
                            raise BackendError(502, "the model server sent an invalid chunk")
                        if chunk.get("usage"):
                            usage = chunk["usage"]
                            record.backend_prompt_tokens = usage.get("prompt_tokens")
                            record.completion_tokens = usage.get("completion_tokens")
                            details = usage.get("prompt_tokens_details") or {}
                            record.cached_tokens = details.get("cached_tokens")
                        for choice in chunk.get("choices") or []:
                            if choice.get("finish_reason"):
                                record.finish_reason = choice["finish_reason"]
                        yield chunk
            except httpx.ConnectError:
                raise BackendError(503, "the model server is not running") from None
            except (httpx.HTTPError, ValueError) as exc:
                log.error("the backend connection failed: %s: %s", type(exc).__name__, exc)
                raise BackendError(502, "the model server failed while answering") from None
        raise BackendError(502, "the model server ended the response early")

    # -- endpoints ----------------------------------------------------------

    async def healthz(self, request: Request) -> Response:
        try:
            resp = await self.client.get("/health", timeout=HEALTH_TIMEOUT)
            ok = resp.status_code == 200
        except httpx.HTTPError:
            ok = False
        return PlainTextResponse("ok" if ok else "unavailable", status_code=200 if ok else 503)

    async def models(self, request: Request) -> Response:
        record = RequestRecord()
        try:
            record.key = self.authenticate(request)
            model = request.path_params.get("model")
            if model is not None and model != self.rules.model_name:
                raise ApiError(404, f"The model `{model}` does not exist.", "model_not_found")
            body = self.model_entry() if model else {"object": "list", "data": [self.model_entry()]}
            record.status = 200
            return JSONResponse(body)
        except ApiError as exc:
            record.status = exc.status
            return error_response(exc)
        finally:
            record.write()

    async def chat(self, request: Request) -> Response:
        record = RequestRecord()
        try:
            record.key = self.authenticate(request)
            prepared = translate.prepare(await self.read_json(request), self.rules)
            record.stream = prepared.stream
            record.effort = prepared.effort
            try:
                record.prompt_tokens = await asyncio.to_thread(
                    self.counter.count, prepared.messages, prepared.tools, prepared.template_args
                )
            except Exception as exc:  # the chat template refused the messages
                raise ApiError(400, f"cannot apply the chat template: {exc}") from None
            record.max_tokens = translate.limit(
                record.prompt_tokens, prepared.requested_max_tokens, self.rules.limits
            )
            prepared.body["max_tokens"] = record.max_tokens
            if self.queue.full():
                raise ApiError(
                    429,
                    "The server is busy with other requests; try again in a minute.",
                    code="rate_limit_exceeded",
                    type_="rate_limit_error",
                )
        except ApiError as exc:
            record.status = exc.status
            record.write()
            headers = {"WWW-Authenticate": "Bearer"} if exc.status == 401 else None
            if exc.status == 429:
                headers = {"Retry-After": "30"}
            return error_response(exc, headers)
        if prepared.stream:
            return ChatResponse(self, prepared, record, self._stream)
        return ChatResponse(self, prepared, record, self._complete)

    # -- the two ways of answering ---------------------------------------

    async def _stream(
        self, prepared: translate.Prepared, record: RequestRecord, send: Send
    ) -> None:
        await send(
            {
                "type": "http.response.start",
                "status": 200,
                "headers": [(k.lower().encode(), v.encode()) for k, v in SSE_HEADERS.items()],
            }
        )
        record.status = 200

        async def body(data: bytes) -> None:
            await send({"type": "http.response.body", "body": data, "more_body": True})

        chunks = self.backend_chunks(prepared.body, record)
        try:
            async for chunk in _with_heartbeats(chunks, self.settings.heartbeat_seconds, body):
                usage_only = not chunk.get("choices") and chunk.get("usage")
                if usage_only and not prepared.include_usage:
                    continue
                await body(_sse(self.public_chunk(chunk)))
            await body(b"data: [DONE]\n\n")
        except (BackendError, QueueFull) as exc:
            error = exc.api_error() if isinstance(exc, BackendError) else _busy()
            record.status = error.status
            await body(_sse(error.body()))
        await send({"type": "http.response.body", "body": b"", "more_body": False})

    async def _complete(
        self, prepared: translate.Prepared, record: RequestRecord, send: Send
    ) -> None:
        try:
            result = await self._collect(prepared, record)
            response: Response = JSONResponse(result)
            record.status = 200
        except (BackendError, QueueFull) as exc:
            error = exc.api_error() if isinstance(exc, BackendError) else _busy()
            record.status = error.status
            response = error_response(error)
        await send(
            {
                "type": "http.response.start",
                "status": response.status_code,
                "headers": response.raw_headers,
            }
        )
        await send({"type": "http.response.body", "body": response.body})

    async def _collect(self, prepared: translate.Prepared, record: RequestRecord) -> dict[str, Any]:
        """A non-streaming response, assembled from the backend's stream."""
        first: dict[str, Any] | None = None
        content: list[str] = []
        reasoning: list[str] = []
        tool_calls: list[dict[str, Any]] = []
        finish_reason = None
        usage = None
        async for chunk in self.backend_chunks(prepared.body, record):
            first = first or chunk
            if chunk.get("usage"):
                usage = chunk["usage"]
            for choice in chunk.get("choices") or []:
                delta = choice.get("delta") or {}
                if delta.get("content"):
                    content.append(delta["content"])
                if delta.get("reasoning"):
                    reasoning.append(delta["reasoning"])
                for call in delta.get("tool_calls") or []:
                    call = dict(call)
                    call.pop("index", None)
                    tool_calls.append(call)
                finish_reason = choice.get("finish_reason") or finish_reason
        if first is None:
            raise BackendError(502, "the model server sent no answer")
        message: dict[str, Any] = {"role": "assistant", "content": "".join(content) or None}
        if reasoning:
            message["reasoning"] = message["reasoning_content"] = "".join(reasoning)
        if tool_calls:
            message["tool_calls"] = tool_calls
        result = {
            "id": first.get("id"),
            "object": "chat.completion",
            "created": first.get("created"),
            "model": self.rules.model_name,
            "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        }
        if usage:
            result["usage"] = usage
        return result

    async def aclose(self) -> None:
        await self.client.aclose()


def _busy() -> ApiError:
    return ApiError(429, "The server is busy; try again in a minute.", type_="rate_limit_error")


async def _with_heartbeats(
    chunks: AsyncIterator[dict[str, Any]],
    interval: float,
    send: Callable[[bytes], Awaitable[None]],
) -> AsyncIterator[dict[str, Any]]:
    """Yield from ``chunks``; whenever nothing arrives for ``interval`` seconds, send a comment.

    ``chunks`` runs in a task of its own (so that an httpx stream is opened and
    closed in the same task); leaving this generator cancels that task.
    """
    queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue(maxsize=64)

    async def produce() -> None:
        try:
            async for chunk in chunks:
                await queue.put(("chunk", chunk))
            await queue.put(("end", None))
        except Exception as exc:
            await queue.put(("error", exc))

    producer = asyncio.ensure_future(produce())
    try:
        while True:
            try:
                kind, value = await asyncio.wait_for(queue.get(), interval)
            except TimeoutError:
                await send(KEEP_ALIVE)
                continue
            if kind == "end":
                return
            if kind == "error":
                raise value
            yield value
    finally:
        producer.cancel()
        with contextlib.suppress(BaseException):
            await producer


class ChatResponse(Response):
    """Runs an answer while watching for the client to leave; leaving cancels the answer."""

    def __init__(
        self,
        gateway: Gateway,
        prepared: translate.Prepared,
        record: RequestRecord,
        run: Callable[[translate.Prepared, RequestRecord, Send], Awaitable[None]],
    ) -> None:
        super().__init__()
        self.gateway = gateway
        self.prepared = prepared
        self.record = record
        self.run = run

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        answer = asyncio.ensure_future(self.run(self.prepared, self.record, send))
        watcher = asyncio.ensure_future(_wait_disconnect(receive))
        try:
            done, _ = await asyncio.wait({answer, watcher}, return_when=asyncio.FIRST_COMPLETED)
            if answer not in done:
                self.record.status = CLIENT_CLOSED
            answer.cancel()
            watcher.cancel()
            results = await asyncio.gather(answer, watcher, return_exceptions=True)
            error = results[0]
            if isinstance(error, Exception):
                log.error("request failed", exc_info=error)
                self.record.status = 500
        finally:
            # Also when this response itself is cancelled (the server shutting down).
            for task in (answer, watcher):
                task.cancel()
            self.record.write()


async def _wait_disconnect(receive: Receive) -> None:
    while True:
        message = await receive()
        if message["type"] == "http.disconnect":
            return


async def _not_found(request: Request, exc: Exception) -> Response:
    error = ApiError(404, f"no route for {request.method} {request.url.path}", type_="not_found")
    return error_response(error)


def create_app(gateway: Gateway) -> Starlette:
    @contextlib.asynccontextmanager
    async def lifespan(app: Starlette) -> AsyncIterator[None]:
        yield
        await gateway.aclose()

    routes = [
        Route("/v1/chat/completions", gateway.chat, methods=["POST"]),
        Route("/v1/models", gateway.models, methods=["GET"]),
        Route("/v1/models/{model:path}", gateway.models, methods=["GET"]),
        Route("/healthz", gateway.healthz, methods=["GET"]),
    ]
    return Starlette(routes=routes, lifespan=lifespan, exception_handlers={404: _not_found})
