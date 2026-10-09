"""The benchmark report: everything as JSON, and a Markdown summary for people.

The Markdown file is what gets committed to ``docs/benchmarks/`` (T06 card,
scope item 6); the JSON keeps every request's numbers for later comparison.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any

GIB = 1024**3


def _gb(value: Any) -> str:
    return "-" if value is None else f"{value / GIB:.2f} GB"


def _seconds(value: Any) -> str:
    return "-" if value is None else f"{value:.1f}s"


def _rate(value: Any) -> str:
    return "-" if value is None else f"{value:.1f}"


def _int(value: Any) -> str:
    return "-" if value is None else str(value)


def _check(ok: Any) -> str:
    return {True: "PASS", False: "FAIL"}.get(ok, "n/a")


def _table(headers: list[str], rows: Iterable[list[str]]) -> list[str]:
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    return lines


def _swap_growth(row: dict[str, Any], start: int | None) -> str:
    if start is None or row.get("swap_max_bytes") is None:
        return "-"
    return f"{(row['swap_max_bytes'] - start) / GIB:+.2f} GB"


def _environment(env: dict[str, Any]) -> list[str]:
    labels = [
        ("Date (UTC)", "date"),
        ("Chip", "chip"),
        ("Memory", "memory"),
        ("macOS", "macos"),
        ("agent-lab", "agent_lab"),
        ("mlx-lm / MLX", "mlx"),
        ("Model", "model"),
        ("Profile", "profile"),
        ("Profile settings", "settings"),
        ("GPU wired limit", "gpu_limit"),
        ("Metal memory limit (watchdog)", "metal_memory_limit"),
        ("Memory at start", "memory_at_start"),
        ("Plan", "plan"),
    ]
    return _table(["Item", "Value"], ([label, str(env.get(key, "-"))] for label, key in labels))


def _cache(section: dict[str, Any]) -> list[str]:
    tokens = section["target_tokens"]
    lines = [f"Conversation of about {tokens} tokens, then one follow-up turn.", ""]
    lines += _table(
        ["Turn", "Prompt", "Cached", "Prefill", "Stored entry", "Metal before", "Metal peak"],
        (
            [
                str(i),
                _int(r["prompt_tokens"]),
                _int(r["cached_tokens"]),
                _seconds(r["prefill_seconds"]),
                _gb(r["prompt_cache_before_bytes"]),
                _gb(r["metal_active_before_bytes"]),
                _gb(r["metal_peak_bytes"]),
            ]
            for i, r in enumerate(section["turns"], start=1)
        ),
    )
    lines += ["", f"**Result:** {section['verdict']}."]
    return lines


def _prefill(section: dict[str, Any]) -> list[str]:
    lines = _table(
        [
            "Prompt",
            "Tokens",
            "Cached",
            "Time to first token",
            "Prefill",
            "Prefill tok/s",
            "Stored entry",
            "Metal before",
            "Metal peak",
            "Swap",
        ],
        (
            [
                r["label"] + (" (capped)" if r["limited_by_max_context"] else ""),
                _int(r["prompt_tokens"]),
                _int(r["cached_tokens"]),
                _seconds(r["first_output_seconds"]),
                _seconds(r["prefill_seconds"]),
                _rate(r["prefill_tokens_per_second"]),
                _gb(r["prompt_cache_before_bytes"]),
                _gb(r["metal_active_before_bytes"]),
                _gb(r["metal_peak_bytes"]),
                _gb(r["swap_max_bytes"]),
            ]
            for r in section["rows"]
        ),
    )
    lines += [
        "",
        f"Prompts longer than the gateway allows ({section['prompt_budget']} tokens: "
        "max_context minus min_output_tokens) are capped to that length.",
    ]
    return lines


def _decode(section: dict[str, Any]) -> list[str]:
    return _table(
        ["Requested", "Generated", "Finish", "Time to first token", "Decode tok/s", "Total"],
        (
            [
                str(r["requested_tokens"]),
                _int(r["completion_tokens"]),
                _int(r["finish_reason"]),
                _seconds(r["first_output_seconds"]),
                _rate(r["decode_tokens_per_second"]),
                _seconds(r["seconds"]),
            ]
            for r in section["rows"]
        ),
    )


def _agent(section: dict[str, Any]) -> list[str]:
    lines = [
        f"Each run starts with a system prompt and tool definitions of about "
        f"{section['start_tokens']} tokens, then sends every answer back with a tool result "
        f"of about {section['step_tokens']} tokens until the prompt reaches "
        f"{section['prompt_budget']} tokens.",
        "",
        "Pass criteria (design section 10):",
        "",
    ]
    lines += _table(
        ["Check", "Result", "Detail"],
        ([c["name"], _check(c["ok"]), c["detail"]] for c in section["checks"]),
    )
    start = section["swap_start_bytes"]
    for run in section["runs"]:
        lines += ["", f"#### Run {run['run']}", ""]
        lines += _table(
            [
                "Round",
                "Prompt",
                "Cached",
                "New",
                "Prefill",
                "Generated",
                "Tool calls",
                "Total",
                "Metal peak",
                "Swap growth",
            ],
            (
                [
                    str(r["round"]),
                    _int(r["prompt_tokens"]),
                    _int(r["cached_tokens"]),
                    _int(r["new_tokens"]),
                    _seconds(r["prefill_seconds"]),
                    _int(r["completion_tokens"]),
                    str(r["tool_calls"]),
                    _seconds(r["seconds"]) + ("" if r["ok"] else f" FAILED: {r['error']}"),
                    _gb(r["metal_peak_bytes"]),
                    _swap_growth(r, start),
                ]
                for r in run["rounds"]
            ),
        )
    return lines


def _sustained(section: dict[str, Any]) -> list[str]:
    lines = [
        f"{section['requests']} requests back to back for {section['seconds']:.0f}s; "
        f"decode speed per {section['window_seconds']:.0f}-second window.",
        "",
    ]
    lines += _table(
        ["From", "Tokens", "Decode tok/s"],
        (
            [f"{r['start_seconds']:.0f}s", str(r["tokens"]), _rate(r["decode_tokens_per_second"])]
            for r in section["rows"]
        ),
    )
    if section["slowdown"] is not None:
        lines += [
            "",
            f"First window {section['first_window_tokens_per_second']:.2f} tok/s, last "
            f"{section['last_window_tokens_per_second']:.2f} tok/s "
            f"({section['slowdown']:.0%} slower).",
        ]
    if section["errors"]:
        lines += ["", "Errors: " + "; ".join(map(str, section["errors"]))]
    return lines


def _offline(section: dict[str, Any]) -> list[str]:
    return [
        f"Network reachable during the check: {'yes' if section['network_reachable'] else 'no'}.",
        "",
        f"**Result:** {_check(section['ok'])}: {section['verdict']}.",
    ]


RENDERERS: dict[str, tuple[str, Callable[[dict[str, Any]], list[str]]]] = {
    "cache": ("Prompt cache reuse (does it copy the KV cache?)", _cache),
    "prefill": ("Prefill and time to first token", _prefill),
    "decode": ("Decode speed", _decode),
    "agent": ("Agent simulation", _agent),
    "sustained": ("Sustained generation", _sustained),
    "offline": ("Offline request", _offline),
}


def render_markdown(report: dict[str, Any]) -> str:
    env = report["environment"]
    lines = [f"# Benchmark: {env.get('profile', '?')}, {env.get('date', '?')}", ""]
    lines += ["## Environment", "", *_environment(env)]
    for name, section in report["sections"].items():
        title, render = RENDERERS[name]
        lines += ["", f"## {title}", ""]
        if "failed" in section:
            lines.append(f"The section failed: {section['failed']}")
        else:
            lines += render(section)
    return "\n".join(lines) + "\n"


def write(report: dict[str, Any], directory: Path) -> tuple[Path, Path]:
    directory.mkdir(parents=True, exist_ok=True)
    json_path = directory / "report.json"
    md_path = directory / "report.md"
    json_path.write_text(json.dumps(report, indent=2) + "\n")
    md_path.write_text(render_markdown(report))
    return json_path, md_path
