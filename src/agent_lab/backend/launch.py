"""The backend process: guard MLX's memory, then run ``mlx_lm.server`` in this process.

``alab serve`` starts it as ``python -m agent_lab.backend.launch --profile <name>``.
Every server argument comes from the profile (see ``settings``).

Memory: in MLX 0.32, ``mx.set_memory_limit()`` is only a soft limit. Above it,
evaluation waits for queued work to finish and then allocates anyway; nothing
raises until Metal itself refuses an allocation (``mlx/transforms.cpp`` and
``mlx/backend/metal/allocator.cpp``), which is too late on a machine whose GPU
memory is wired. So this wrapper does two things:

1. it sets the soft limit, which also keeps MLX's buffer cache trimmed below it;
2. a watchdog thread reads MLX's active memory every few milliseconds and, when
   it exceeds the limit, logs the reason and exits the process. Exiting returns
   all of the process's GPU memory at once, and ``alab status`` reports the exit
   with the log path.

The gateway's token limit (T05) keeps requests from getting there; this guard
is the second layer (design section 3.3).

Three small hooks adapt mlx-lm 0.32.0 (pinned in ``pyproject.toml``):

- the profile's tool parser is passed to the tokenizer as ``tool_parser_type``,
  the same key mlx-lm reads from ``tokenizer_config.json``, so the verified
  model files stay untouched;
- once the model has loaded, ``backend.ready.json`` records the load time and
  memory, which is how ``alab serve`` knows the backend is ready (mlx-lm's
  ``/health`` already answers while the model is still loading);
- if the model fails to load or the generation thread dies, the process exits
  instead of staying up and failing every request.
"""

from __future__ import annotations

import argparse
import faulthandler
import importlib.metadata
import io
import json
import logging
import os
import signal
import sys
import threading
import time
from collections.abc import Callable
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path
from types import FrameType, ModuleType
from typing import Any

from agent_lab import config, paths
from agent_lab.backend.settings import LaunchSettings, launch_settings

log = logging.getLogger("agent_lab.backend")

LOG_DAYS = 14  # rotated logs kept
WATCHDOG_INTERVAL = 0.01  # seconds between memory checks
EXIT_CONFIG = 2
EXIT_LOAD_FAILED = 3
EXIT_GENERATION_DIED = 4
EXIT_MEMORY_LIMIT = 5
GENERATION_DIED_GRACE = 2.0  # seconds for mlx-lm to send the in-flight request its error

# Environment of the server: models only ever come from `alab pull` (design section 9).
OFFLINE_ENV = {"HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"}

GIB = 1024**3
MIB = 1024**2


class _LogStream(io.TextIOBase):
    """A text stream that sends each complete line to a logger (for sys.stdout/sys.stderr)."""

    def __init__(self, logger: logging.Logger, level: int) -> None:
        self._logger = logger
        self._level = level
        self._buffer = ""

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        self._buffer += text
        *lines, self._buffer = self._buffer.split("\n")
        for line in lines:
            if line.strip():
                self._logger.log(self._level, line.rstrip())
        return len(text)

    def flush(self) -> None:
        if self._buffer.strip():
            self._logger.log(self._level, self._buffer.rstrip())
        self._buffer = ""


def setup_logging(log_file: Path) -> None:
    """Log to ``log_file``, rotated at midnight; Python's stdout and stderr go there too.

    Native crashes still reach file descriptors 1 and 2, which ``alab serve``
    points at the console log.
    """
    log_file.parent.mkdir(parents=True, exist_ok=True)
    handler = TimedRotatingFileHandler(
        log_file, when="midnight", backupCount=LOG_DAYS, encoding="utf-8"
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)
    faulthandler.enable(file=2)  # fd 2 is the console log
    sys.stdout = _LogStream(logging.getLogger("stdout"), logging.INFO)
    # mlx-lm's access log lines arrive on stderr; real errors carry their own log level.
    sys.stderr = _LogStream(logging.getLogger("stderr"), logging.INFO)


def _version(package: str) -> str:
    try:
        return importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def _exit(code: int) -> None:
    """Leave now, whatever other threads are doing (mlx-lm's generation thread never ends)."""
    logging.shutdown()
    os._exit(code)


def check_memory(active_bytes: int, limit: int) -> str | None:
    """The reason to stop, or None while MLX stays within the limit."""
    if active_bytes <= limit:
        return None
    return (
        f"Metal memory limit exceeded: MLX is using {_size(active_bytes)}, "
        f"the limit is {_size(limit)}; stopping the backend to protect the system"
    )


def _size(n: int) -> str:
    return f"{n / GIB:.2f} GB" if n >= GIB else f"{n / MIB:.1f} MB"


def start_watchdog(
    read_active: Callable[[], int],
    limit: int,
    on_exceeded: Callable[[str], None],
    interval: float = WATCHDOG_INTERVAL,
) -> threading.Thread:
    def watch() -> None:
        while True:
            reason = check_memory(read_active(), limit)
            if reason:
                on_exceeded(reason)
                return
            time.sleep(interval)

    thread = threading.Thread(target=watch, name="memory-watchdog", daemon=True)
    thread.start()
    return thread


def _memory_exceeded(reason: str) -> None:
    log.critical(reason)
    _exit(EXIT_MEMORY_LIMIT)


def write_ready(path: Path, info: dict[str, Any]) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(info, indent=2) + "\n")
    tmp.replace(path)


def install_hooks(
    server: ModuleType, mx: ModuleType, settings: LaunchSettings, ready_path: Path
) -> None:
    """Adapt mlx_lm.server (0.32.0): tool parser, readiness record, exit on fatal errors."""
    provider_cls = server.ModelProvider
    generator_cls = server.ResponseGenerator
    original_init = provider_cls.__init__
    original_load_default = provider_cls.load_default
    original_run_generate = generator_cls._run_generate

    def init(self: Any, cli_args: argparse.Namespace) -> None:
        original_init(self, cli_args)
        if settings.tool_parser:
            self._tokenizer_config["tool_parser_type"] = settings.tool_parser

    def load_default(self: Any) -> None:
        started = time.monotonic()
        try:
            original_load_default(self)
        except Exception:
            log.exception("loading the model failed")
            _exit(EXIT_LOAD_FAILED)
        seconds = time.monotonic() - started
        parser = self.tokenizer.tool_parser
        parser_name = parser.__module__.rpartition(".")[2] if parser else None
        info = {
            "pid": os.getpid(),
            "model": settings.model_id,
            "load_seconds": round(seconds, 1),
            "metal_active_bytes": mx.get_active_memory(),
            "metal_peak_bytes": mx.get_peak_memory(),
            "tool_parser": parser_name,
            "mlx_lm": _version("mlx-lm"),
            "mlx": _version("mlx"),
        }
        log.info(
            "model loaded in %.1fs: %s of Metal memory in use, tool parser %s",
            seconds,
            _size(info["metal_active_bytes"]),
            parser_name or "none (tool calls will not be parsed)",
        )
        write_ready(ready_path, info)

    def run_generate(self: Any) -> None:
        original_run_generate(self)
        if self._generation_failed:
            log.critical("the generation thread died (see the traceback above); exiting")
            time.sleep(GENERATION_DIED_GRACE)
            _exit(EXIT_GENERATION_DIED)

    provider_cls.__init__ = init
    provider_cls.load_default = load_default
    generator_cls._run_generate = run_generate


def _on_sigterm(signum: int, frame: FrameType | None) -> None:
    log.info("received SIGTERM; exiting")
    _exit(0)


def run(settings: LaunchSettings, ready_path: Path) -> None:
    """Configure MLX and the hooks, then run mlx_lm.server until the process is stopped."""
    os.environ.update(OFFLINE_ENV)  # before huggingface_hub is imported
    import mlx.core as mx
    import mlx_lm.server as server

    log.info(
        "starting mlx_lm.server %s (MLX %s) for %s on port %d, profile %s",
        _version("mlx-lm"),
        _version("mlx"),
        settings.model_id,
        settings.port,
        settings.profile,
    )
    mx.set_memory_limit(settings.memory_limit)
    log.info("Metal memory limit %s (watchdog enforced)", _size(settings.memory_limit))
    install_hooks(server, mx, settings, ready_path)
    start_watchdog(mx.get_active_memory, settings.memory_limit, _memory_exceeded)
    signal.signal(signal.SIGTERM, _on_sigterm)
    sys.argv = ["mlx_lm.server", *settings.server_args]
    server.main()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agent_lab.backend.launch")
    parser.add_argument("--profile", default=config.DEFAULT_PROFILE)
    args = parser.parse_args(argv)
    try:
        settings = launch_settings(config.load_profile(args.profile))
    except config.ConfigError as exc:
        print(f"backend: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    setup_logging(paths.backend_log())
    try:
        run(settings, paths.backend_ready())
    except Exception:
        log.exception("the backend failed")
        _exit(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
