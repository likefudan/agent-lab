from __future__ import annotations

from pathlib import Path

import pytest

from agent_lab import cli, config, doctor, pull, serve
from agent_lab.backend import process
from agent_lab.doctor import Check, Status


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


def test_serve_does_not_start_a_second_backend(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    record = process.Record(123, 8100, "mac-24gb", "qwen3.8-27b-mlx-4bit", 0.0)
    running = process.Status(process.State.RUNNING, record, None, 1024**3)
    monkeypatch.setattr(process, "status", lambda: running)

    def no_start(*args: object, **kwargs: object) -> None:
        raise AssertionError("must not start")

    monkeypatch.setattr(process, "start", no_start)
    lines = serve.serve(config.load_profile())
    assert "already running (pid 123); not starting another" in lines[0]


def test_status_exit_codes(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    assert cli.main(["status"]) == 3
    assert "backend: not running" in capsys.readouterr().out
    record = process.Record(123, 8100, "mac-24gb", "qwen3.8-27b-mlx-4bit", 0.0)
    exited = process.Status(process.State.EXITED, record, None, None)
    monkeypatch.setattr(process, "status", lambda: exited)
    assert cli.main(["status"]) == 1
    out = capsys.readouterr().out
    assert "exited unexpectedly (pid 123" in out
    assert "var/logs/backend.log" in out


def test_stop_when_nothing_runs(lab_home: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["stop"]) == 0
    assert "backend: not running" in capsys.readouterr().out


def test_serve_reports_preflight_errors(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(pull, "local_state", lambda entry: pull.LocalState.NOT_DOWNLOADED)
    assert cli.main(["serve"]) == 1
    assert "alab serve: model qwen3.8-27b-mlx-4bit is not downloaded" in capsys.readouterr().err
