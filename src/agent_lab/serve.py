"""``alab serve``, ``alab stop`` and ``alab status`` (design section 6.5).

In T04 these manage only the inference backend; T05 adds the gateway and T07
the tunnel.
"""

from __future__ import annotations

import time

from agent_lab import config, doctor, paths, pull, registry
from agent_lab.backend import process
from agent_lab.backend.settings import launch_settings

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


def describe(status: process.Status) -> list[str]:
    """Lines for ``alab status`` and the end of ``alab serve``."""
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
        uptime = int(time.time() - record.started_at)
        lines.append(f"  uptime: {uptime // 3600}h{uptime // 60 % 60:02d}m{uptime % 60:02d}s")
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


def serve(profile: config.Profile, force: bool = False) -> list[str]:
    """Start the backend unless it is already running. Returns the lines to print."""
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
