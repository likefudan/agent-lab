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

The watchdog reacts after the fact: one evaluation step (at most one prefill
chunk of ``prefill_step_size`` tokens) can overshoot the limit before it fires.
The gateway's token limit (T05) is the primary guard that keeps requests from
getting there; the watchdog is the second layer (design section 3.3).

Three small hooks adapt mlx-lm 0.32.0 (pinned in ``pyproject.toml``):

- the profile's tool parser is passed to the tokenizer as ``tool_parser_type``,
  the same key mlx-lm reads from ``tokenizer_config.json``, so the verified
  model files stay untouched;
- once the model has loaded, ``backend.ready.json`` records the load time and
  memory, which is how ``alab serve`` knows the backend is ready (mlx-lm's
  ``/health`` already answers while the model is still loading);
- if the model fails to load or the generation thread dies, the process exits
  instead of staying up and failing every request;
- each request's timing, prompt cache use and peak Metal memory are kept for
  ``GET /agent-lab/requests``, which ``alab bench`` reads (T06). MLX's peak
  counter is reset when a request starts, which is exact because the backend
  serves one request at a time; ``alab status`` still shows the lifetime peak.
"""

from __future__ import annotations

import argparse
import contextlib
import faulthandler
import importlib.metadata
import importlib.util
import io
import json
import logging
import os
import signal
import sys
import tempfile
import threading
import time
from collections import deque
from collections.abc import Callable, Iterator
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
MEMORY_SAMPLE_INTERVAL = 2.0  # seconds between memory records for `alab status`
GENERATION_DIED_GRACE = 2.0  # seconds for mlx-lm to send the in-flight request its error
REQUESTS_PATH = "/agent-lab/requests"  # per-request statistics for `alab bench`
REQUEST_LOG_SIZE = 64  # requests kept for REQUESTS_PATH

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
        self._lock = threading.Lock()  # HTTP handler threads write at the same time

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        with self._lock:
            self._buffer += text
            *lines, self._buffer = self._buffer.split("\n")
        for line in lines:
            if line.strip():
                self._logger.log(self._level, line.rstrip())
        return len(text)

    def flush(self) -> None:
        with self._lock:
            rest, self._buffer = self._buffer, ""
        if rest.strip():
            self._logger.log(self._level, rest.rstrip())


class _LogFileHandler(TimedRotatingFileHandler):
    """Reports its own failures (disk full, rotation) on fd 2, not through logging again."""

    def handleError(self, record: logging.LogRecord) -> None:
        with contextlib.suppress(Exception):
            print(f"backend log: cannot write a record: {sys.exc_info()[1]}", file=sys.__stderr__)


class _NoBodies(logging.Filter):
    """Cut request bodies from mlx-lm's messages: it logs the body of a request it rejects."""

    MARKERS = ("Raw body:", "Invalid Request Body:")

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        for marker in self.MARKERS:
            if marker in message:
                record.msg = message.split(marker, 1)[0] + marker + " [request body omitted]"
                record.args = None
                break
        return True


def setup_logging(log_file: Path) -> None:
    """Log to ``log_file``, rotated at midnight; Python's stdout and stderr go there too.

    Native crashes still reach file descriptors 1 and 2, which ``alab serve``
    points at the console log.
    """
    log_file.parent.mkdir(parents=True, exist_ok=True)
    handler = _LogFileHandler(log_file, when="midnight", backupCount=LOG_DAYS, encoding="utf-8")
    handler.addFilter(_NoBodies())
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
    on_sample: Callable[[int], None] | None = None,
    sample_every: float = MEMORY_SAMPLE_INTERVAL,
    stop: threading.Event | None = None,
) -> threading.Thread:
    """Check memory every ``interval``; pass a reading to ``on_sample`` every ``sample_every``."""

    stopped = stop or threading.Event()

    def watch() -> None:
        last_sample = 0.0
        while not stopped.is_set():
            try:
                active = read_active()
            except Exception as exc:
                # Without a reading there is no guard; stopping is the safe choice.
                on_exceeded(f"cannot read MLX memory use ({exc}); stopping the backend")
                return
            reason = check_memory(active, limit)
            if reason:
                on_exceeded(reason)
                return
            now = time.monotonic()
            if on_sample is not None and now - last_sample >= sample_every:
                last_sample = now
                try:
                    on_sample(active)
                except Exception:
                    log.exception("cannot record memory use")  # the guard itself keeps running
            stopped.wait(interval)

    thread = threading.Thread(target=watch, name="memory-watchdog", daemon=True)
    thread.start()
    return thread


def _memory_exceeded(reason: str) -> None:
    log.critical(reason)
    _exit(EXIT_MEMORY_LIMIT)


def write_json(path: Path, info: dict[str, Any]) -> None:
    """Replace ``path`` atomically; safe when several threads write the same file."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(info, indent=2) + "\n")
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


class PeakTracker:
    """MLX's peak memory, per request and over the process's life.

    ``start_window`` resets MLX's peak counter when a request starts; the
    lifetime peak keeps whatever earlier windows reached.
    """

    def __init__(self, mx: ModuleType) -> None:
        self._mx = mx
        self._lifetime = 0
        self._lock = threading.Lock()

    def start_window(self) -> None:
        with self._lock:
            self._lifetime = max(self._lifetime, self._mx.get_peak_memory())
            self._mx.reset_peak_memory()

    def window(self) -> int:
        """The peak since the last ``start_window``."""
        peak: int = self._mx.get_peak_memory()
        return peak

    def lifetime(self) -> int:
        with self._lock:
            return max(self._lifetime, self.window())


class RequestLog:
    """Statistics of the last requests, oldest first, each with an increasing ``id``."""

    def __init__(self, size: int = REQUEST_LOG_SIZE) -> None:
        self._entries: deque[dict[str, Any]] = deque(maxlen=size)
        self._next_id = 1
        self._lock = threading.Lock()

    def add(self, entry: dict[str, Any]) -> None:
        with self._lock:
            self._entries.append({"id": self._next_id, **entry})
            self._next_id += 1

    def snapshot(self) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(e) for e in self._entries]


def memory_record(mx: ModuleType, peaks: PeakTracker, active: int | None = None) -> dict[str, Any]:
    """MLX's memory use for ``alab status`` (RSS leaves out Metal buffers on macOS)."""
    return {
        "pid": os.getpid(),
        "active_bytes": mx.get_active_memory() if active is None else active,
        "peak_bytes": peaks.lifetime(),
    }


def _send_json(handler: Any, code: int, payload: Any) -> None:
    body = json.dumps(payload).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


_BROWSER_REFUSED = {"error": {"message": "browser requests are not accepted"}}


def install_hooks(
    server: ModuleType,
    mx: ModuleType,
    settings: LaunchSettings,
    ready_path: Path,
    memory_path: Path,
    peaks: PeakTracker | None = None,
    requests: RequestLog | None = None,
) -> None:
    """Adapt mlx_lm.server (0.32.0): tool parser, readiness record, exit on fatal errors,
    per-request statistics and no requests from web pages."""
    if peaks is None:
        peaks = PeakTracker(mx)
    if requests is None:
        requests = RequestLog()
    provider_cls = server.ModelProvider
    generator_cls = server.ResponseGenerator
    handler_cls = server.APIHandler
    original_do_post = handler_cls.do_POST
    original_do_get = handler_cls.do_GET
    original_init = provider_cls.__init__
    original_load_default = provider_cls.load_default
    original_run_generate = generator_cls._run_generate
    original_generate = generator_cls.generate

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
        # mlx-lm records the parser it chose in the tokenizer's init_kwargs (the
        # function's module can differ: some parsers reuse another's function).
        init_kwargs = getattr(self.tokenizer, "init_kwargs", None) or {}
        parser_name = init_kwargs.get("tool_parser_type") if self.tokenizer.tool_parser else None
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
        write_json(memory_path, memory_record(mx, peaks))
        write_json(ready_path, info)

    def run_generate(self: Any) -> None:
        original_run_generate(self)
        if self._generation_failed:
            log.critical("the generation thread died (see the traceback above); exiting")
            time.sleep(GENERATION_DIED_GRACE)
            _exit(EXIT_GENERATION_DIED)

    def generate(
        self: Any, request: Any, args: Any, progress_callback: Any = None
    ) -> tuple[Any, Iterator[Any]]:
        # Requests run one at a time (concurrency 1), so the peak window is this request's.
        peaks.start_window()
        started = time.monotonic()
        entry: dict[str, Any] = {
            "started_at": round(time.time(), 3),
            "metal_active_before_bytes": mx.get_active_memory(),
            "prompt_cache_before_bytes": self.prompt_cache.nbytes,
            "prompt_cache_before_entries": len(self.prompt_cache),
        }
        ctx, responses = original_generate(self, request, args, progress_callback)

        def timed() -> Iterator[Any]:
            first: float | None = None
            count = 0
            try:
                for response in responses:
                    if first is None:
                        first = time.monotonic()
                    count += 1
                    yield response
            finally:
                # Also when the client went away: the handler stops iterating.
                entry.update(
                    prompt_tokens=len(ctx.prompt),
                    cached_tokens=ctx.prompt_cache_count,
                    generated_tokens=count,
                    first_token_seconds=None if first is None else round(first - started, 4),
                    total_seconds=round(time.monotonic() - started, 4),
                    metal_peak_bytes=peaks.window(),
                    metal_active_after_bytes=mx.get_active_memory(),
                    metal_cache_after_bytes=mx.get_cache_memory(),
                )
                requests.add(entry)

        return ctx, timed()

    def do_post(self: Any) -> None:
        # Browsers add Origin; the gateway and local tools do not. Without this, any web
        # page could send the unauthenticated backend work with a "simple" no-cors POST.
        if self.headers.get("Origin") is not None:
            _send_json(self, 403, _BROWSER_REFUSED)
            return
        original_do_post(self)

    def do_get(self: Any) -> None:
        if self.path.partition("?")[0] != REQUESTS_PATH:
            original_do_get(self)
            return
        if self.headers.get("Origin") is not None:
            _send_json(self, 403, _BROWSER_REFUSED)
            return
        cache = self.response_generator.prompt_cache
        payload = {
            "requests": requests.snapshot(),
            "memory": memory_record(mx, peaks),
            "metal_cache_bytes": mx.get_cache_memory(),
            "prompt_cache": {"entries": len(cache), "bytes": cache.nbytes},
        }
        _send_json(self, 200, payload)

    handler_cls.do_POST = do_post
    handler_cls.do_GET = do_get
    generator_cls.generate = generate
    provider_cls.__init__ = init
    provider_cls.load_default = load_default
    generator_cls._run_generate = run_generate


def tool_parser_exists(name: str) -> bool:
    try:
        return importlib.util.find_spec(f"mlx_lm.tool_parsers.{name}") is not None
    except ImportError:
        return False


def _on_sigterm(signum: int, frame: FrameType | None) -> None:
    log.info("received SIGTERM; exiting")
    _exit(0)


def run(settings: LaunchSettings, ready_path: Path) -> None:
    """Configure MLX and the hooks, then run mlx_lm.server until the process is stopped."""
    os.environ.update(OFFLINE_ENV)  # before huggingface_hub is imported
    import mlx.core as mx
    import mlx_lm.server as server

    if settings.tool_parser and not tool_parser_exists(settings.tool_parser):
        log.error(
            "mlx-lm has no tool parser %r; check tool_parser in the profile", settings.tool_parser
        )
        _exit(EXIT_CONFIG)

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
    memory_path = paths.backend_memory()
    peaks = PeakTracker(mx)
    install_hooks(server, mx, settings, ready_path, memory_path, peaks)

    def record_memory(active: int) -> None:
        write_json(memory_path, memory_record(mx, peaks, active))

    start_watchdog(
        mx.get_active_memory, settings.memory_limit, _memory_exceeded, on_sample=record_memory
    )
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
