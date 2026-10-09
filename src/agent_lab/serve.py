"""``alab serve``, ``alab stop`` and ``alab status`` (design section 6.5).

``serve`` starts the backend, waits until its model is loaded, then starts the
gateway in front of it (T05); T07 adds the tunnel. ``stop`` stops the gateway
first, so no new request reaches a backend that is going away.
"""

from __future__ import annotations

import time

from agent_lab import config, doctor, paths, pull, registry
from agent_lab.backend import process
from agent_lab.backend.settings import launch_settings
from agent_lab.gateway import keys
from agent_lab.gateway import process as gateway_process

GIB = 1024**3


class ServeError(Exception):
    """``alab serve`` refused to start or the backend failed; the message says why."""


def preflight(profile: config.Profile, force: bool) -> list[str]:
    """Checks before starting (T03's GPU limit, ports, memory). Returns warnings to print.

    Raises ServeError when the backend cannot or should not start; ``force``
    turns a GPU limit that is too low (or unknown) into a warning.
    """
    warnings: list[str] = []
    entry = registry.get_entry(profile.model.id)
    state = pull.local_state(entry)
    if state is not pull.LocalState.DOWNLOADED:
        raise ServeError(
            f"model {entry.id} is {state.value}; run ./alab pull --profile {profile.name}"
        )

    info = doctor.collect_system()
    gpu = doctor.check_gpu_limit(info, profile)
    if gpu.status is not doctor.Status.OK:
        if not force:
            raise ServeError(
                f"GPU limit: {gpu.detail}\nrefusing to start; pass --force to start anyway"
            )
        warnings.append(f"GPU limit: {gpu.detail} (starting anyway because of --force)")

    port = profile.backend.port
    if doctor.port_in_use(port):
        if process.status().state is not process.State.STOPPED:
            raise ServeError("another alab serve started the backend meanwhile; see ./alab status")
        owner = doctor.port_owner(port)
        by = f" by {owner}" if owner else ""
        raise ServeError(f"port {port} is already in use{by}")

    for check in doctor.check_memory_pressure(info, profile):
        if check.status is not doctor.Status.OK:
            warnings.append(f"{check.name}: {check.detail}")
    return warnings


def _gb(n: int | None) -> str:
    return "unknown" if n is None else f"{n / GIB:.2f} GB"


def _uptime(started_at: float) -> str:
    seconds = int(time.time() - started_at)
    return f"{seconds // 3600}h{seconds // 60 % 60:02d}m{seconds % 60:02d}s"


def describe_gateway(status: gateway_process.Status) -> list[str]:
    """Lines about the gateway for ``alab status`` and the end of ``alab serve``."""
    record = status.record
    if record is None:
        return ["gateway: not running"]
    lines = [f"gateway: {status.state.value} (pid {record.pid}, port {record.port})"]
    if status.state is process.State.EXITED:
        lines.append("  run ./alab stop to clear it, then ./alab serve to start again")
    else:
        name = (status.ready or {}).get("model_name", "?")
        lines.append(f"  url: http://127.0.0.1:{record.port}/v1 (model {name})")
        lines.append(f"  uptime: {_uptime(record.started_at)}")
        if status.queue is not None:
            lines.append(
                f"  queue: {status.queue.get('active', 0)} running, "
                f"{status.queue.get('waiting', 0)} waiting"
            )
    lines.append(f"  log: {paths.gateway_log()}")
    if status.state in {process.State.EXITED, process.State.UNHEALTHY}:
        tail = process.log_tail(paths.gateway_log(), 10) or process.log_tail(
            paths.gateway_console_log(), 10
        )
        if tail:
            lines.append("  last log lines:")
            lines.extend(f"    {line}" for line in tail)
    return lines


def describe(status: process.Status) -> list[str]:
    """Lines about the backend for ``alab status`` and the end of ``alab serve``."""
    record = status.record
    if record is None:
        return ["backend: not running"]
    lines = [
        f"backend: {status.state.value} (pid {record.pid}, port {record.port}, "
        f"model {record.model}, profile {record.profile})"
    ]
    if status.state is process.State.EXITED:
        lines.append("  run ./alab stop to clear it, then ./alab serve to start again")
    else:
        lines.append(f"  uptime: {_uptime(record.started_at)}")
        memory = status.memory or {}
        lines.append(
            f"  memory: Metal {_gb(memory.get('active_bytes'))} in use, "
            f"peak {_gb(memory.get('peak_bytes'))}; process RSS {_gb(status.rss_bytes)} "
            "(RSS leaves out most Metal buffers)"
        )
    if status.ready:
        ready = status.ready
        lines.append(
            f"  loaded in {ready.get('load_seconds')}s with mlx-lm {ready.get('mlx_lm')} "
            f"(MLX {ready.get('mlx')}); Metal memory after load "
            f"{_gb(ready.get('metal_active_bytes'))}; tool parser {ready.get('tool_parser')}"
        )
    lines.append(f"  log: {paths.backend_log()}")
    if status.state in {process.State.EXITED, process.State.UNHEALTHY}:
        tail = process.log_tail(paths.backend_log(), 10)
        if tail:
            lines.append("  last log lines:")
            lines.extend(f"    {line}" for line in tail)
        console = process.log_tail(paths.backend_console_log(), 10)
        if console:
            lines.append(f"  console output ({paths.backend_console_log()}):")
            lines.extend(f"    {line}" for line in console)
    return lines


def _start_backend(profile: config.Profile, force: bool) -> list[str]:
    current = process.status()
    if current.state in {process.State.RUNNING, process.State.LOADING, process.State.UNHEALTHY}:
        assert current.record is not None
        return [
            f"the backend is already {current.state.value} (pid {current.record.pid}); "
            "not starting another",
            *describe(current),
        ]
    for warning in preflight(profile, force):
        print(f"warning: {warning}")
    settings = launch_settings(profile)
    print(f"starting the backend for {settings.model_id} on {settings.url} ...")
    started = time.monotonic()
    try:
        status, created = process.start(
            settings, profile.backend.start_timeout_seconds, progress=print
        )
    except process.BackendError as exc:
        raise ServeError(str(exc)) from exc
    if not created:
        return ["another alab serve started the backend first", *describe(status)]
    return [f"backend ready after {time.monotonic() - started:.1f}s", *describe(status)]


def _start_gateway(profile: config.Profile) -> list[str]:
    current = gateway_process.status()
    if current.state in {process.State.RUNNING, process.State.LOADING, process.State.UNHEALTHY}:
        assert current.record is not None
        return [
            f"the gateway is already {current.state.value} (pid {current.record.pid}); "
            "not starting another",
            *describe_gateway(current),
        ]
    port = profile.gateway.port
    if doctor.port_in_use(port):
        owner = doctor.port_owner(port)
        by = f" by {owner}" if owner else ""
        raise ServeError(f"port {port} is already in use{by}; the gateway cannot start")
    print(f"starting the gateway on http://127.0.0.1:{port} ...")
    started = time.monotonic()
    try:
        status, created = gateway_process.start(profile.name, port, profile.gateway.model_name)
    except process.BackendError as exc:
        raise ServeError(f"{exc}\nthe backend is still running; ./alab stop stops it") from exc
    if not created:
        return ["another alab serve started the gateway first", *describe_gateway(status)]
    return [f"gateway ready after {time.monotonic() - started:.1f}s", *describe_gateway(status)]


def serve(profile: config.Profile, force: bool = False) -> list[str]:
    """Start the backend, then the gateway, unless they already run. Returns lines to print."""
    try:
        has_keys = bool(keys.load())
    except keys.KeysError as exc:
        raise ServeError(str(exc)) from exc
    if not has_keys:
        raise ServeError(
            "no API key exists yet, so nothing could use the gateway; create one first:\n"
            "  ./alab keys create <name>     (for example: ./alab keys create opencode)"
        )
    lines = _start_backend(profile, force)
    for line in lines:
        print(line)
    return _start_gateway(profile)
