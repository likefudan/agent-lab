"""The benchmark sections (T06 card, scope item 2) and the design's pass criteria (section 10).

Each section returns a JSON-ready dict. Token counts come from the gateway's
usage; prefill and decode speeds come from the backend's own timing, because
a tool call reaches the client only once it is complete (design section 7.4).
"""

from __future__ import annotations

import itertools
import socket
import subprocess
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Any

from agent_lab import macos
from agent_lab.bench import prompts
from agent_lab.bench.client import ChatResult, Client
from agent_lab.bench.prompts import Counter, Prompt

GIB = 1024**3
SWAP_GROWTH_LIMIT = 1 * GIB  # design section 10
COPY_THRESHOLD = 0.5  # a request that holds over half the stored entry again copied it
LSOF = "/usr/sbin/lsof"
NETWORK_PROBE = ("1.1.1.1", 443)
SECTIONS = ("cache", "prefill", "decode", "agent", "sustained", "offline")


@dataclass(frozen=True)
class Plan:
    """How much each section does. ``FULL`` is the device run; ``QUICK`` checks the flow in CI."""

    cache_tokens: int = 16384  # conversation length for the prompt cache copy check
    prefill_lengths: tuple[int, ...] = (1024, 8192, 16384, 24576, 32768)
    decode_lengths: tuple[int, ...] = (256, 1024)
    agent_start_tokens: int = 10240  # system prompt and tool definitions
    agent_step_tokens: int = 1024  # tool result added per round
    agent_round_tokens: int = 256  # max_tokens of each agent request
    agent_rounds: int | None = None  # None: until max_context is full
    agent_runs: int = 3
    sustained_seconds: float = 600.0
    sustained_window_seconds: float = 30.0
    sustained_request_tokens: int = 1024


FULL = Plan()
QUICK = Plan(
    cache_tokens=2048,
    prefill_lengths=(512, 2048, 8192),
    decode_lengths=(64,),
    agent_start_tokens=1024,
    agent_step_tokens=512,
    agent_round_tokens=64,
    agent_runs=1,
    sustained_seconds=20.0,
    sustained_window_seconds=5.0,
    sustained_request_tokens=128,
)


@dataclass(frozen=True)
class Limits:
    max_context: int
    min_output_tokens: int

    @property
    def prompt_budget(self) -> int:
        """The longest prompt the gateway accepts."""
        return self.max_context - self.min_output_tokens


@dataclass
class Context:
    client: Client
    counter: Counter
    limits: Limits
    plan: Plan
    run_id: str  # makes prompts unique to this run
    gpu_limit_bytes: int | None
    gateway_pid: int | None = None
    log: Callable[[str], None] = print


# -- one request -------------------------------------------------------------


def _ratio(numerator: float | None, denominator: float | None) -> float | None:
    if numerator is None or not denominator or denominator <= 0:
        return None
    return numerator / denominator


def request_row(result: ChatResult) -> dict[str, Any]:
    """One request's numbers for the report."""
    backend = result.backend or {}
    prompt = result.prompt_tokens
    cached = result.cached_tokens
    new = None if prompt is None else prompt - max(cached or 0, 0)
    first = backend.get("first_token_seconds")
    total = backend.get("total_seconds")
    generated = backend.get("generated_tokens")
    decode_seconds = None if first is None or total is None else total - first
    memory = result.memory
    return {
        "ok": result.ok,
        "error": result.error,
        "status": result.status,
        "prompt_tokens": prompt,
        "cached_tokens": cached,
        "new_tokens": new,
        "completion_tokens": result.completion_tokens,
        "finish_reason": result.finish_reason,
        "tool_calls": len(result.tool_calls),
        "first_output_seconds": result.first_output_seconds,
        "seconds": result.seconds,
        "prefill_seconds": first,
        "prefill_tokens_per_second": _ratio(new, first),
        "decode_tokens_per_second": _ratio(
            None if not generated else generated - 1, decode_seconds
        ),
        "metal_peak_bytes": backend.get("metal_peak_bytes"),
        "metal_active_before_bytes": backend.get("metal_active_before_bytes"),
        "metal_cache_after_bytes": backend.get("metal_cache_after_bytes"),
        "prompt_cache_before_bytes": backend.get("prompt_cache_before_bytes"),
        "backend_rss_max_bytes": memory.backend_rss_max_bytes,
        "swap_start_bytes": memory.swap_start_bytes,
        "swap_max_bytes": memory.swap_max_bytes,
        "available_min_bytes": memory.available_min_bytes,
        "backend_stats": result.backend is not None,
    }


def _short(text: str) -> str:
    return text if len(text) <= 120 else text[:117] + "..."


def _note(ctx: Context, what: str, row: dict[str, Any]) -> None:
    if not row["ok"]:
        ctx.log(f"  {what}: FAILED: {row['error']}")
        return
    parts = [f"{row['prompt_tokens']} prompt tokens ({row['cached_tokens']} cached)"]
    if row["prefill_seconds"] is not None:
        parts.append(f"prefill {row['prefill_seconds']:.1f}s")
    parts.append(f"{row['completion_tokens']} generated, {row['seconds']:.1f}s total")
    if row["metal_peak_bytes"]:
        parts.append(f"Metal peak {row['metal_peak_bytes'] / GIB:.2f} GB")
    ctx.log(f"  {what}: " + ", ".join(parts))


def _swap_now() -> int | None:
    stats = macos.memory_stats()
    return stats.swap_used_bytes if stats else None


# -- sections ----------------------------------------------------------------


def cache_copy(ctx: Context) -> dict[str, Any]:
    """Scope item 1: does reusing the prompt cache hold a second copy of the KV cache?

    Turn 1 sends a long document; turn 2 continues the same conversation, so
    most of its prompt comes from the cache. If mlx-lm copies the stored entry
    before extending it, turn 2's peak is about one stored entry above the
    memory in use when it started (which already includes the stored entry).
    """
    first = prompts.plain_prompt(f"cache-{ctx.run_id}", ctx.plan.cache_tokens, ctx.counter)
    turn1 = ctx.client.chat(first.messages, max_tokens=64)
    rows = [request_row(turn1)]
    _note(ctx, "turn 1", rows[0])
    result: dict[str, Any] = {"target_tokens": ctx.plan.cache_tokens, "turns": rows}
    if not turn1.ok:
        result["verdict"] = "could not measure: turn 1 failed"
        result["copied"] = None
        return result
    follow_up = {"role": "user", "content": "Name one more detail from it, in one sentence."}
    turn2 = ctx.client.chat([*first.messages, turn1.assistant_message(), follow_up], max_tokens=64)
    rows.append(request_row(turn2))
    _note(ctx, "turn 2", rows[1])
    result.update(_copy_verdict(rows[0], rows[1]))
    return result


def _copy_verdict(turn1: dict[str, Any], turn2: dict[str, Any]) -> dict[str, Any]:
    stored = turn2["prompt_cache_before_bytes"]
    before = turn2["metal_active_before_bytes"]
    peak = turn2["metal_peak_bytes"]
    if not turn2["ok"]:
        return {"copied": None, "verdict": "could not measure: turn 2 failed"}
    if None in (stored, before, peak):
        return {"copied": None, "verdict": "could not measure: no backend statistics"}
    if not turn2["cached_tokens"]:
        return {
            "copied": None,
            "stored_entry_bytes": stored,
            "verdict": "could not measure: turn 2 got no prompt cache hit",
        }
    extra = peak - before
    copied = stored > 0 and extra >= COPY_THRESHOLD * stored
    peak1 = turn1["metal_peak_bytes"]
    verdict = (
        f"turn 2 reused {turn2['cached_tokens']} cached tokens; the stored entry was "
        f"{stored / GIB:.2f} GB and turn 2 peaked {extra / GIB:.2f} GB above the memory in use "
        f"when it started, so the cache is {'copied' if copied else 'not copied'} on reuse"
    )
    return {
        "copied": copied,
        "stored_entry_bytes": stored,
        "turn2_extra_bytes": extra,
        "peak_difference_bytes": None if peak1 is None else peak - peak1,
        "verdict": verdict,
    }


def prefill(ctx: Context) -> dict[str, Any]:
    """Prefill speed and time to first token for each prompt length, with no cache hit."""
    budget = ctx.limits.prompt_budget
    rows = []
    done: set[int] = set()
    for length in ctx.plan.prefill_lengths:
        target = min(length, budget)
        if target in done:
            continue
        done.add(target)
        prompt = prompts.plain_prompt(f"prefill-{length}-{ctx.run_id}", target, ctx.counter)
        row = request_row(ctx.client.chat(prompt.messages, max_tokens=8))
        row["label"] = _k(length)
        row["limited_by_max_context"] = target < length
        _note(ctx, f"{row['label']} prompt", row)
        rows.append(row)
    return {"prompt_budget": budget, "rows": rows}


def _k(tokens: int) -> str:
    return f"{tokens // 1024}K" if tokens % 1024 == 0 else str(tokens)


def decode(ctx: Context) -> dict[str, Any]:
    """Generation speed for long answers to a short prompt."""
    rows = []
    for length in ctx.plan.decode_lengths:
        messages = prompts.long_answer_prompt(f"decode-{length}-{ctx.run_id}")
        row = request_row(ctx.client.chat(messages, max_tokens=length))
        row["requested_tokens"] = length
        _note(ctx, f"{length} tokens", row)
        rows.append(row)
    return {"rows": rows}


def agent(ctx: Context) -> dict[str, Any]:
    """Scope item 2 and the pass criteria: agent conversations that fill max_context.

    Every run starts like a coding agent (system prompt and tool definitions),
    then sends each answer back with a tool result of ``agent_step_tokens``,
    as Cursor and opencode do, until the prompt reaches the gateway's limit.
    All runs share the system prompt, like a client starting a new task.
    """
    swap_start = _swap_now()
    runs = []
    for number in range(1, ctx.plan.agent_runs + 1):
        ctx.log(f" run {number} of {ctx.plan.agent_runs}")
        runs.append(_agent_run(ctx, number))
    return {
        "start_tokens": ctx.plan.agent_start_tokens,
        "step_tokens": ctx.plan.agent_step_tokens,
        "prompt_budget": ctx.limits.prompt_budget,
        "swap_start_bytes": swap_start,
        "runs": runs,
        "checks": _agent_checks(ctx, runs, swap_start),
    }


def _agent_run(ctx: Context, number: int) -> dict[str, Any]:
    seed = f"agent-{ctx.run_id}"
    start = prompts.agent_start(seed, ctx.plan.agent_start_tokens, ctx.counter)
    messages = list(start.messages)
    tools = start.tools
    step_words = max(1, int(ctx.plan.agent_step_tokens / ctx.counter.tokens_per_word()))
    budget = ctx.limits.prompt_budget
    rounds: list[dict[str, Any]] = []
    full = False
    for round_no in itertools.count(1):
        if ctx.plan.agent_rounds is not None and round_no > ctx.plan.agent_rounds:
            break
        result = ctx.client.chat(messages, tools, max_tokens=ctx.plan.agent_round_tokens)
        row = request_row(result)
        row["round"] = round_no
        rounds.append(row)
        _note(ctx, f"round {round_no}", row)
        if not result.ok or full:
            break
        added = _add_tool_results(messages, result, f"{seed}-{number}-{round_no}", step_words)
        tokens = ctx.counter.count(messages, tools)
        if tokens > budget:
            fitted = _fit_last(messages, tools, f"{seed}-{number}-{round_no}-last", budget, ctx)
            if fitted is None:
                del messages[-added:]  # not even an empty result fits: the context is full
                break
            messages = fitted.messages
            full = True
        elif budget - tokens < ctx.plan.agent_step_tokens // 4:
            full = True  # close enough: the next request is the last one
    ok_rounds = [r for r in rounds if r["ok"]]
    final = ok_rounds[-1]["prompt_tokens"] if ok_rounds else None
    peaks = [r["metal_peak_bytes"] for r in rounds if r["metal_peak_bytes"] is not None]
    return {
        "run": number,
        "rounds": rounds,
        "final_prompt_tokens": final,
        "filled": final is not None and final >= budget - ctx.plan.agent_step_tokens,
        "metal_peak_bytes": max(peaks, default=None),
        "errors": [r["error"] for r in rounds if not r["ok"]],
    }


def _add_tool_results(
    messages: list[dict[str, Any]], result: ChatResult, seed: str, step_words: int
) -> int:
    """Append the answer and its tool results (or a user message); return how many were added."""
    messages.append(result.assistant_message())
    calls = result.tool_calls
    if not calls:
        text = "Here is the next file.\n" + prompts.tool_result(seed, step_words)
        messages.append({"role": "user", "content": text})
        return 2
    for i, call in enumerate(calls):
        if not call.get("id"):
            call["id"] = f"call-{seed}-{i}"
        messages.append(
            {
                "role": "tool",
                "tool_call_id": call["id"],
                "content": prompts.tool_result(f"{seed}-{i}", max(1, step_words // len(calls))),
            }
        )
    return 1 + len(calls)


def _fit_last(
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]] | None,
    seed: str,
    budget: int,
    ctx: Context,
) -> Prompt | None:
    """Shorten the last message's tool output so the prompt fills the budget exactly."""
    last = messages[-1]
    prefix = "Here is the next file.\n" if last["role"] == "user" else ""

    def build(n: int) -> Prompt:
        content = prefix + prompts.tool_result(seed, n)
        return Prompt([*messages[:-1], {**last, "content": content}], tools)

    try:
        return prompts.fit(build, budget, ctx.counter)
    except ValueError:
        return None


def _agent_checks(
    ctx: Context, runs: list[dict[str, Any]], swap_start: int | None
) -> list[dict[str, Any]]:
    rounds = [r for run in runs for r in run["rounds"]]
    peaks = [r["metal_peak_bytes"] for r in rounds if r["metal_peak_bytes"] is not None]
    swaps = [r["swap_max_bytes"] for r in rounds if r["swap_max_bytes"] is not None]
    errors = [r["error"] for r in rounds if not r["ok"]]
    checks = [
        {
            "name": f"{len(runs)} conversation(s) filled max_context",
            "ok": bool(runs) and all(run["filled"] for run in runs),
            "detail": ", ".join(str(run["final_prompt_tokens"]) for run in runs)
            + f" of {ctx.limits.prompt_budget} prompt tokens",
        },
        _limit_check(max(peaks, default=None), ctx.gpu_limit_bytes),
    ]
    if swap_start is None or not swaps:
        checks.append({"name": "swap grew less than 1 GB", "ok": None, "detail": "not readable"})
    else:
        growth = max(swaps) - swap_start
        checks.append(
            {
                "name": "swap grew less than 1 GB",
                "ok": growth < SWAP_GROWTH_LIMIT,
                "detail": f"{growth / GIB:+.2f} GB",
            }
        )
    checks.append(
        {
            "name": "no errors",
            "ok": not errors,
            "detail": "; ".join(_short(e or "") for e in errors) or "none",
        }
    )
    return checks


def _limit_check(peak: int | None, limit: int | None) -> dict[str, Any]:
    name = "peak Metal memory under the GPU limit"
    if peak is None or limit is None:
        return {"name": name, "ok": None, "detail": "not measured"}
    return {
        "name": name,
        "ok": peak < limit,
        "detail": f"{peak / GIB:.2f} GB of {limit / GIB:.2f} GB",
    }


def sustained(ctx: Context) -> dict[str, Any]:
    """Generation speed over time under continuous load (fanless throttling)."""
    window = ctx.plan.sustained_window_seconds
    started = time.monotonic()
    tokens: dict[int, float] = {}
    busy: dict[int, float] = {}
    requests = 0
    errors = []
    while time.monotonic() - started < ctx.plan.sustained_seconds:
        sent = time.monotonic() - started
        messages = prompts.long_answer_prompt(f"sustained-{requests}-{ctx.run_id}")
        result = ctx.client.chat(messages, max_tokens=ctx.plan.sustained_request_tokens)
        requests += 1
        if not result.ok:
            errors.append(result.error)
            break
        times = [sent + t for t in result.output_times]
        # A chunk usually carries one token; spread the reported count over the chunks.
        per_chunk = (result.completion_tokens or len(times)) / max(len(times), 1)
        for previous, current in itertools.pairwise(times):
            slot = int(current // window)
            tokens[slot] = tokens.get(slot, 0.0) + per_chunk
            busy[slot] = busy.get(slot, 0.0) + (current - previous)
    rows = [
        {
            "start_seconds": slot * window,
            "tokens": round(tokens[slot]),
            "decode_tokens_per_second": tokens[slot] / busy[slot] if busy[slot] > 0 else None,
        }
        for slot in sorted(tokens)
    ]
    speeds = [r["decode_tokens_per_second"] for r in rows if r["decode_tokens_per_second"]]
    first, last = (speeds[0], speeds[-1]) if speeds else (None, None)
    ctx.log(
        f"  {requests} requests in {time.monotonic() - started:.0f}s"
        + (f", {first:.2f} -> {last:.2f} tok/s" if first and last else "")
    )
    return {
        "seconds": time.monotonic() - started,
        "window_seconds": window,
        "requests": requests,
        "rows": rows,
        "first_window_tokens_per_second": first,
        "last_window_tokens_per_second": last,
        "slowdown": None if not first or last is None else 1 - last / first,
        "errors": errors,
    }


def network_reachable(timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection(NETWORK_PROBE, timeout=timeout):
            return True
    except OSError:
        return False


def outside_connections(pid: int) -> list[str] | None:
    """The process's sockets that are not on the loopback interface, or None if unknown."""
    try:
        result = subprocess.run(
            [LSOF, "-nP", "-a", "-p", str(pid), "-i", "-F", "n"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode not in (0, 1):  # 1: no sockets matched
        return None
    return [
        line[1:]
        for line in result.stdout.splitlines()
        if line.startswith("n") and not _loopback_only(line[1:])
    ]


def _loopback_only(name: str) -> bool:
    """Whether an lsof socket name such as ``127.0.0.1:52000->127.0.0.1:8100`` stays local."""
    for end in name.split("->"):
        host = end.rsplit(":", 1)[0].strip("[]")
        if not (host.startswith("127.") or host in ("::1", "localhost")):
            return False
    return True


def offline(ctx: Context) -> dict[str, Any]:
    """One request, then check that neither process holds a non-loopback socket.

    Run it with the network switched off (and no tunnel) for the card's check;
    with the network up it still shows that inference opens no outside connection.
    """
    network = network_reachable()
    result = ctx.client.chat(
        [{"role": "user", "content": "Reply with the single word: ready."}], max_tokens=16
    )
    row = request_row(result)
    _note(ctx, "request", row)
    pids = {"backend": ctx.client.backend_pid, "gateway": ctx.gateway_pid}
    sockets = {name: outside_connections(pid) for name, pid in pids.items() if pid}
    unknown = [name for name, found in sockets.items() if found is None]
    outside = {name: found for name, found in sockets.items() if found}
    if not row["ok"]:
        verdict = f"the request failed: {row['error']}"
    elif outside:
        verdict = f"non-loopback sockets found: {outside}"
    elif unknown or not sockets:
        verdict = "the request worked, but the sockets could not be checked"
    elif network:
        verdict = (
            "the request worked and only loopback sockets were open; the network was up, "
            "so repeat with it switched off for the full check"
        )
    else:
        verdict = "the request worked with the network off, using only loopback sockets"
    return {
        "network_reachable": network,
        "request": row,
        "outside_sockets": outside,
        "ok": row["ok"] and not outside and not unknown and bool(sockets),
        "verdict": verdict,
    }


RUNNERS: dict[str, Callable[[Context], dict[str, Any]]] = {
    "cache": cache_copy,
    "prefill": prefill,
    "decode": decode,
    "agent": agent,
    "sustained": sustained,
    "offline": offline,
}


def plan_dict(plan: Plan) -> dict[str, Any]:
    return asdict(plan)
