from __future__ import annotations

import platform
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from agent_lab import cli, config, gpulimit, macos
from agent_lab.gpulimit import GpuLimitError, LimitState, MetalInfo

GIB = 1024**3
M5_MEMORY = 24 * GIB
MLX = MetalInfo(16 * GIB, "MLX 0.32.3")


class FakeMac:
    """Stands in for sysctl, sudo and the terminal; records every command that would run."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch, wired: int | None = 0) -> None:
        self.wired = wired
        self.memory: int | None = M5_MEMORY
        self.commands: list[list[str]] = []
        self.answers: list[str] = []
        self.prompts: list[str] = []
        self.tty = True
        self.exit_code = 0
        monkeypatch.setattr(platform, "system", lambda: "Darwin")
        monkeypatch.setattr(gpulimit, "read_metal_info", lambda: MLX)
        monkeypatch.setattr(gpulimit, "memory_bytes", lambda: self.memory)
        monkeypatch.setattr(macos, "sysctl_int", self._sysctl_int)
        monkeypatch.setattr(gpulimit, "run_command", self._run)
        monkeypatch.setattr(sys.stdin, "isatty", lambda: self.tty, raising=False)
        monkeypatch.setattr("builtins.input", self._input)

    def _sysctl_int(self, name: str) -> int | None:
        assert name == "iogpu.wired_limit_mb"
        return self.wired

    def _run(self, argv: list[str]) -> int:
        self.commands.append(argv)
        if self.exit_code == 0:
            self.wired = int(argv[-1].partition("=")[2])
        return self.exit_code

    def _input(self, prompt: str) -> str:
        self.prompts.append(prompt)
        if not self.answers:
            raise EOFError
        return self.answers.pop(0)


@pytest.fixture
def mac(monkeypatch: pytest.MonkeyPatch, lab_home: Path) -> FakeMac:
    return FakeMac(monkeypatch)


@pytest.fixture
def profile(lab_home: Path) -> config.Profile:
    return config.load_profile()


def _with_limit(profile: config.Profile, value_mb: int) -> config.Profile:
    return replace(profile, system=config.SystemConfig(gpu_wired_limit_mb=value_mb))


def test_ceiling_is_physical_memory_minus_3gb() -> None:
    assert gpulimit.ceiling_mb(24 * GIB) == 21504
    assert gpulimit.ceiling_mb(16 * GIB) == 13312
    assert gpulimit.ceiling_mb(7 * GIB) == 4096


def test_sysctl_arguments() -> None:
    assert gpulimit.sysctl_command(20480) == [
        "/usr/bin/sudo",
        "/usr/sbin/sysctl",
        "iogpu.wired_limit_mb=20480",
    ]
    assert gpulimit.sysctl_command(0)[-1] == "iogpu.wired_limit_mb=0"


def test_apply_confirmed(
    mac: FakeMac, profile: config.Profile, capsys: pytest.CaptureFixture[str]
) -> None:
    mac.answers = ["y"]
    gpulimit.apply(profile)
    assert mac.commands == [["/usr/bin/sudo", "/usr/sbin/sysctl", "iogpu.wired_limit_mb=20480"]]
    assert mac.prompts == ["Run it? [y/N] "]
    out = capsys.readouterr().out
    assert "Command: /usr/bin/sudo /usr/sbin/sysctl iogpu.wired_limit_mb=20480" in out
    assert "cannot be swapped out" in out
    assert "4.0 GB left" in out
    assert "is now 20480 MB" in out


@pytest.mark.parametrize("answer", ["", "n", "no", "maybe", None])
def test_apply_without_confirmation_runs_nothing(
    mac: FakeMac, profile: config.Profile, answer: str | None
) -> None:
    mac.answers = [] if answer is None else [answer]  # None: input() hits end of file
    with pytest.raises(GpuLimitError, match="cancelled"):
        gpulimit.apply(profile)
    assert mac.commands == []
    assert mac.wired == 0


def test_apply_without_terminal_needs_yes(mac: FakeMac, profile: config.Profile) -> None:
    mac.tty = False
    with pytest.raises(GpuLimitError, match="--yes"):
        gpulimit.apply(profile)
    assert mac.commands == []
    gpulimit.apply(profile, assume_yes=True)
    assert mac.prompts == []
    assert mac.wired == 20480


def test_apply_refuses_values_above_the_ceiling(mac: FakeMac, profile: config.Profile) -> None:
    with pytest.raises(GpuLimitError, match="above the ceiling of 21504 MB"):
        gpulimit.apply(_with_limit(profile, 21505), assume_yes=True)
    mac.memory = 16 * GIB
    with pytest.raises(GpuLimitError, match="ceiling of 13312 MB"):
        gpulimit.apply(profile, assume_yes=True)
    assert mac.commands == []
    mac.memory = 24 * GIB
    gpulimit.apply(_with_limit(profile, 21504), assume_yes=True)  # the ceiling itself is allowed
    assert mac.wired == 21504


def test_apply_refuses_when_memory_is_unknown(mac: FakeMac, profile: config.Profile) -> None:
    mac.memory = None
    with pytest.raises(GpuLimitError, match="ceiling is unknown"):
        gpulimit.apply(profile, assume_yes=True)
    assert mac.commands == []


def test_apply_skips_when_already_set(
    mac: FakeMac, profile: config.Profile, capsys: pytest.CaptureFixture[str]
) -> None:
    mac.wired = 20480
    gpulimit.apply(profile)
    assert mac.commands == []
    assert "already 20480 MB" in capsys.readouterr().out


def test_apply_reports_sudo_failure(mac: FakeMac, profile: config.Profile) -> None:
    mac.exit_code = 1
    with pytest.raises(GpuLimitError, match="exited with status 1"):
        gpulimit.apply(profile, assume_yes=True)


def test_apply_verifies_the_new_value(
    mac: FakeMac, profile: config.Profile, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(gpulimit, "run_command", lambda argv: 0)  # "succeeds" without changing it
    with pytest.raises(GpuLimitError, match="reads 0 after the change, expected 20480"):
        gpulimit.apply(profile, assume_yes=True)


def test_revert(mac: FakeMac, capsys: pytest.CaptureFixture[str]) -> None:
    gpulimit.revert()
    assert mac.commands == []
    assert "already 0" in capsys.readouterr().out
    mac.wired = 20480
    with pytest.raises(GpuLimitError, match="cancelled"):
        gpulimit.revert()
    assert mac.commands == []
    mac.answers = ["yes"]
    gpulimit.revert()
    assert mac.commands == [["/usr/bin/sudo", "/usr/sbin/sysctl", "iogpu.wired_limit_mb=0"]]
    assert mac.wired == 0


def test_apply_and_revert_need_macos(
    profile: config.Profile, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Linux")
    monkeypatch.setattr(gpulimit, "run_command", pytest.fail)
    with pytest.raises(GpuLimitError, match="only exists on macOS"):
        gpulimit.apply(profile, assume_yes=True)
    with pytest.raises(GpuLimitError, match="only exists on macOS"):
        gpulimit.revert(assume_yes=True)


def test_effective_limit() -> None:
    assert LimitState(20480, MLX, M5_MEMORY).effective_mb() == 20480
    assert LimitState(0, MLX, M5_MEMORY).effective_mb() == 16384
    assert LimitState(0, MetalInfo(None, "no MLX"), M5_MEMORY).effective_mb() is None
    assert LimitState(None, MLX, M5_MEMORY).effective_mb() is None


def test_show(profile: config.Profile, capsys: pytest.CaptureFixture[str]) -> None:
    gpulimit.show(profile, LimitState(0, MLX, M5_MEMORY))
    out = capsys.readouterr().out
    assert "iogpu.wired_limit_mb           0 (system default)" in out
    assert "16.0 GB (MLX 0.32.3)" in out
    assert "24.0 GB (24576 MB)" in out
    assert "profile mac-24gb needs         20480 MB" in out
    assert "ceiling (physical - 3GB)       21504 MB" in out
    assert "16384 MB in force is below the profile's 20480 MB" in out

    gpulimit.show(profile, LimitState(20480, MetalInfo(None, "MLX is not installed"), None))
    out = capsys.readouterr().out
    assert "unavailable: MLX is not installed" in out
    assert "status: OK, 20480 MB in force" in out
    assert "ceiling" not in out


def test_metal_info_without_mlx(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "mlx", None)
    monkeypatch.setitem(sys.modules, "mlx.core", None)
    info = gpulimit.read_metal_info()
    assert info.recommended_bytes is None
    assert "MLX is not installed" in info.note


def test_cli_dispatch(mac: FakeMac, capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["gpu-limit"]) == 0
    assert "profile mac-24gb needs" in capsys.readouterr().out
    assert cli.main(["gpu-limit", "apply"]) == 1  # no answer: cancelled
    assert "cancelled; nothing was changed" in capsys.readouterr().err
    assert cli.main(["gpu-limit", "apply", "--yes"]) == 0
    assert mac.wired == 20480
    assert cli.main(["gpu-limit", "revert", "--yes"]) == 0
    assert mac.wired == 0
    assert cli.main(["gpu-limit", "--profile", "missing", "apply", "--yes"]) == 1
    assert 'profile "missing" not found' in capsys.readouterr().err
    assert cli.main(["gpu-limit", "show", "--profile", "missing"]) == 1
    assert mac.commands == [
        ["/usr/bin/sudo", "/usr/sbin/sysctl", "iogpu.wired_limit_mb=20480"],
        ["/usr/bin/sudo", "/usr/sbin/sysctl", "iogpu.wired_limit_mb=0"],
    ]
