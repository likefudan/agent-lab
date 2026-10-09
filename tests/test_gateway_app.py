"""The gateway against a fake backend, over real HTTP (both run in background threads)."""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx
import pytest

from agent_lab.gateway import keys
from tests.gateway_fakes import MODEL, FakeBackend, Running, running_gateway

HELLO = [{"role": "user", "content": "Say hello"}]


@pytest.fixture
def key(lab_home: Path) -> str:
    return keys.create("test")


def client(run: Running, key: str | None, timeout: float = 10) -> httpx.Client:
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    return httpx.Client(base_url=run.url, headers=headers, timeout=timeout, trust_env=False)


def chat(run: Running, key: str, **body: Any) -> httpx.Response:
    with client(run, key) as c:
        return c.post("/v1/chat/completions", json={"model": MODEL, "messages": HELLO, **body})


def events(text: str) -> list[Any]:
    """The data events of an SSE body, decoded; "[DONE]" stays a string."""
    result: list[Any] = []
    for line in text.splitlines():
        if line.startswith("data: "):
            data = line[6:]
            result.append(data if data == "[DONE]" else json.loads(data))
    return result


def wait_for(condition: Any, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("condition not reached")
        time.sleep(0.02)


@pytest.fixture
def backend() -> FakeBackend:
    return FakeBackend()


@pytest.fixture
def run(lab_home: Path, backend: FakeBackend) -> Iterator[Running]:
    with running_gateway(backend) as running:
        yield running


# -- authentication ---------------------------------------------------------


def test_requests_need_a_valid_key(run: Running, key: str) -> None:
    for header in (None, "Bearer wrong", f"Basic {key}", "Bearer", key, f"Bearer {key}x"):
        headers = {"Authorization": header} if header is not None else {}
        with httpx.Client(base_url=run.url, trust_env=False) as c:
            response = c.post("/v1/chat/completions", json={"messages": HELLO}, headers=headers)
            assert response.status_code == 401, header
            assert response.json()["error"]["code"] == "invalid_api_key"
            assert response.headers["www-authenticate"] == "Bearer"
            assert c.get("/v1/models", headers=headers).status_code == 401
    assert run.backend.requests == []  # 127.0.0.1 gets no exemption either


def test_revoked_and_new_keys_apply_without_restart(run: Running, key: str) -> None:
    assert chat(run, key).status_code == 200
    second = keys.create("second")
    assert chat(run, second).status_code == 200
    keys.revoke("test")
    assert chat(run, key).status_code == 401
    assert chat(run, second).status_code == 200


# -- endpoints ----------------------------------------------------------------


def test_models(run: Running, key: str) -> None:
    with client(run, key) as c:
        listing = c.get("/v1/models").json()
        assert [m["id"] for m in listing["data"]] == [MODEL]
        assert c.get(f"/v1/models/{MODEL}").json()["id"] == MODEL
        assert c.get("/v1/models/gpt-4o").status_code == 404


def test_healthz_says_only_ok_or_unavailable(run: Running) -> None:
    with httpx.Client(base_url=run.url, trust_env=False) as c:
        response = c.get("/healthz")
        assert (response.status_code, response.text) == (200, "ok")
        run.backend.healthy = False
        response = c.get("/healthz")
        assert (response.status_code, response.text) == (503, "unavailable")
        assert "server" not in response.headers


def test_other_paths_are_404(run: Running, key: str) -> None:
    with client(run, key) as c:
        for path in ("/v1/completions", "/v1/embeddings", "/v1/responses", "/health", "/"):
            assert c.post(path, json={}).status_code in {404, 405}, path
            assert c.get(path).status_code == 404, path


def test_unknown_model_is_rejected(run: Running, key: str) -> None:
    response = chat(run, key, model="gpt-4o")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "model_not_found"
    assert run.backend.requests == []


def test_images_are_rejected(run: Running, key: str) -> None:
    content = [
        {"type": "text", "text": "what is this?"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}},
    ]
    with client(run, key) as c:
        response = c.post(
            "/v1/chat/completions", json={"messages": [{"role": "user", "content": content}]}
        )
    assert response.status_code == 400
    assert "only text is supported" in response.json()["error"]["message"]


def test_invalid_json_is_rejected(run: Running, key: str) -> None:
    with client(run, key) as c:
        for body in (b"{nope", b"[" * 100_000):  # the second is too deep for json.loads
            response = c.post("/v1/chat/completions", content=body)
            assert response.status_code == 400
            assert response.json()["error"]["message"] == "the request body is not valid JSON"


# -- what reaches the backend ---------------------------------------------


def test_non_streaming_answer(run: Running, key: str) -> None:
    run.backend.tool_calls = [{"name": "get_weather", "arguments": '{"city": "Paris"}'}]
    run.backend.finish_reason = "tool_calls"
    response = chat(run, key, tools=[{"type": "function", "function": {"name": "get_weather"}}])
    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "chat.completion"
    assert body["model"] == MODEL
    assert "system_fingerprint" not in body
    choice = body["choices"][0]
    assert choice["finish_reason"] == "tool_calls"
    assert choice["message"]["content"] == "Hello there."
    assert choice["message"]["tool_calls"] == [
        {
            "function": {"name": "get_weather", "arguments": '{"city": "Paris"}'},
            "type": "function",
            "id": "call-0",
        }
    ]
    assert body["usage"]["prompt_tokens"] == 2 + 10


def test_forwarded_request(run: Running, key: str) -> None:
    response = chat(
        run,
        key,
        max_tokens=32000,  # what opencode sends: clamped, not rejected
        temperature=0.2,
        adapters="evil/adapter",
        draft_model="evil/draft",
        num_draft_tokens=5,
        role_mapping={"user": "x"},
        chat_template_kwargs={"enable_thinking": True},
        logprobs=True,
    )
    assert response.status_code == 200
    sent = run.backend.requests[-1]
    assert sent["model"] == "default_model"
    assert sent["max_tokens"] == 200  # max_output_tokens
    assert sent["temperature"] == 0.2  # the client's value is kept
    assert (sent["top_p"], sent["top_k"]) == (0.8, 20)  # the rest are the non-thinking defaults
    assert sent["stream"] is True and sent["stream_options"] == {"include_usage": True}
    for name in (
        "adapters",
        "draft_model",
        "num_draft_tokens",
        "role_mapping",
        "chat_template_kwargs",
        "logprobs",
    ):
        assert name not in sent, name


def test_max_tokens_clamped_to_the_room_left(lab_home: Path, key: str) -> None:
    with running_gateway(FakeBackend(), max_context=100) as run:
        words = " ".join(["word"] * 40)
        response = chat(run, key, messages=[{"role": "user", "content": words}])
        assert response.status_code == 200
        assert run.backend.requests[-1]["max_tokens"] == 60  # 100 - 40
        response = chat(run, key, messages=[{"role": "user", "content": words}], max_tokens=7)
        assert run.backend.requests[-1]["max_tokens"] == 7
        response = chat(
            run, key, messages=[{"role": "user", "content": words}], max_completion_tokens=9
        )
        assert run.backend.requests[-1]["max_tokens"] == 9


def test_oversized_prompt_never_reaches_the_backend(lab_home: Path, key: str) -> None:
    with running_gateway(FakeBackend(), max_context=100) as run:
        words = " ".join(["word"] * 51)  # 100 - 50 reserved for output = 50 allowed
        response = chat(run, key, messages=[{"role": "user", "content": words}], stream=True)
        assert response.status_code == 400
        error = response.json()["error"]
        assert error["code"] == "context_length_exceeded"
        assert "51 tokens" in error["message"]
        assert run.backend.requests == []


def test_reasoning_effort(run: Running, key: str) -> None:
    chat(run, key)
    sent = run.backend.requests[-1]
    assert "chat_template_kwargs" not in sent  # the backend's default: thinking off
    assert sent["temperature"] == 0.7
    assert run.counter.calls[-1]["template_args"] == {"enable_thinking": False}

    chat(run, key, reasoning_effort="none")
    assert "chat_template_kwargs" not in run.backend.requests[-1]

    for effort, level in (("low", "low"), ("medium", "medium"), ("high", "xhigh")):
        chat(run, key, reasoning_effort=effort)
        sent = run.backend.requests[-1]
        expected = {"enable_thinking": True, "reasoning_effort": level}
        assert sent["chat_template_kwargs"] == expected
        assert (sent["temperature"], sent["top_p"], sent["top_k"]) == (0.6, 0.95, 20)
        assert run.counter.calls[-1]["template_args"] == expected  # counted the same way

    response = chat(run, key, reasoning_effort="extreme")
    assert response.status_code == 400
    assert response.json()["error"]["param"] == "reasoning_effort"


def test_backend_error_is_reported(run: Running, key: str) -> None:
    run.backend.status = 404
    response = chat(run, key)
    assert response.status_code == 400
    assert "rejected the request" in response.json()["error"]["message"]


def test_backend_down(lab_home: Path, key: str) -> None:
    with running_gateway(FakeBackend(), backend_running=False) as run:
        response = chat(run, key)
        assert response.status_code == 503
        assert response.json()["error"]["message"] == "the model server is not running"
        streamed = chat(run, key, stream=True)
        assert streamed.status_code == 200
        assert events(streamed.text)[-1]["error"]["message"] == "the model server is not running"
        with httpx.Client(base_url=run.url, trust_env=False) as c:
            assert c.get("/healthz").text == "unavailable"


# -- streaming ------------------------------------------------------------------


def test_streaming_answer(run: Running, key: str) -> None:
    run.backend.reasoning = ["Let me think."]
    response = chat(run, key, stream=True)
    assert response.status_code == 200
    assert response.headers["content-type"] == "text/event-stream"
    assert response.headers["cache-control"] == "no-cache"
    data = events(response.text)
    assert data[-1] == "[DONE]"
    chunks = data[:-1]
    assert all(c["model"] == MODEL and "system_fingerprint" not in c for c in chunks)
    assert all(c["choices"] for c in chunks)  # no usage chunk: the client did not ask
    deltas = [c["choices"][0]["delta"] for c in chunks]
    assert deltas[0]["reasoning"] == deltas[0]["reasoning_content"] == "Let me think."
    assert "".join(d.get("content", "") for d in deltas) == "Hello there."
    assert ": keepalive" not in response.text  # mlx-lm's own progress comments are dropped

    response = chat(run, key, stream=True, stream_options={"include_usage": True})
    usage = events(response.text)[-2]
    assert usage["choices"] == [] and usage["usage"]["prompt_tokens"] == 2
    assert usage["object"] == "chat.completion.chunk" and usage["model"] == MODEL


def test_heartbeats_while_queued_and_prefilling(lab_home: Path, key: str) -> None:
    backend = FakeBackend(prefill_seconds=1.2)
    with running_gateway(backend, heartbeat_seconds=0.2) as run, client(run, key) as c:
        started = time.monotonic()
        times: list[float] = []
        first_data = None
        body = {"messages": HELLO, "stream": True}
        with c.stream("POST", "/v1/chat/completions", json=body) as response:
            assert response.status_code == 200
            headers_after = time.monotonic() - started
            for line in response.iter_lines():
                if line == ": keep-alive":
                    times.append(time.monotonic() - started)
                elif line.startswith("data:") and first_data is None:
                    first_data = time.monotonic() - started
        assert headers_after < 0.5  # headers go out before the backend has answered
        assert first_data is not None and first_data >= 1.2
        before = [t for t in times if t < first_data]
        assert len(before) >= 4
        gaps = [b - a for a, b in zip([0.0, *before], before, strict=False)]
        assert max(gaps) < 0.5


def test_full_queue_returns_429(lab_home: Path, key: str) -> None:
    backend = FakeBackend(prefill_seconds=1.0)
    with running_gateway(backend, queue_size=1) as run:
        results: list[int] = []

        def slow_request() -> None:
            results.append(chat(run, key).status_code)

        threads = [threading.Thread(target=slow_request) for _ in range(2)]
        for thread in threads:
            thread.start()
            time.sleep(0.1)
        wait_for(lambda: run.gateway.queue.active == 1 and run.gateway.queue.waiting == 1)
        response = chat(run, key)
        assert response.status_code == 429
        assert response.headers["retry-after"]
        assert response.json()["error"]["type"] == "rate_limit_error"
        for thread in threads:
            thread.join()
        assert results == [200, 200]
        assert backend.started == 2  # one at a time, both served


def test_client_disconnect_cancels_the_stream(lab_home: Path, key: str) -> None:
    backend = FakeBackend(chunk_seconds=0.3, pieces=["x"] * 50)
    with running_gateway(backend) as run, client(run, key) as c:
        body = {"messages": HELLO, "stream": True}
        with c.stream("POST", "/v1/chat/completions", json=body) as response:
            for line in response.iter_lines():
                if line.startswith("data:"):
                    break  # the client goes away after the first chunk
        wait_for(lambda: backend.cancelled == 1)
        assert backend.finished == 0
        wait_for(lambda: run.gateway.queue.active == 0)
        backend.chunk_seconds = 0
        assert chat(run, key).status_code == 200  # the slot is free again


def test_client_disconnect_cancels_a_queued_request(lab_home: Path, key: str) -> None:
    backend = FakeBackend(prefill_seconds=1.0)
    with running_gateway(backend, queue_size=2) as run:
        first = threading.Thread(target=lambda: chat(run, key))
        first.start()
        wait_for(lambda: run.gateway.queue.active == 1)
        with client(run, key, timeout=0.3) as c, pytest.raises(httpx.ReadTimeout):
            c.post("/v1/chat/completions", json={"messages": HELLO})
        wait_for(lambda: run.gateway.queue.waiting == 0)
        first.join()
        time.sleep(0.2)
        assert backend.started == 1  # the request that left never reached the backend


def test_client_disconnect_cancels_a_non_streaming_request(lab_home: Path, key: str) -> None:
    backend = FakeBackend(chunk_seconds=0.3, pieces=["x"] * 50)
    with running_gateway(backend) as run:
        with client(run, key, timeout=0.5) as c, pytest.raises(httpx.ReadTimeout):
            c.post("/v1/chat/completions", json={"messages": HELLO})
        wait_for(lambda: backend.cancelled == 1)
        assert backend.finished == 0
        wait_for(lambda: run.gateway.queue.active == 0)


def test_request_log_has_no_bodies(
    run: Running, key: str, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level("INFO", logger="agent_lab.gateway")
    chat(run, key, messages=[{"role": "user", "content": "agentlab-secret words"}])

    def lines() -> list[str]:
        records = caplog.records
        return [r.getMessage() for r in records if r.name == "agent_lab.gateway.requests"]

    wait_for(lambda: len(lines()) == 1)  # written once the response has gone out
    line = lines()[0]
    assert line.startswith("key=test status=200 stream=false effort=default prompt_tokens=2 ")
    assert "backend_prompt_tokens=2 " in line and "completion_tokens=3" in line
    assert "agentlab-secret" not in caplog.text
