from __future__ import annotations

import platform
import sys
from pathlib import Path

import pytest

from agent_lab import doctor, paths
from agent_lab.doctor import Status, SystemInfo

GIB = 1024**3
M5 = SystemInfo("Darwin", "arm64", "Apple M5", 24 * GIB, "26.1")


def test_apple_silicon_mac_passes_machine_checks() -> None:
    assert doctor.check_chip(M5).status is Status.OK
    assert doctor.check_memory(M5).status is Status.OK
    assert doctor.check_macos(M5) == doctor.Check("macOS", Status.OK, "26.1")


def test_non_apple_silicon_fails() -> None:
    intel_mac = SystemInfo("Darwin", "x86_64", "Intel Core i7", 16 * GIB, "14.5")
    linux = SystemInfo("Linux", "x86_64", "Xeon", 64 * GIB, "")
    assert doctor.check_chip(intel_mac).status is Status.FAIL
    assert doctor.check_chip(linux).status is Status.FAIL
    assert doctor.check_macos(linux).status is Status.FAIL


@pytest.mark.parametrize(
    ("version", "status"),
    [("13.6.1", Status.FAIL), ("14.0", Status.OK), ("15.7", Status.OK), ("", Status.WARN)],
)
def test_macos_version(version: str, status: Status) -> None:
    info = SystemInfo("Darwin", "arm64", "Apple M1", 8 * GIB, version)
    assert doctor.check_macos(info).status is status


def test_small_memory_warns() -> None:
    ci_runner = SystemInfo("Darwin", "arm64", "Apple M1 (Virtual)", 7 * GIB, "15.5")
    check = doctor.check_memory(ci_runner)
    assert check.status is Status.WARN
    assert check.detail.startswith("7 GB")
    unknown = SystemInfo("Darwin", "arm64", "Apple M1", None, "15.5")
    assert doctor.check_memory(unknown).status is Status.WARN


def test_disk(tmp_path: Path) -> None:
    assert doctor.check_disk(tmp_path, 100 * GIB).status is Status.OK
    low = doctor.check_disk(tmp_path, 5 * GIB)
    assert low.status is Status.WARN
    assert str(tmp_path) in low.detail


def _fake_interpreter(lab_home: Path, monkeypatch: pytest.MonkeyPatch, inside: bool) -> Path:
    """A .venv/bin/python symlink to an interpreter inside (or outside) .tools/python."""
    base = lab_home / ".tools/python" if inside else lab_home / "elsewhere"
    real = base / "cpython/bin/python3"
    real.parent.mkdir(parents=True)
    real.write_text("")
    link = lab_home / ".venv/bin/python"
    link.parent.mkdir(parents=True)
    link.symlink_to(real)
    monkeypatch.setattr(sys, "executable", str(link))
    return real


def test_python_inside_tools(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (lab_home / ".python-version").write_text(platform.python_version() + "\n")
    real = _fake_interpreter(lab_home, monkeypatch, inside=True)
    check = doctor.check_python()
    assert check.status is Status.OK
    assert str(real) in check.detail  # the interpreter path is printed for inspection


def test_python_outside_tools_fails(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (lab_home / ".python-version").write_text(platform.python_version() + "\n")
    _fake_interpreter(lab_home, monkeypatch, inside=False)
    check = doctor.check_python()
    assert check.status is Status.FAIL
    assert "not the Python in .tools/python" in check.detail


def test_python_version_mismatch_fails(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (lab_home / ".python-version").write_text("3.0.0\n")
    _fake_interpreter(lab_home, monkeypatch, inside=True)
    check = doctor.check_python()
    assert check.status is Status.FAIL
    assert "pins 3.0.0" in check.detail


def test_tools_not_installed(lab_home: Path) -> None:
    checks = doctor.check_tools("darwin-arm64")
    assert [c.name for c in checks] == ["uv", "cloudflared"]
    assert all(c.status is Status.FAIL and "./bootstrap.sh" in c.detail for c in checks)
    assert doctor.check_tools(None)[0].status is Status.FAIL


def test_secrets_dir(lab_home: Path) -> None:
    assert doctor.check_secrets_dir().status is Status.FAIL
    paths.ensure_layout()
    assert doctor.check_secrets_dir().status is Status.OK
    paths.secrets_dir().chmod(0o755)
    assert "mode 755" in doctor.check_secrets_dir().detail


def test_profile_check(lab_home: Path) -> None:
    assert doctor.check_profile().status is Status.OK
    (lab_home / "config/profiles/mac-24gb.toml").write_text("[model]\n")
    check = doctor.check_profile()
    assert check.status is Status.FAIL
    assert "missing section [backend]" in check.detail


def test_main_reports_and_exit_code(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    paths.ensure_layout()
    monkeypatch.setattr(doctor, "collect_system", lambda: M5)
    # Tools are not installed in the temporary home, so doctor must fail.
    assert doctor.main() == 1
    out = capsys.readouterr().out
    assert f"AGENT_LAB_HOME={lab_home.resolve()}" in out
    assert "Apple M5 (arm64)" in out
    assert "24 GB" in out
    assert "26.1" in out
    assert "GB free at" in out
    assert "check(s) failed" in out
