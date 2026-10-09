from __future__ import annotations

from pathlib import Path

import pytest

from agent_lab import cli, config, doctor, pull, serve
from agent_lab.backend import process
from agent_lab.doctor import Check, Status
from agent_lab.gateway import keys
from agent_lab.gateway import process as gateway_process


@pytest.fixture
def ready_machine(monkeypatch: pytest.MonkeyPatch) -> None:
    """A machine where every preflight check passes."""
    monkeypatch.setattr(pull, "local_state", lambda entry: pull.LocalState.DOWNLOADED)
    monkeypatch.setattr(
        doctor, "check_gpu_limit", lambda info, p: Check("GPU limit", Status.OK, "ok")
    )
    monkeypatch.setattr(doctor, "port_in_use", lambda port: False)
    monkeypatch.setattr(
        doctor, "check_memory_pressure", lambda info, p: [Check("free memory", Status.OK, "ok")]
    )


def test_preflight_passes(lab_home: Path, ready_machine: None) -> None:
    assert serve.preflight(config.load_profile(), force=False) == []


def test_model_must_be_downloaded(
    lab_home: Path, ready_machine: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(pull, "local_state", lambda entry: pull.LocalState.INCOMPLETE)
    with pytest.raises(
        serve.ServeError, match=r"is incomplete; run \./alab pull --profile mac-24gb"
    ):
        serve.preflight(config.load_profile(), force=False)


def test_low_gpu_limit_refuses_unless_forced(
    lab_home: Path, ready_machine: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    low = Check("GPU limit", Status.WARN, "system default, Metal recommends 18186 MB, below ...")
    monkeypatch.setattr(doctor, "check_gpu_limit", lambda info, p: low)
    profile = config.load_profile()
    with pytest.raises(serve.ServeError, match="refusing to start; pass --force"):
        serve.preflight(profile, force=False)
    warnings = serve.preflight(profile, force=True)
    assert len(warnings) == 1 and "--force" in warnings[0]


def test_port_in_use_refuses(
    lab_home: Path, ready_machine: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(doctor, "port_in_use", lambda port: True)
    monkeypatch.setattr(doctor, "port_owner", lambda port: "ollama (pid 42)")
    with pytest.raises(serve.ServeError, match="port 8100 is already in use by ollama"):
        serve.preflight(config.load_profile(), force=True)


def test_low_memory_only_warns(
    lab_home: Path, ready_machine: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    low = [Check("free memory", Status.WARN, "8.8 GB available"), Check("swap", Status.OK, "0")]
    monkeypatch.setattr(doctor, "check_memory_pressure", lambda info, p: low)
    assert serve.preflight(config.load_profile(), force=False) == ["free memory: 8.8 GB available"]


def no_start(*args: object, **kwargs: object) -> None:
    raise AssertionError("must not start")


def test_serve_does_not_start_a_second_backend_or_gateway(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    keys.create("test")
    record = process.Record(123, 8100, "mac-24gb", "qwen3.8-27b-mlx-4bit", 0.0)
    running = process.Status(process.State.RUNNING, record, None, 1024**3)
    monkeypatch.setattr(process, "status", lambda: running)
    monkeypatch.setattr(process, "start", no_start)
    gateway_record = process.Record(124, 8000, "mac-24gb", "qwen3.8-27b", 0.0)
    gateway = gateway_process.Status(
        process.State.RUNNING, gateway_record, {}, {"active": 1, "waiting": 2}
    )
    monkeypatch.setattr(gateway_process, "status", lambda: gateway)
    monkeypatch.setattr(gateway_process, "start", no_start)
    lines = serve.serve(config.load_profile())
    assert "backend is already running (pid 123); not starting another" in capsys.readouterr().out
    assert "gateway is already running (pid 124); not starting another" in lines[0]
    assert "  queue: 1 running, 2 waiting" in lines


def test_serve_refuses_a_backend_with_another_profile(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    keys.create("test")
    record = process.Record(123, 8100, "ci-tiny", "qwen3-0.6b-mlx-4bit", 0.0)
    running = process.Status(process.State.RUNNING, record, None, None)
    monkeypatch.setattr(process, "status", lambda: running)
    monkeypatch.setattr(gateway_process, "start", no_start)
    with pytest.raises(serve.ServeError, match="the backend runs profile ci-tiny, not mac-24gb"):
        serve.serve(config.load_profile())


def test_stop_tries_the_backend_when_the_gateway_fails(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def stuck(timeout: float = 0) -> None:
        raise process.BackendError("pid 9 did not exit after SIGKILL")

    stopped: list[bool] = []

    def stop_backend() -> tuple[None, bool]:
        stopped.append(True)
        return None, False

    monkeypatch.setattr(gateway_process, "stop", stuck)
    monkeypatch.setattr(process, "stop", stop_backend)
    assert cli.main(["stop"]) == 1
    assert stopped == [True]
    assert "gateway: pid 9 did not exit" in capsys.readouterr().err


def test_serve_refuses_without_a_key(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(process, "start", no_start)
    with pytest.raises(serve.ServeError, match=r"(?s)no API key exists yet.*alab keys create"):
        serve.serve(config.load_profile())


def test_gateway_port_in_use_refuses(
    lab_home: Path, ready_machine: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    keys.create("test")
    record = process.Record(123, 8100, "mac-24gb", "qwen3.8-27b-mlx-4bit", 0.0)
    monkeypatch.setattr(
        process, "status", lambda: process.Status(process.State.RUNNING, record, None, None)
    )
    monkeypatch.setattr(doctor, "port_in_use", lambda port: port == 8000)
    monkeypatch.setattr(doctor, "port_owner", lambda port: "nginx (pid 7)")
    monkeypatch.setattr(gateway_process, "start", no_start)
    with pytest.raises(serve.ServeError, match="port 8000 is already in use by nginx"):
        serve.serve(config.load_profile())


def test_status_exit_codes(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    assert cli.main(["status"]) == 3
    out = capsys.readouterr().out
    assert "backend: not running" in out and "gateway: not running" in out
    record = process.Record(123, 8100, "mac-24gb", "qwen3.8-27b-mlx-4bit", 0.0)
    exited = process.Status(process.State.EXITED, record, None, None)
    monkeypatch.setattr(process, "status", lambda: exited)
    assert cli.main(["status"]) == 1
    out = capsys.readouterr().out
    assert "exited unexpectedly (pid 123" in out
    assert "var/logs/backend.log" in out


def test_status_backend_without_gateway_is_a_problem(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    record = process.Record(123, 8100, "mac-24gb", "qwen3.8-27b-mlx-4bit", 0.0)
    running = process.Status(process.State.RUNNING, record, None, None)
    monkeypatch.setattr(process, "status", lambda: running)
    assert cli.main(["status"]) == 1
    assert "gateway: not running" in capsys.readouterr().out


def test_stop_when_nothing_runs(lab_home: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["stop"]) == 0
    out = capsys.readouterr().out
    assert out.splitlines() == ["gateway: not running", "backend: not running"]


def test_serve_reports_preflight_errors(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    keys.create("test")
    monkeypatch.setattr(pull, "local_state", lambda entry: pull.LocalState.NOT_DOWNLOADED)
    assert cli.main(["serve"]) == 1
    assert "alab serve: model qwen3.8-27b-mlx-4bit is not downloaded" in capsys.readouterr().err
