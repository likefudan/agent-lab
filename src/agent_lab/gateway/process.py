"""Start, stop and inspect the gateway process, like ``backend.process`` does for the backend.

The gateway runs detached, recorded in ``var/run/gateway.json``; it writes
``gateway.ready.json`` once it listens and ``gateway.queue.json`` whenever its
queue changes. It is ready when ``/healthz`` answers at all: "unavailable"
only means the backend is down, which ``alab status`` shows separately.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import subprocess
import sys
import time
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any

from agent_lab import paths
from agent_lab.backend import process
from agent_lab.backend.process import Record, State

MODULE = "agent_lab.gateway"
START_TIMEOUT = 120.0  # loading transformers and the tokenizer takes a few seconds
STOP_TIMEOUT = 10.0


@dataclass(frozen=True)
class Status:
    state: State
    record: Record | None
    ready: dict[str, Any] | None
    queue: dict[str, Any] | None  # {"active": n, "waiting": n}


def is_gateway(pid: int) -> bool:
    return process.runs_module(pid, MODULE)


def _answers(port: int) -> bool:
    return process.health(port, "/healthz") is not None


def status() -> Status:
    record = Record.load(paths.gateway_state())
    if record is None:
        return Status(State.STOPPED, None, None, None)
    if not is_gateway(record.pid):
        return Status(State.EXITED, record, None, None)
    ready = process.read_record(paths.gateway_ready(), record.pid)
    if ready is None:
        state = State.LOADING
    else:
        state = State.RUNNING if _answers(record.port) else State.UNHEALTHY
    queue = process.read_record(paths.gateway_queue(), record.pid)
    return Status(state, record, ready, queue)


def _clear_files() -> None:
    for path in (paths.gateway_state(), paths.gateway_ready(), paths.gateway_queue()):
        path.unlink(missing_ok=True)


@contextlib.contextmanager
def _locked() -> Iterator[None]:
    paths.run_dir().mkdir(parents=True, exist_ok=True)
    with paths.gateway_lock().open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def launch_command(profile: str) -> list[str]:
    return [sys.executable, "-m", MODULE, "--profile", profile]


def _failure(message: str) -> process.BackendError:
    lines = [message]
    for path in (paths.gateway_log(), paths.gateway_console_log()):
        tail = process.log_tail(path)
        if tail:
            lines.append(f"last lines of {path}:")
            lines.extend(f"  {line}" for line in tail)
    return process.BackendError("\n".join(lines))


def start(
    profile: str,
    port: int,
    model: str,
    timeout: float = START_TIMEOUT,
    command: list[str] | None = None,
) -> tuple[Status, bool]:
    """Start the gateway and wait until it answers. Returns the status and whether it started it.

    Raises BackendError (with the end of the log) if it exits or does not answer in time.
    """
    with _locked():
        current = status()
        if current.state in {State.RUNNING, State.LOADING, State.UNHEALTHY}:
            return current, False
        _clear_files()
        paths.ensure_layout()
        with paths.gateway_console_log().open("wb") as out:
            proc = subprocess.Popen(
                command or launch_command(profile),
                stdin=subprocess.DEVNULL,
                stdout=out,
                stderr=subprocess.STDOUT,
                env={**os.environ, "AGENT_LAB_HOME": str(paths.home())},
                cwd=paths.home(),
                start_new_session=True,
            )
        record = Record(proc.pid, port, profile, model, time.time())
        try:
            record.save(paths.gateway_state())
        except BaseException:
            process.terminate(proc.pid, proc, STOP_TIMEOUT, is_gateway)
            raise
    try:
        deadline = time.monotonic() + timeout
        while True:
            code = proc.poll()
            if code is not None:
                raise _failure(f"the gateway exited with status {code} while starting")
            ready = process.read_record(paths.gateway_ready(), proc.pid)
            if ready is not None and _answers(port):
                queue = process.read_record(paths.gateway_queue(), proc.pid)
                return Status(State.RUNNING, record, ready, queue), True
            if time.monotonic() > deadline:
                raise _failure(f"the gateway did not answer after {timeout:.0f}s; stopped it")
            time.sleep(process.POLL_INTERVAL)
    except BaseException:
        with _locked():
            process.terminate(proc.pid, proc, STOP_TIMEOUT, is_gateway)
            if Record.load(paths.gateway_state()) == record:
                _clear_files()
        raise


def stop(timeout: float = STOP_TIMEOUT) -> tuple[Record | None, bool]:
    """Stop the gateway. Returns its record (None if none) and whether it was running."""
    with _locked():
        record = Record.load(paths.gateway_state())
        if record is None:
            _clear_files()
            return None, False
        running = is_gateway(record.pid)
        if running:
            process.terminate(record.pid, None, timeout, is_gateway)
        _clear_files()
        return record, running
