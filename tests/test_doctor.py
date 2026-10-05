from __future__ import annotations

import platform
import socket
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from agent_lab import config, doctor, gpulimit, macos, paths
from agent_lab.doctor import Status, SystemInfo
from agent_lab.gpulimit import LimitState, MetalInfo
from agent_lab.macos import MemoryStats

GIB = 1024**3
M5 = SystemInfo("Darwin", "arm64", "Apple M5", 24 * GIB, "26.1")


def test_apple_silicon_mac_passes_machine_checks() -> None:
    assert doctor.check_chip(M5).status is Status.OK
    assert doctor.check_memory(M5).status is Status.OK
    assert doctor.check_macos(M5) == doctor.Check("macOS", Status.OK, "26.1")


def test_collect_system_on_macos(monkeypatch: pytest.MonkeyPatch) -> None:
    values = {"machdep.cpu.brand_string": "Apple M5", "hw.memsize": str(24 * GIB)}
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    monkeypatch.setattr(platform, "mac_ver", lambda: ("26.5.2", ("", "", ""), "arm64"))
    monkeypatch.setattr(macos, "sysctl", lambda name: values.get(name, ""))
    assert doctor.collect_system() == SystemInfo("Darwin", "arm64", "Apple M5", 24 * GIB, "26.5.2")


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


def test_python_version_file_missing(lab_home: Path) -> None:
    (lab_home / ".python-version").unlink()
    check = doctor.check_python()
    assert check.status is Status.FAIL
    assert "cannot read .python-version" in check.detail


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
    check = doctor.check_secrets_dir()
    assert check.status is Status.FAIL
    assert "mode 755" in check.detail


def test_profile_check(lab_home: Path) -> None:
    check, profile = doctor.check_profile()
    assert check.status is Status.OK
    assert profile is not None and profile.name == "mac-24gb"
    (lab_home / "config/profiles/mac-24gb.toml").write_text("[model]\n")
    check, profile = doctor.check_profile()
    assert check.status is Status.FAIL
    assert profile is None
    assert "missing section [backend]" in check.detail


@pytest.fixture
def profile(lab_home: Path) -> config.Profile:
    return config.load_profile()


MLX = MetalInfo(16 * GIB, "MLX 0.32.3")


@pytest.mark.parametrize(
    ("state", "status", "detail"),
    [
        (LimitState(20480, MLX, 24 * GIB), Status.OK, "iogpu.wired_limit_mb=20480 (profile needs"),
        (LimitState(21000, MLX, 24 * GIB), Status.OK, "iogpu.wired_limit_mb=21000"),
        (LimitState(0, MLX, 24 * GIB), Status.WARN, "Metal recommends 16384 MB, below the 20480"),
        (LimitState(18000, MLX, 24 * GIB), Status.WARN, "run ./alab gpu-limit apply"),
        (LimitState(0, MetalInfo(None, "no MLX"), 24 * GIB), Status.WARN, "unknown: no MLX"),
        (LimitState(None, MLX, 24 * GIB), Status.WARN, "cannot read the sysctl"),
        (LimitState(0, MLX, 16 * GIB), Status.WARN, "above this machine's ceiling of 13312 MB"),
    ],
)
def test_gpu_limit_check(
    profile: config.Profile, state: LimitState, status: Status, detail: str
) -> None:
    check = doctor.check_gpu_limit(M5, profile, state)
    assert check.status is status
    assert detail in check.detail


def test_gpu_limit_check_off_macos(profile: config.Profile) -> None:
    linux = SystemInfo("Linux", "x86_64", "Xeon", 64 * GIB, "")
    assert doctor.check_gpu_limit(linux, profile).status is Status.WARN


def test_memory_pressure(profile: config.Profile) -> None:
    free, swap = doctor.check_memory_pressure(M5, profile, MemoryStats(21 * GIB, 0))
    assert (free.status, swap.status) == (Status.OK, Status.OK)
    assert free.detail == "21.0 GB available"
    free, swap = doctor.check_memory_pressure(M5, profile, MemoryStats(12 * GIB, 3 * GIB))
    assert (free.status, swap.status) == (Status.WARN, Status.WARN)
    assert "less than the model's 19.5 GB" in free.detail
    assert "3.0 GB in use" in swap.detail
    _, swap = doctor.check_memory_pressure(M5, profile, MemoryStats(21 * GIB, None))
    assert swap.status is Status.WARN


def test_ports(profile: config.Profile, monkeypatch: pytest.MonkeyPatch) -> None:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        port = listener.getsockname()[1]
        assert doctor.port_in_use(port)
        busy = replace(profile, gateway=replace(profile.gateway, port=port))
        monkeypatch.setattr(doctor, "port_owner", lambda p: f"python (pid 42) on {p}")
        gateway, _ = doctor.check_ports(busy)
        assert gateway.status is Status.WARN
        assert gateway.detail.startswith(f"in use by python (pid 42) on {port}; the gateway")
    assert not doctor.port_in_use(port)
    monkeypatch.setattr(doctor, "port_in_use", lambda p: False)
    assert [c.name for c in doctor.check_ports(profile)] == ["port 8000", "port 8100"]
    assert all(c.status is Status.OK for c in doctor.check_ports(profile))


def test_port_owner_parses_lsof(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_run(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        assert argv == ["/usr/sbin/lsof", "-nP", "-iTCP:8000", "-sTCP:LISTEN", "-Fpc"]
        return subprocess.CompletedProcess(argv, 0, "p4242\ncollama\nf5\n", "")

    monkeypatch.setattr(subprocess, "run", fake_run)
    assert doctor.port_owner(8000) == "ollama (pid 4242)"


def test_main_reports_and_exit_code(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    paths.ensure_layout()
    monkeypatch.setattr(doctor, "collect_system", lambda: M5)
    monkeypatch.setattr(gpulimit, "read_state", lambda: LimitState(0, MLX, 24 * GIB))
    monkeypatch.setattr(macos, "memory_stats", lambda: MemoryStats(21 * GIB, 0))
    monkeypatch.setattr(doctor, "port_in_use", lambda port: False)
    # Tools are not installed in the temporary home, so doctor must fail.
    assert doctor.main() == 1
    out = capsys.readouterr().out
    assert f"AGENT_LAB_HOME={lab_home.resolve()}" in out
    assert "Apple M5 (arm64)" in out
    assert "24 GB" in out
    assert "26.1" in out
    assert "GB free at" in out
    assert "Metal recommends 16384 MB" in out
    assert "21.0 GB available" in out
    assert "free for the gateway" in out
    assert "check(s) failed" in out
