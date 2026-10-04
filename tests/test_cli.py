from __future__ import annotations

from pathlib import Path

import pytest

from agent_lab import __version__, cli, doctor


def test_version(lab_home: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["version"]) == 0
    assert f"agent-lab {__version__}" in capsys.readouterr().out


def test_command_is_required(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as excinfo:
        cli.main([])
    assert excinfo.value.code == 2


def test_doctor_dispatch(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(doctor, "main", lambda: 7)
    assert cli.main(["doctor"]) == 7
    assert (lab_home / "var/secrets").is_dir()
