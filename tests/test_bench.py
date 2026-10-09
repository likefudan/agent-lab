"""``alab bench``: prompt sizing, the sections against a fake backend, and the report."""

from __future__ import annotations

import argparse
import dataclasses
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

from agent_lab import config
from agent_lab.bench import prompts, report, runner, suites
from agent_lab.bench.client import ChatResult, Client, MemorySamples
from agent_lab.cli import _sections
from agent_lab.gateway import keys
from tests.gateway_fakes import MODEL, FakeBackend, Running, WordCounter, running_gateway

GIB = 1024**3

PLAN = suites.Plan(
    cache_tokens=200,
    prefill_lengths=(100, 400, 2000),
    decode_lengths=(5,),
    agent_start_tokens=200,
    agent_step_tokens=100,
    agent_round_tokens=10,
    agent_runs=2,
    sustained_seconds=0.3,
    sustained_window_seconds=0.1,
    sustained_request_tokens=5,
)


def counter() -> prompts.Counter:
    return prompts.Counter(WordCounter())


def test_filler_is_deterministic_and_seeded() -> None:
    assert prompts.filler("a", 50) == prompts.filler("a", 50)
    assert prompts.filler("a", 50) != prompts.filler("b", 50)
    assert len(prompts.filler("a", 50).split()) == 50
    assert len(prompts.file_listing("a", 25).splitlines()) == 3


@pytest.mark.parametrize("target", [50, 333, 4000])
def test_fit_lands_just_under_the_target(target: int) -> None:
    prompt = prompts.plain_prompt("x", target, counter())
    assert target - 8 <= prompt.tokens <= target
    assert prompt.tokens == WordCounter().count(prompt.messages, None, {})


def test_fit_refuses_a_target_below_the_empty_prompt() -> None:
    with pytest.raises(ValueError, match="even an empty prompt"):
        prompts.agent_start("x", 5, counter())


def test_agent_start_has_tools_and_the_target_length() -> None:
    prompt = prompts.agent_start("x", 500, counter())
    assert prompt.tools == prompts.AGENT_TOOLS
    assert [m["role"] for m in prompt.messages] == ["system", "user"]
    assert 492 <= prompt.tokens <= 500


@pytest.fixture
def run(lab_home: Path) -> Iterator[Running]:
    backend = FakeBackend(pieces=["Reading", " the", " file", "."], chunk_seconds=0.01)
    with running_gateway(backend, max_context=1000) as running:
        yield running


def context(run: Running, plan: suites.Plan = PLAN) -> suites.Context:
    client = Client(run.url, run.backend_url, keys.create("bench"), MODEL)
    return suites.Context(
        client=client,
        counter=counter(),
        limits=suites.Limits(max_context=1000, min_output_tokens=50),
        plan=plan,
        run_id="test",
        gpu_limit_bytes=20 * GIB,
        log=lambda line: None,
    )


def test_all_sections_against_the_fake_backend(run: Running) -> None:
    run.backend.tool_calls = [{"name": "read_file", "arguments": '{"path": "src/cache.py"}'}]
    ctx = context(run)
    sections: dict[str, Any] = {name: suites.RUNNERS[name](ctx) for name in suites.SECTIONS}
    result: dict[str, Any] = {"environment": {"profile": "test"}, "sections": sections}

    turns = sections["cache"]["turns"]
    assert [t["ok"] for t in turns] == [True, True]
    assert 192 <= turns[0]["prompt_tokens"] <= 200
    assert turns[1]["prompt_tokens"] > turns[0]["prompt_tokens"]
    # The fake backend never reports cached tokens, so there is nothing to compare.
    assert sections["cache"]["copied"] is None

    rows = sections["prefill"]["rows"]
    assert [r["label"] for r in rows] == ["100", "400", "2000"]
    assert [r["limited_by_max_context"] for r in rows] == [False, False, True]
    assert 942 <= rows[2]["prompt_tokens"] <= 950
    assert rows[0]["prefill_tokens_per_second"] == pytest.approx(rows[0]["prompt_tokens"] / 0.01)
    assert all(r["metal_peak_bytes"] == 2 * GIB for r in rows)

    [decode] = sections["decode"]["rows"]
    assert decode["completion_tokens"] == 4
    assert decode["decode_tokens_per_second"] == pytest.approx(3 / 0.04)

    agent = sections["agent"]
    assert len(agent["runs"]) == 2
    for agent_run in agent["runs"]:
        assert agent_run["filled"] and not agent_run["errors"]
        assert 900 <= agent_run["final_prompt_tokens"] <= 950
        assert all(r["tool_calls"] == 1 for r in agent_run["rounds"])
        prompts_sent = [r["prompt_tokens"] for r in agent_run["rounds"]]
        assert prompts_sent == sorted(prompts_sent) and len(prompts_sent) >= 6
    checks = {c["name"]: c["ok"] for c in agent["checks"]}
    assert checks["2 conversation(s) filled max_context"] is True
    assert checks["peak Metal memory under the GPU limit"] is True
    assert checks["no errors"] is True
    # The agent sent its answers back with tool results, as a client does.
    agent_bodies = [b for b in run.backend.requests if b.get("tools")]
    assert any(m["role"] == "tool" for m in agent_bodies[-1]["messages"])
    assert agent_bodies[-1]["messages"][2]["tool_calls"][0]["function"]["name"] == "read_file"

    sustained = sections["sustained"]
    assert sustained["requests"] >= 1 and sustained["rows"]
    assert not sustained["errors"]

    offline = sections["offline"]
    assert offline["request"]["ok"]
    assert offline["ok"] is False  # no pids to check in this test
    assert "could not be checked" in offline["verdict"]

    markdown = report.render_markdown(result)
    for title, _ in report.RENDERERS.values():
        assert f"## {title}" in markdown
    assert "| no errors | PASS | none |" in markdown
    problems = runner.failed_checks(result)
    assert problems == ["offline: the request worked, but the sockets could not be checked"]


def test_agent_without_tool_calls_sends_user_messages(run: Running) -> None:
    ctx = context(run, dataclasses.replace(PLAN, agent_runs=1))
    agent = suites.agent(ctx)
    assert agent["runs"][0]["filled"]
    roles = [m["role"] for m in run.backend.requests[-1]["messages"]]
    assert roles[:2] == ["system", "user"] and "tool" not in roles
    assert roles[2:4] == ["assistant", "user"]


def test_failed_requests_are_reported(run: Running) -> None:
    run.backend.status = 500
    ctx = context(run, dataclasses.replace(PLAN, agent_runs=1))
    agent = suites.agent(ctx)
    [agent_run] = agent["runs"]
    assert len(agent_run["rounds"]) == 1 and agent_run["errors"]
    checks = {c["name"]: c["ok"] for c in agent["checks"]}
    assert checks["no errors"] is False
    assert checks["1 conversation(s) filled max_context"] is False
    cache = suites.cache_copy(ctx)
    assert cache["copied"] is None and "turn 1 failed" in cache["verdict"]


def row(**values: Any) -> dict[str, Any]:
    base = suites.request_row(ChatResult(status=200, seconds=1.0, first_output_seconds=0.5))
    return {**base, **values}


def test_copy_verdict() -> None:
    turn1 = row(metal_peak_bytes=17 * GIB)
    copied = suites._copy_verdict(
        turn1,
        row(
            cached_tokens=16000,
            prompt_cache_before_bytes=1 * GIB,
            metal_active_before_bytes=16 * GIB,
            metal_peak_bytes=int(17.1 * GIB),
        ),
    )
    assert copied["copied"] is True
    assert copied["turn2_extra_bytes"] == pytest.approx(1.1 * GIB, rel=0.01)
    assert "is copied on reuse" in copied["verdict"]
    shared = suites._copy_verdict(
        turn1,
        row(
            cached_tokens=16000,
            prompt_cache_before_bytes=1 * GIB,
            metal_active_before_bytes=16 * GIB,
            metal_peak_bytes=int(16.2 * GIB),
        ),
    )
    assert shared["copied"] is False and "not copied" in shared["verdict"]
    miss = suites._copy_verdict(
        turn1,
        row(
            cached_tokens=0,
            prompt_cache_before_bytes=GIB,
            metal_active_before_bytes=GIB,
            metal_peak_bytes=GIB,
        ),
    )
    assert miss["copied"] is None and "no prompt cache hit" in miss["verdict"]


def test_swap_growth_check_uses_the_section_start() -> None:
    ctx = argparse.Namespace(limits=suites.Limits(1000, 50), gpu_limit_bytes=None)
    rounds = [row(swap_max_bytes=int(1.5 * GIB))]
    runs = [{"rounds": rounds, "filled": True, "final_prompt_tokens": 950}]
    checks = {c["name"]: c for c in suites._agent_checks(ctx, runs, swap_start=GIB)}  # type: ignore[arg-type]
    assert checks["swap grew less than 1 GB"]["ok"] is True
    assert checks["swap grew less than 1 GB"]["detail"] == "+0.50 GB"
    assert checks["peak Metal memory under the GPU limit"]["ok"] is None
    checks = {c["name"]: c for c in suites._agent_checks(ctx, runs, swap_start=0)}  # type: ignore[arg-type]
    assert checks["swap grew less than 1 GB"]["ok"] is False


@pytest.mark.parametrize(
    ("name", "local"),
    [
        ("127.0.0.1:8100", True),
        ("127.0.0.1:52000->127.0.0.1:8100", True),
        ("[::1]:8000", True),
        ("*:8000", False),
        ("192.168.1.5:52000->104.16.0.1:443", False),
        ("127.0.0.1:52000->18.1.2.3:443", False),
    ],
)
def test_loopback_only(name: str, local: bool) -> None:
    assert suites._loopback_only(name) is local


def test_memory_samples() -> None:
    samples = MemorySamples()
    samples.add(None, None, None)
    assert samples == MemorySamples()
    samples.add(100, 50, 7)
    samples.add(300, 20, 5)
    samples.add(200, 40, None)
    assert (samples.swap_start_bytes, samples.swap_max_bytes) == (100, 300)
    assert samples.available_min_bytes == 20
    assert samples.backend_rss_max_bytes == 7


def test_sections_argument() -> None:
    assert _sections("offline,cache") == ["cache", "offline"]
    with pytest.raises(argparse.ArgumentTypeError, match="unknown section bogus"):
        _sections("cache,bogus")


def test_bench_needs_a_running_service(lab_home: Path) -> None:
    with pytest.raises(runner.BenchError, match="start both first"):
        runner.run(config.load_profile("ci-tiny"), ["offline"], suites.QUICK, "quick")
    assert not keys.load()  # no key was left behind


def test_sections_after_the_backend_stops_are_skipped(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    record = argparse.Namespace(pid=1, port=8000)
    status = argparse.Namespace(record=record, ready={})
    monkeypatch.setattr(runner, "_running", lambda profile: (status, status))
    monkeypatch.setattr(runner, "environment", lambda *args: ({"profile": "ci-tiny"}, None))
    ran: list[str] = []

    def section(name: str) -> Any:
        def run(ctx: suites.Context) -> dict[str, Any]:
            ran.append(name)
            return {"failed": f"{name} ran"}  # renders without numbers

        return run

    monkeypatch.setattr(suites, "RUNNERS", {name: section(name) for name in suites.SECTIONS})
    alive = iter([True, False])
    directory, result = runner.run(
        config.load_profile("ci-tiny"),
        ["cache", "prefill", "decode"],
        suites.QUICK,
        "quick",
        log=lambda line: None,
        counter=WordCounter(),
        backend_alive=lambda: next(alive, False),
    )
    assert ran == ["cache"]
    assert result["sections"]["prefill"] == {"failed": "skipped: the backend is no longer running"}
    assert (directory / "report.md").exists()
    assert runner.failed_checks(result)[1].startswith("prefill: skipped")
    assert not keys.load()  # the temporary key was revoked
