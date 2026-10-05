"""The launch wrapper's hooks and memory guard, without MLX (fake server and mx modules)."""

from __future__ import annotations

import io
import json
import logging
import threading
import types
from pathlib import Path
from typing import Any

import pytest

from agent_lab import config
from agent_lab.backend import launch
from agent_lab.backend.settings import launch_settings


class Exited(Exception):
    def __init__(self, code: int) -> None:
        self.code = code


@pytest.fixture
def exits(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_exit(code: int) -> None:
        raise Exited(code)

    monkeypatch.setattr(launch, "_exit", fake_exit)
    monkeypatch.setattr(launch, "GENERATION_DIED_GRACE", 0)


def qwen3_coder_parser(text: str, tools: Any) -> dict[str, Any]:
    return {}


qwen3_coder_parser.__module__ = "mlx_lm.tool_parsers.qwen3_coder"


def fake_modules(fail_load: bool = False, fail_generate: bool = False) -> tuple[Any, Any]:
    class ModelProvider:
        def __init__(self, cli_args: Any) -> None:
            self._tokenizer_config: dict[str, Any] = {"trust_remote_code": False}
            self.tokenizer: Any = None

        def load_default(self) -> None:
            if fail_load:
                raise ValueError("Model type qwen9 not supported.")
            parser = self._tokenizer_config.get("tool_parser_type")
            # Like mlx-lm: the chosen parser's name ends up in init_kwargs.
            self.tokenizer = types.SimpleNamespace(
                tool_parser=qwen3_coder_parser if parser == "qwen3_coder" else None,
                init_kwargs={"tool_parser_type": parser} if parser else {},
            )

    class ResponseGenerator:
        def __init__(self) -> None:
            self._generation_failed = False

        def _run_generate(self) -> None:
            self._generation_failed = fail_generate

    class APIHandler:
        def __init__(self, headers: dict[str, str]) -> None:
            self.headers = headers
            self.wfile = io.BytesIO()
            self.sent: list[Any] = []
            self.handled = False

        def send_response(self, code: int) -> None:
            self.sent.append(code)

        def send_header(self, name: str, value: str) -> None:
            self.sent.append((name, value))

        def end_headers(self) -> None:
            pass

        def do_POST(self) -> None:
            self.handled = True

    server = types.SimpleNamespace(
        ModelProvider=ModelProvider, ResponseGenerator=ResponseGenerator, APIHandler=APIHandler
    )
    mx = types.SimpleNamespace(
        get_active_memory=lambda: 15 * 1024**3, get_peak_memory=lambda: 16 * 1024**3
    )
    return server, mx


def test_tool_parser_is_passed_to_the_tokenizer_and_ready_file_written(
    lab_home: Path, tmp_path: Path
) -> None:
    server, mx = fake_modules()
    settings = launch_settings(config.load_profile())
    ready = tmp_path / "ready.json"
    launch.install_hooks(server, mx, settings, ready, tmp_path / "memory.json")
    provider = server.ModelProvider(None)
    assert provider._tokenizer_config["tool_parser_type"] == "qwen3_coder"
    provider.load_default()
    info = json.loads(ready.read_text())
    assert info["tool_parser"] == "qwen3_coder"
    assert info["model"] == "qwen3.8-27b-mlx-4bit"
    assert info["metal_active_bytes"] == 15 * 1024**3
    assert info["pid"] > 0
    assert isinstance(info["load_seconds"], float)
    memory = json.loads((tmp_path / "memory.json").read_text())
    assert memory == {"pid": info["pid"], "active_bytes": 15 * 1024**3, "peak_bytes": 16 * 1024**3}


def test_auto_tool_parser_is_not_forced(lab_home: Path, tmp_path: Path) -> None:
    server, mx = fake_modules()
    launch.install_hooks(
        server, mx, launch_settings(config.load_profile("ci-tiny")), tmp_path / "r", tmp_path / "m"
    )
    provider = server.ModelProvider(None)
    assert "tool_parser_type" not in provider._tokenizer_config
    provider.load_default()
    assert json.loads((tmp_path / "r").read_text())["tool_parser"] is None


def test_failed_load_exits(lab_home: Path, tmp_path: Path, exits: None) -> None:
    server, mx = fake_modules(fail_load=True)
    launch.install_hooks(
        server, mx, launch_settings(config.load_profile()), tmp_path / "r", tmp_path / "m"
    )
    with pytest.raises(Exited) as excinfo:
        server.ModelProvider(None).load_default()
    assert excinfo.value.code == launch.EXIT_LOAD_FAILED
    assert not (tmp_path / "r").exists()


def test_dead_generation_thread_exits(lab_home: Path, tmp_path: Path, exits: None) -> None:
    server, mx = fake_modules(fail_generate=True)
    launch.install_hooks(
        server, mx, launch_settings(config.load_profile()), tmp_path / "r", tmp_path / "m"
    )
    with pytest.raises(Exited) as excinfo:
        server.ResponseGenerator()._run_generate()
    assert excinfo.value.code == launch.EXIT_GENERATION_DIED


def test_generation_thread_stopping_normally_does_not_exit(lab_home: Path, tmp_path: Path) -> None:
    server, mx = fake_modules()
    launch.install_hooks(
        server, mx, launch_settings(config.load_profile()), tmp_path / "r", tmp_path / "m"
    )
    server.ResponseGenerator()._run_generate()


def test_check_memory() -> None:
    assert launch.check_memory(10, 10) is None
    reason = launch.check_memory(int(19.6 * 1024**3), int(19.5 * 1024**3))
    assert reason is not None
    assert "19.60 GB" in reason and "19.50 GB" in reason
    assert "600.0 MB" in (launch.check_memory(700 * 1024**2, 600 * 1024**2) or "")


def test_watchdog_reports_when_memory_exceeds_the_limit() -> None:
    readings = iter([100, 200, 300, 2000, 100])
    reported: list[str] = []
    done = threading.Event()

    def exceeded(reason: str) -> None:
        reported.append(reason)
        done.set()

    thread = launch.start_watchdog(lambda: next(readings), 1000, exceeded, interval=0.001)
    assert done.wait(5)
    thread.join(5)
    assert not thread.is_alive()
    assert len(reported) == 1 and "limit" in reported[0]


def test_log_stream_logs_complete_lines(caplog: pytest.LogCaptureFixture) -> None:
    stream = launch._LogStream(logging.getLogger("test.stream"), logging.INFO)
    with caplog.at_level(logging.INFO, logger="test.stream"):
        stream.write("first line\nsecond ")
        stream.write("part\n\n")
        stream.write("unterminated")
        stream.flush()
    assert [r.getMessage() for r in caplog.records] == ["first line", "second part", "unterminated"]


def test_main_rejects_a_bad_profile(lab_home: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert launch.main(["--profile", "missing"]) == launch.EXIT_CONFIG
    assert 'profile "missing" not found' in capsys.readouterr().err


def test_watchdog_samples_memory_for_status() -> None:
    samples: list[int] = []
    done = threading.Event()

    def sample(active: int) -> None:
        samples.append(active)
        if len(samples) >= 2:
            done.set()

    stop = threading.Event()
    thread = launch.start_watchdog(
        lambda: 500,
        1000,
        lambda reason: None,
        interval=0.001,
        on_sample=sample,
        sample_every=0.01,
        stop=stop,
    )
    assert done.wait(5)
    stop.set()
    thread.join(5)
    assert not thread.is_alive()
    assert samples[:2] == [500, 500]


def test_watchdog_stops_when_memory_cannot_be_read() -> None:
    reported: list[str] = []

    def broken() -> int:
        raise RuntimeError("[metal] device lost")

    thread = launch.start_watchdog(broken, 1000, reported.append, interval=0.001)
    thread.join(5)
    assert len(reported) == 1 and "cannot read MLX memory use" in reported[0]


def test_watchdog_survives_a_failing_sample() -> None:
    calls: list[int] = []
    done = threading.Event()

    def sample(active: int) -> None:
        calls.append(active)
        if len(calls) >= 2:
            done.set()
        raise TypeError("not serializable")

    stop = threading.Event()
    thread = launch.start_watchdog(
        lambda: 1,
        1000,
        lambda r: None,
        interval=0.001,
        on_sample=sample,
        sample_every=0.0,
        stop=stop,
    )
    assert done.wait(5)
    stop.set()
    thread.join(5)


def test_tool_parser_exists() -> None:
    assert launch.tool_parser_exists("no_such_parser_xyz") is False


def test_browser_requests_are_rejected(lab_home: Path, tmp_path: Path) -> None:
    server, mx = fake_modules()
    launch.install_hooks(
        server, mx, launch_settings(config.load_profile()), tmp_path / "r", tmp_path / "m"
    )
    browser = server.APIHandler({"Origin": "https://example.com"})
    browser.do_POST()
    assert not browser.handled
    assert browser.sent[0] == 403
    assert b"browser requests are not accepted" in browser.wfile.getvalue()
    local = server.APIHandler({})
    local.do_POST()
    assert local.handled and local.sent == []


def test_request_bodies_are_not_logged() -> None:
    record = logging.LogRecord(
        "x",
        logging.ERROR,
        __file__,
        1,
        "Invalid JSON in request: %s. Raw body: %s",
        ("bad", "{secret"),
        None,
    )
    assert launch._NoBodies().filter(record)
    assert record.getMessage() == "Invalid JSON in request: bad. Raw body: [request body omitted]"
    not_object = logging.LogRecord(
        "x", logging.ERROR, __file__, 1, 'Invalid Request Body: [{"content": "secret"}]', None, None
    )
    launch._NoBodies().filter(not_object)
    assert not_object.getMessage() == "Invalid Request Body: [request body omitted]"
    plain = logging.LogRecord("x", logging.INFO, __file__, 1, "hello %s", ("you",), None)
    launch._NoBodies().filter(plain)
    assert plain.getMessage() == "hello you"


def test_write_json_replaces_the_file_and_leaves_no_temp_files(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    launch.write_json(path, {"a": 1})
    launch.write_json(path, {"a": 2})
    assert json.loads(path.read_text()) == {"a": 2}
    assert [p.name for p in tmp_path.iterdir()] == ["state.json"]
