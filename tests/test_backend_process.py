"""serve/stop/status process management against a fake backend process."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import pytest

from agent_lab import paths
from agent_lab.backend import process
from agent_lab.backend.process import State
from agent_lab.backend.settings import LaunchSettings

FAKE = Path(__file__).with_name("fake_backend.py")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
        return port


def settings(port: int) -> LaunchSettings:
    return LaunchSettings("ci-tiny", "tiny", Path("/nonexistent"), port, 1024**3, None, ())


def command(port: int, mode: str) -> list[str]:
    return [sys.executable, str(FAKE), str(port), mode, process.LAUNCH_MODULE]


@pytest.fixture
def backend(lab_home: Path) -> object:
    yield
    process.stop(timeout=2)


def port_free(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


def test_start_status_stop(backend: object) -> None:
    port = free_port()
    status, created = process.start(settings(port), 20, command(port, "ok"))
    assert created
    assert status.state is State.RUNNING
    assert status.ready is not None and status.ready["load_seconds"] == 0.3
    assert status.record is not None
    pid = status.record.pid

    now = process.status()
    assert now.state is State.RUNNING
    assert now.rss_bytes is not None and now.rss_bytes > 0
    assert now.memory is None  # the fake backend records no Metal memory
    paths.backend_memory().write_text(json.dumps({"pid": pid, "active_bytes": 5, "peak_bytes": 6}))
    assert process.status().memory == {"pid": pid, "active_bytes": 5, "peak_bytes": 6}

    record, was_running = process.stop()
    assert record is not None and record.pid == pid and was_running
    assert process.status().state is State.STOPPED
    assert not process.is_backend(pid)
    assert port_free(port)
    assert not paths.backend_state().exists()
    assert not paths.backend_ready().exists()
    assert not paths.backend_memory().exists()


def test_second_start_finds_the_running_backend(backend: object) -> None:
    port = free_port()
    first, created = process.start(settings(port), 20, command(port, "ok"))
    second, created_again = process.start(settings(port), 20, command(port, "ok"))
    assert created and not created_again
    assert first.record is not None and second.record is not None
    assert second.record.pid == first.record.pid


def test_unexpected_exit_is_reported(backend: object) -> None:
    port = free_port()
    status, _ = process.start(settings(port), 20, command(port, "ok"))
    assert status.record is not None
    os.kill(status.record.pid, signal.SIGKILL)
    deadline = time.monotonic() + 5
    while process.status().state is not State.EXITED and time.monotonic() < deadline:
        time.sleep(0.05)
    exited = process.status()
    assert exited.state is State.EXITED
    assert exited.record == status.record
    record, was_running = process.stop()
    assert record == status.record and not was_running
    assert process.status().state is State.STOPPED


def test_exit_while_starting_fails_with_the_log(backend: object) -> None:
    port = free_port()
    with pytest.raises(process.BackendError) as excinfo:
        process.start(settings(port), 20, command(port, "exit"))
    message = str(excinfo.value)
    assert "exited with status 3 while starting" in message
    assert "Model type qwen9 not supported." in message
    assert process.status().state is State.STOPPED


def test_timeout_stops_the_process(backend: object, monkeypatch: pytest.MonkeyPatch) -> None:
    port = free_port()
    started: list[int] = []
    real_popen = subprocess.Popen

    def popen(*args: Any, **kwargs: Any) -> Any:
        proc = real_popen(*args, **kwargs)
        started.append(proc.pid)
        return proc

    monkeypatch.setattr(subprocess, "Popen", popen)
    with pytest.raises(process.BackendError, match="not ready after 1s; stopped it"):
        process.start(settings(port), 1, command(port, "hang"))
    assert started and not process.is_backend(started[0])
    assert process.status().state is State.STOPPED


def test_unhealthy_backend_is_reported(backend: object) -> None:
    port = free_port()
    with pytest.raises(process.BackendError, match="not ready"):
        process.start(settings(port), 2, command(port, "unhealthy"))


def test_stop_kills_a_backend_that_ignores_sigterm(backend: object) -> None:
    port = free_port()
    status, _ = process.start(settings(port), 20, command(port, "ignore-term"))
    assert status.record is not None
    _, was_running = process.stop(timeout=0.5)
    assert was_running
    assert not process.is_backend(status.record.pid)


def test_a_reused_pid_is_not_the_backend(lab_home: Path) -> None:
    paths.ensure_layout()
    # Our own pid is alive but its command line is pytest, not the launch module.
    process.Record(os.getpid(), 8100, "ci-tiny", "tiny", time.time()).save(paths.backend_state())
    assert process.status().state is State.EXITED
    record, was_running = process.stop()
    assert record is not None and not was_running  # and pytest is still alive


def test_corrupt_record_counts_as_stopped(lab_home: Path) -> None:
    paths.ensure_layout()
    paths.backend_state().write_text("{not json")
    assert process.status().state is State.STOPPED


def test_log_tail(tmp_path: Path) -> None:
    log = tmp_path / "x.log"
    log.write_text("".join(f"line {i}\n" for i in range(100)))
    assert process.log_tail(log, 3) == ["line 97", "line 98", "line 99"]
    assert process.log_tail(tmp_path / "missing.log") == []
