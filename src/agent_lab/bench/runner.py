"""Run ``alab bench`` against the service ``alab serve`` started (T06).

The benchmark goes through the gateway like a client, with a temporary API
key that is revoked at the end. Results go to ``var/bench/<timestamp>/``;
the report is rewritten after every section, so an interrupted run keeps
what it measured.
"""

from __future__ import annotations

import dataclasses
import subprocess
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from agent_lab import __version__, config, doctor, gpulimit, macos, paths, pull, registry
from agent_lab.backend import process
from agent_lab.backend.settings import launch_settings
from agent_lab.bench import report, suites
from agent_lab.bench.client import Client
from agent_lab.bench.prompts import Counter
from agent_lab.gateway import keys
from agent_lab.gateway import process as gateway_process
from agent_lab.gateway.tokens import ChatTemplateCounter, PromptCounter
from agent_lab.gateway.translate import THINKING_SWITCH

GIB = 1024**3
MIB = 1024**2


class BenchError(Exception):
    """The benchmark cannot run; the message says why."""


def _git_commit() -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=paths.home(),
            capture_output=True,
            text=True,
            check=True,
        )
    except OSError, subprocess.CalledProcessError:
        return "unknown"
    return result.stdout.strip() or "unknown"


def environment(
    profile: config.Profile, ready: dict[str, Any], plan_name: str, plan: suites.Plan
) -> tuple[dict[str, str], int | None]:
    """What the report records about the machine and the setup, and the GPU limit in bytes."""
    info = doctor.collect_system()
    entry = registry.get_entry(profile.model.id)
    state = gpulimit.read_state()
    effective = state.effective_mb()
    memory = macos.memory_stats()
    backend = profile.backend
    if memory is None:
        at_start = "not readable"
    else:
        used = memory.swap_used_bytes
        swap = "unknown" if used is None else f"{used / GIB:.2f} GB"
        at_start = f"{memory.available_bytes / GIB:.1f} GB available, swap used {swap}"
    env = {
        "date": datetime.now(UTC).strftime("%Y-%m-%d %H:%M"),
        "chip": f"{info.chip} ({info.machine})",
        "memory": "unknown" if info.memory_bytes is None else f"{info.memory_bytes / GIB:.0f} GB",
        "macos": info.macos_version or info.system,
        "agent_lab": f"{__version__} (commit {_git_commit()})",
        "mlx": f"{ready.get('mlx_lm', '?')} / {ready.get('mlx', '?')}",
        "model": f"{entry.id} ({entry.repo}@{entry.revision[:12]})",
        "profile": profile.name,
        "settings": (
            f"max_context {profile.gateway.max_context}, "
            f"min_output_tokens {profile.gateway.min_output_tokens}, "
            f"prompt_cache_size {backend.prompt_cache_size}, "
            f"prompt_cache_bytes {backend.prompt_cache_bytes / GIB:.2f} GB, "
            f"prefill_step_size {backend.prefill_step_size}, "
            f"thinking {'on' if backend.enable_thinking else 'off'}"
        ),
        "gpu_limit": (
            f"iogpu.wired_limit_mb = {state.wired_limit_mb} "
            f"({'unknown' if effective is None else f'{effective} MB'} in force)"
        ),
        "metal_memory_limit": f"{backend.metal_memory_limit / GIB:.2f} GB",
        "memory_at_start": at_start,
        "plan": plan_name + ("" if plan in (suites.FULL, suites.QUICK) else " (adjusted)"),
    }
    return env, None if effective is None else effective * MIB


def _running(profile: config.Profile) -> tuple[process.Status, gateway_process.Status]:
    backend = process.status()
    gateway = gateway_process.status()
    if backend.state is not process.State.RUNNING or gateway.state is not process.State.RUNNING:
        raise BenchError(
            f"the backend is {backend.state.value} and the gateway is {gateway.state.value}; "
            f"start both first: ./alab serve --profile {profile.name}"
        )
    for name, status in (("backend", backend), ("gateway", gateway)):
        assert status.record is not None
        if status.record.profile != profile.name:
            raise BenchError(
                f"the {name} runs profile {status.record.profile}, not {profile.name}; "
                f"run ./alab bench --profile {status.record.profile}, or restart ./alab serve"
            )
    return backend, gateway


def failed_checks(result: dict[str, Any]) -> list[str]:
    """Why the run did not pass: failed sections, failed requests and failed checks."""
    problems = []
    for name, section in result["sections"].items():
        if "failed" in section:
            problems.append(f"{name}: {section['failed']}")
            continue
        for check in section.get("checks", []):
            if check["ok"] is False:
                problems.append(f"{name}: {check['name']}: {check['detail']}")
        if section.get("ok") is False:
            problems.append(f"{name}: {section.get('verdict')}")
        rows = [*section.get("rows", []), *section.get("turns", [])]
        problems += [f"{name}: {r['error']}" for r in rows if not r.get("ok", True)]
        problems += [f"{name}: {e}" for e in section.get("errors", [])]
    return problems


def run(
    profile: config.Profile,
    sections: Sequence[str],
    plan: suites.Plan,
    plan_name: str,
    log: Callable[[str], None] = print,
    counter: PromptCounter | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Run the sections in order; returns the report directory and the report."""
    backend, gateway = _running(profile)
    assert backend.record is not None and gateway.record is not None
    stamp = datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
    directory = paths.bench_dir() / stamp
    log("loading the tokenizer to size the prompts ...")
    counter = counter or ChatTemplateCounter(pull.model_dir(profile.model.id))
    template_args = {THINKING_SWITCH: profile.backend.enable_thinking}
    env, gpu_limit = environment(profile, backend.ready or {}, plan_name, plan)
    result: dict[str, Any] = {
        "environment": env,
        "gpu_limit_bytes": gpu_limit,
        "plan": dataclasses.asdict(plan),
        "sections": {},
    }
    key_name = f"bench-{stamp}"
    key = keys.create(key_name)
    client = Client(
        f"http://127.0.0.1:{gateway.record.port}",
        launch_settings(profile).url,
        key,
        profile.gateway.model_name,
        backend_pid=backend.record.pid,
    )
    ctx = suites.Context(
        client=client,
        counter=Counter(counter, template_args),
        limits=suites.Limits(profile.gateway.max_context, profile.gateway.min_output_tokens),
        plan=plan,
        run_id=stamp,
        gpu_limit_bytes=gpu_limit,
        gateway_pid=gateway.record.pid,
        log=log,
    )
    try:
        for name in sections:
            log(f"== {name}")
            try:
                result["sections"][name] = suites.RUNNERS[name](ctx)
            except Exception as exc:  # keep the other sections' results
                result["sections"][name] = {"failed": f"{type(exc).__name__}: {exc}"}
                log(f"  the section failed: {type(exc).__name__}: {exc}")
            report.write(result, directory)
    finally:
        client.close()
        keys.revoke(key_name)
        report.write(result, directory)
    return directory, result
