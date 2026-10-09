"""Requests through the gateway, the backend's own statistics, and memory samples.

Every request streams, like Cursor's and opencode's. The client side gives
what a user sees (time to the first output, total time); the backend's
``/agent-lab/requests`` (``backend.launch``) gives what happened inside:
prompt tokens served from the prompt cache, time to the first generated
token (prefill), generated tokens and the request's peak Metal memory.
"""

from __future__ import annotations

import contextlib
import json
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any

import httpx

from agent_lab import macos
from agent_lab.backend import launch, process

SAMPLE_INTERVAL = 0.5  # seconds between memory samples during a request
REQUEST_TIMEOUT = 3600.0  # a 32K prompt with no cache hit takes minutes on the 24GB Mac
STATS_TIMEOUT = 10.0


@dataclass
class MemorySamples:
    """System memory while a request ran (None where it cannot be read, e.g. on Linux)."""

    swap_start_bytes: int | None = None
    swap_max_bytes: int | None = None
    available_min_bytes: int | None = None
    backend_rss_max_bytes: int | None = None

    def add(self, swap: int | None, available: int | None, rss: int | None) -> None:
        if swap is not None:
            if self.swap_start_bytes is None:
                self.swap_start_bytes = swap
            self.swap_max_bytes = max(self.swap_max_bytes or 0, swap)
        if available is not None:
            low = self.available_min_bytes
            self.available_min_bytes = available if low is None else min(low, available)
        if rss is not None:
            self.backend_rss_max_bytes = max(self.backend_rss_max_bytes or 0, rss)


@contextlib.contextmanager
def sampling(backend_pid: int | None, interval: float = SAMPLE_INTERVAL) -> Iterator[MemorySamples]:
    """Sample swap, available memory and the backend's RSS until the block ends."""
    samples = MemorySamples()
    stop = threading.Event()

    def sample() -> None:
        stats = macos.memory_stats()
        rss = process.rss_bytes(backend_pid) if backend_pid else None
        samples.add(
            stats.swap_used_bytes if stats else None,
            stats.available_bytes if stats else None,
            rss,
        )

    def loop() -> None:
        while not stop.wait(interval):
            sample()

    sample()
    thread = threading.Thread(target=loop, name="memory-sampler", daemon=True)
    thread.start()
    try:
        yield samples
    finally:
        stop.set()
        thread.join()
        sample()


@dataclass
class ChatResult:
    status: int
    seconds: float  # until the stream ended
    first_output_seconds: float | None  # first content, reasoning or tool call (client side)
    text: str = ""
    reasoning: str = ""
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    finish_reason: str | None = None
    usage: dict[str, Any] | None = None
    output_times: list[float] = field(default_factory=list)  # each content/reasoning chunk
    backend: dict[str, Any] | None = None  # the backend's statistics for this request
    memory: MemorySamples = field(default_factory=MemorySamples)
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.status == 200 and self.error is None

    @property
    def prompt_tokens(self) -> int | None:
        value = (self.usage or {}).get("prompt_tokens")
        return value if isinstance(value, int) else None

    @property
    def completion_tokens(self) -> int | None:
        value = (self.usage or {}).get("completion_tokens")
        return value if isinstance(value, int) else None

    @property
    def cached_tokens(self) -> int | None:
        details = (self.usage or {}).get("prompt_tokens_details") or {}
        value = details.get("cached_tokens")
        return value if isinstance(value, int) else None

    def assistant_message(self) -> dict[str, Any]:
        """The answer as a client sends it back in the next request."""
        message: dict[str, Any] = {"role": "assistant", "content": self.text}
        if self.tool_calls:
            message["tool_calls"] = self.tool_calls
        return message


def _add_tool_call(calls: list[dict[str, Any]], delta: dict[str, Any]) -> None:
    index = delta.get("index", len(calls))
    while len(calls) <= index:
        calls.append({"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
    call = calls[index]
    if delta.get("id"):
        call["id"] = delta["id"]
    function = delta.get("function") or {}
    call["function"]["name"] += function.get("name") or ""
    call["function"]["arguments"] += function.get("arguments") or ""


class Client:
    """Talks to the gateway with an API key, and to the backend for its statistics."""

    def __init__(
        self,
        gateway_url: str,
        backend_url: str,
        api_key: str,
        model: str,
        backend_pid: int | None = None,
        timeout: float = REQUEST_TIMEOUT,
    ) -> None:
        self.model = model
        self.backend_pid = backend_pid
        # trust_env=False: never send local requests through a proxy from the environment.
        self._gateway = httpx.Client(
            base_url=gateway_url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=httpx.Timeout(timeout, connect=10.0),
            trust_env=False,
        )
        self._backend = httpx.Client(base_url=backend_url, timeout=STATS_TIMEOUT, trust_env=False)

    def close(self) -> None:
        self._gateway.close()
        self._backend.close()

    def backend_stats(self) -> dict[str, Any] | None:
        """The backend's ``/agent-lab/requests``, or None if it cannot be read."""
        try:
            response = self._backend.get(launch.REQUESTS_PATH)
            data = response.json() if response.status_code == 200 else None
        except httpx.HTTPError, ValueError:
            return None
        return data if isinstance(data, dict) else None

    def _last_backend_id(self) -> int:
        stats = self.backend_stats() or {}
        ids = [r.get("id", 0) for r in stats.get("requests", [])]
        return max(ids, default=0)

    def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        max_tokens: int | None = None,
    ) -> ChatResult:
        body: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "stream": True,
            "stream_options": {"include_usage": True},
        }
        if tools:
            body["tools"] = tools
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        before = self._last_backend_id()
        with sampling(self.backend_pid) as samples:
            result = self._stream(body)
        result.memory = samples
        if result.ok:
            result.backend = self._backend_entry(before, result.prompt_tokens)
        return result

    def _stream(self, body: dict[str, Any]) -> ChatResult:
        started = time.monotonic()
        result = ChatResult(status=0, seconds=0.0, first_output_seconds=None)
        try:
            with self._gateway.stream("POST", "/v1/chat/completions", json=body) as response:
                result.status = response.status_code
                if response.status_code != 200:
                    response.read()
                    result.error = _error_message(response)
                else:
                    for line in response.iter_lines():
                        if line.startswith("data: ") and line != "data: [DONE]":
                            self._event(result, json.loads(line[6:]), started)
        except (httpx.HTTPError, ValueError) as exc:
            result.error = f"{type(exc).__name__}: {exc}"
        result.seconds = time.monotonic() - started
        return result

    @staticmethod
    def _event(result: ChatResult, chunk: dict[str, Any], started: float) -> None:
        if "error" in chunk:
            error = chunk["error"]
            result.error = error.get("message", str(error)) if isinstance(error, dict) else error
            return
        if chunk.get("usage"):
            result.usage = chunk["usage"]
        for choice in chunk.get("choices") or []:
            delta = choice.get("delta") or {}
            content = delta.get("content") or ""
            reasoning = delta.get("reasoning_content") or delta.get("reasoning") or ""
            calls = delta.get("tool_calls") or []
            now = time.monotonic() - started
            if (content or reasoning or calls) and result.first_output_seconds is None:
                result.first_output_seconds = now
            if content or reasoning:
                result.output_times.append(now)
            result.text += content
            result.reasoning += reasoning
            for call in calls:
                _add_tool_call(result.tool_calls, call)
            if choice.get("finish_reason"):
                result.finish_reason = choice["finish_reason"]

    def _backend_entry(self, after_id: int, prompt_tokens: int | None) -> dict[str, Any] | None:
        """The backend's record of the request just answered (the newest after ``after_id``)."""
        stats = self.backend_stats() or {}
        newer = [r for r in stats.get("requests", []) if r.get("id", 0) > after_id]
        if not newer:
            return None
        entry: dict[str, Any] = newer[-1]
        if prompt_tokens is not None and entry.get("prompt_tokens") != prompt_tokens:
            return None  # not this request's record
        return entry


def _error_message(response: httpx.Response) -> str:
    try:
        error = response.json().get("error")
    except ValueError, AttributeError:
        return f"HTTP {response.status_code}"
    if isinstance(error, dict):
        return f"HTTP {response.status_code}: {error.get('message', error)}"
    return f"HTTP {response.status_code}: {error}"
