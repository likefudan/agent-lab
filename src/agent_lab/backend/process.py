"""Start, stop and inspect the backend process (``alab serve``, ``alab stop``, ``alab status``).

The backend runs detached from the terminal, in its own session. Its pid, port
and profile are recorded in ``var/run/backend.json``; the backend itself writes
``var/run/backend.ready.json`` once the model is loaded. A recorded pid only
counts as the backend while that process's command line is still the launch
module, so a pid reused by an unrelated process is never signalled.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import asdict, dataclass
from enum import StrEnum
from pathlib import Path
from typing import Any

from agent_lab import paths
from agent_lab.backend import launch
from agent_lab.backend.settings import HOST, LaunchSettings

LAUNCH_MODULE = "agent_lab.backend.launch"
PS = "/bin/ps"
STOP_TIMEOUT = 15.0  # seconds between SIGTERM and SIGKILL
POLL_INTERVAL = 0.5
HEALTH_TIMEOUT = 2.0
LOG_TAIL_LINES = 20


class BackendError(Exception):
    """The backend could not be started or stopped; the message says why."""


class State(StrEnum):
    STOPPED = "not running"
    LOADING = "loading the model"
    RUNNING = "running"
    UNHEALTHY = "running but unhealthy"
    EXITED = "exited unexpectedly"


@dataclass(frozen=True)
class Record:
    """What ``var/run/backend.json`` holds about the backend ``alab serve`` started."""

    pid: int
    port: int
    profile: str
    model: str
    started_at: float  # time.time()

    @classmethod
    def load(cls, path: Path) -> Record | None:
        """The record, or None if there is none or it names no pid.

        Unknown fields are ignored and missing ones get placeholders, so a record
        written by another version still finds (and lets ``stop`` end) its process.
        """
        try:
            data = json.loads(path.read_text())
        except OSError, ValueError:
            return None
        if not isinstance(data, dict) or not isinstance(data.get("pid"), int):
            return None  # nothing names a process, so there is nothing to signal

        def field(name: str, kind: Any, default: Any) -> Any:
            value = data.get(name)
            return value if isinstance(value, kind) and not isinstance(value, bool) else default

        return cls(
            pid=data["pid"],
            port=field("port", int, 0),
            profile=field("profile", str, "unknown"),
            model=field("model", str, "unknown"),
            started_at=float(field("started_at", int | float, 0.0)),
        )

    def save(self, path: Path) -> None:
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self), indent=2) + "\n")
        tmp.replace(path)


@dataclass(frozen=True)
class Status:
    state: State
    record: Record | None
    ready: dict[str, Any] | None  # backend.ready.json, once the model is loaded
    rss_bytes: int | None
    memory: dict[str, Any] | None = None  # backend.memory.json: Metal active and peak bytes


def process_command(pid: int) -> str | None:
    """The process's command line, or None if no such process exists."""
    try:
        result = subprocess.run(
            [PS, "-o", "command=", "-p", str(pid)], capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    command = result.stdout.strip()
    return command or None


def is_backend(pid: int) -> bool:
    try:
        os.kill(pid, 0)  # cheap existence check before running ps
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # exists but belongs to someone else; ps decides
    command = process_command(pid)
    return command is not None and LAUNCH_MODULE in command


def rss_bytes(pid: int) -> int | None:
    try:
        result = subprocess.run(
            [PS, "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    value = result.stdout.strip()
    return int(value) * 1024 if value.isdigit() else None


# Never send local requests through a proxy from http_proxy and friends.
_LOCAL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def health(port: int) -> int | None:
    """HTTP status of the backend's /health, or None if nothing answers."""
    try:
        with _LOCAL_OPENER.open(f"http://{HOST}:{port}/health", timeout=HEALTH_TIMEOUT) as response:
            status: int = response.status
            return status
    except urllib.error.HTTPError as exc:
        return exc.code
    except OSError, ValueError:
        return None


def _read_ready(pid: int) -> dict[str, Any] | None:
    return _read_record(paths.backend_ready(), pid)


def _read_record(path: Path, pid: int) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text())
    except OSError, ValueError:
        return None
    # A record left by an earlier run does not describe this process.
    if not isinstance(data, dict) or data.get("pid") != pid:
        return None
    return data


def status() -> Status:
    record = Record.load(paths.backend_state())
    if record is None:
        return Status(State.STOPPED, None, None, None)
    if not is_backend(record.pid):
        return Status(State.EXITED, record, None, None)
    ready = _read_ready(record.pid)
    if ready is None:
        state = State.LOADING
    else:
        state = State.RUNNING if health(record.port) == 200 else State.UNHEALTHY
    memory = _read_record(paths.backend_memory(), record.pid)
    return Status(state, record, ready, rss_bytes(record.pid), memory)


def log_tail(path: Path, lines: int = LOG_TAIL_LINES) -> list[str]:
    try:
        with path.open("rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 64 * 1024))
            text = f.read().decode("utf-8", errors="replace")
    except OSError:
        return []
    return text.splitlines()[-lines:]


def _clear_files() -> None:
    for path in (paths.backend_state(), paths.backend_ready(), paths.backend_memory()):
        path.unlink(missing_ok=True)


@contextlib.contextmanager
def _locked() -> Iterator[None]:
    """Serialize serve and stop, so two at once cannot start two backends."""
    paths.run_dir().mkdir(parents=True, exist_ok=True)
    with paths.backend_lock().open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def launch_command(profile: str) -> list[str]:
    return [sys.executable, "-m", LAUNCH_MODULE, "--profile", profile]


def child_env() -> dict[str, str]:
    env = dict(os.environ)
    env.update(launch.OFFLINE_ENV)
    env["AGENT_LAB_HOME"] = str(paths.home())
    return env


def _failure(message: str) -> BackendError:
    lines = [message]
    for path in (paths.backend_log(), paths.backend_console_log()):
        tail = log_tail(path)
        if tail:
            lines.append(f"last lines of {path}:")
            lines.extend(f"  {line}" for line in tail)
    return BackendError("\n".join(lines))


def start(
    settings: LaunchSettings,
    timeout: float,
    command: list[str] | None = None,
    progress: Callable[[str], None] | None = None,
) -> tuple[Status, bool]:
    """Start the backend and wait until its model is loaded and /health answers.

    Returns the status and whether this call started it (False if a backend
    was already running). On failure or timeout the new process is stopped
    and BackendError carries the end of the logs. The lock is only held while
    starting the process, so ``alab stop`` can end a backend that is still loading.
    """
    with _locked():
        current = status()
        if current.state in {State.RUNNING, State.LOADING, State.UNHEALTHY}:
            return current, False
        _clear_files()
        paths.ensure_layout()
        console = paths.backend_console_log()
        with console.open("wb") as out:
            proc = subprocess.Popen(
                command or launch_command(settings.profile),
                stdin=subprocess.DEVNULL,
                stdout=out,
                stderr=subprocess.STDOUT,
                env=child_env(),
                cwd=paths.home(),
                start_new_session=True,  # survives the terminal closing; no Ctrl-C from it
            )
        record = Record(proc.pid, settings.port, settings.profile, settings.model_id, time.time())
        try:
            record.save(paths.backend_state())
        except BaseException:
            _terminate(proc.pid, proc)
            raise
    try:
        return _wait_ready(proc, record, timeout, progress), True
    except BaseException:
        with _locked():
            _terminate(proc.pid, proc)
            if Record.load(paths.backend_state()) == record:
                _clear_files()
        raise


def _wait_ready(
    proc: subprocess.Popen[bytes],
    record: Record,
    timeout: float,
    progress: Callable[[str], None] | None,
) -> Status:
    deadline = time.monotonic() + timeout
    last_note = 0.0
    while True:
        code = proc.poll()
        if code is not None:
            raise _failure(f"the backend exited with status {code} while starting")
        ready = _read_ready(record.pid)
        if ready is not None and health(record.port) == 200:
            memory = _read_record(paths.backend_memory(), record.pid)
            return Status(State.RUNNING, record, ready, rss_bytes(record.pid), memory)
        now = time.monotonic()
        if now > deadline:
            raise _failure(f"the backend was not ready after {timeout:.0f}s; stopped it")
        if progress and now - last_note >= 30:
            progress("loading the model..." if ready is None else "waiting for /health...")
            last_note = now
        time.sleep(POLL_INTERVAL)


def _wait_exit(pid: int, proc: subprocess.Popen[bytes] | None, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc is not None:
            if proc.poll() is not None:
                return True
        elif not is_backend(pid):
            return True
        time.sleep(0.1)
    return False


def _terminate(
    pid: int, proc: subprocess.Popen[bytes] | None, timeout: float = STOP_TIMEOUT
) -> bool:
    """SIGTERM, then SIGKILL after ``timeout``. Returns True if SIGKILL was needed."""
    if proc is not None and proc.poll() is not None:
        return False  # already reaped: its pid may belong to another process by now
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGTERM)
    if _wait_exit(pid, proc, timeout):
        return False
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)
    if not _wait_exit(pid, proc, 5.0):
        raise BackendError(f"pid {pid} did not exit after SIGKILL")
    return True


def stop(timeout: float = STOP_TIMEOUT) -> tuple[Record | None, bool]:
    """Stop the backend. Returns its record (None if none was recorded) and whether it was running.

    A record whose process already exited is just cleared.
    """
    with _locked():
        record = Record.load(paths.backend_state())
        if record is None:
            _clear_files()
            return None, False
        running = is_backend(record.pid)
        if running:
            _terminate(record.pid, None, timeout)
        _clear_files()
        return record, running
