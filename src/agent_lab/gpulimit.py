"""``alab gpu-limit``: show, temporarily raise and restore the GPU wired memory limit.

This is the only system-level change agent-lab makes (design section 4.3). It
runs ``sudo sysctl iogpu.wired_limit_mb=<value>`` after the user confirms, never
above "physical memory minus 3GB", and the kernel forgets the value on reboot.
Nothing here installs anything that would apply it at boot.
"""

from __future__ import annotations

import platform
import shlex
import subprocess
import sys
from dataclasses import dataclass

from agent_lab import config, macos
from agent_lab.macos import MIB

SYSCTL_NAME = "iogpu.wired_limit_mb"
SUDO = "/usr/bin/sudo"
HEADROOM_MB = 3 * 1024  # left to macOS and other apps; wired memory cannot be swapped out
SYSTEM_DEFAULT = 0  # writing 0 restores the kernel's default limit

GIB = 1024**3


class GpuLimitError(Exception):
    """A gpu-limit command was refused or failed; the message says why."""


@dataclass(frozen=True)
class MetalInfo:
    """Metal's ``recommendedMaxWorkingSetSize`` as MLX reports it, or why it is unavailable."""

    recommended_bytes: int | None
    note: str  # "MLX 0.32.3" or the reason the value is missing


@dataclass(frozen=True)
class LimitState:
    wired_limit_mb: int | None  # sysctl value; 0 means the system default; None if unreadable
    metal: MetalInfo
    memory_bytes: int | None

    def effective_mb(self) -> int | None:
        """The limit in force: the sysctl value, or Metal's recommendation while it is 0."""
        if self.wired_limit_mb:
            return self.wired_limit_mb
        if self.wired_limit_mb == SYSTEM_DEFAULT and self.metal.recommended_bytes:
            return self.metal.recommended_bytes // MIB
        return None


def read_metal_info() -> MetalInfo:
    try:
        import mlx.core as mx
    except ImportError as exc:
        return MetalInfo(None, f"MLX is not installed ({exc}); only the sysctl value is shown")
    try:
        if not mx.metal.is_available():
            return MetalInfo(None, "MLX reports no Metal GPU on this machine")
        info = mx.device_info(mx.gpu)
    except Exception as exc:  # MLX raises plain RuntimeErrors from the C++ side
        return MetalInfo(None, f"MLX could not read the Metal device: {exc}")
    value = info.get("max_recommended_working_set_size")
    if not isinstance(value, int) or value <= 0:
        return MetalInfo(None, f"MLX {mx.__version__} did not report the recommended working set")
    return MetalInfo(value, f"MLX {mx.__version__}")


def memory_bytes() -> int | None:
    return macos.sysctl_int("hw.memsize")


def read_state() -> LimitState:
    return LimitState(macos.sysctl_int(SYSCTL_NAME), read_metal_info(), memory_bytes())


def ceiling_mb(memory: int) -> int:
    """The highest value ``apply`` accepts: physical memory minus 3GB, in MB."""
    return memory // MIB - HEADROOM_MB


def sysctl_command(value_mb: int) -> list[str]:
    return [SUDO, macos.SYSCTL, f"{SYSCTL_NAME}={value_mb}"]


def _gb(n_bytes: int) -> str:
    return f"{n_bytes / GIB:.1f} GB"


def _describe_limit(state: LimitState) -> str:
    if state.wired_limit_mb is None:
        return "unknown (cannot read the sysctl)"
    if state.wired_limit_mb == SYSTEM_DEFAULT:
        return "0 (system default)"
    return f"{state.wired_limit_mb} MB"


def show(profile: config.Profile, state: LimitState | None = None) -> None:
    state = state or read_state()
    needed = profile.system.gpu_wired_limit_mb
    metal = state.metal
    rows = [
        (SYSCTL_NAME, _describe_limit(state)),
        (
            "Metal recommended working set",
            f"{_gb(metal.recommended_bytes)} ({metal.note})"
            if metal.recommended_bytes
            else f"unavailable: {metal.note}",
        ),
        (
            "physical memory",
            f"{_gb(state.memory_bytes)} ({state.memory_bytes // MIB} MB)"
            if state.memory_bytes
            else "unknown",
        ),
        (f"profile {profile.name} needs", f"{needed} MB"),
    ]
    if state.memory_bytes:
        rows.append(("ceiling (physical - 3GB)", f"{ceiling_mb(state.memory_bytes)} MB"))
    width = max(len(name) for name, _ in rows)
    for name, value in rows:
        print(f"  {name:<{width}}  {value}")
    print(status_line(state, needed))


def status_line(state: LimitState, needed_mb: int) -> str:
    effective = state.effective_mb()
    if effective is None:
        return "status: the GPU limit in force is unknown"
    if effective >= needed_mb:
        return f"status: OK, {effective} MB in force (profile needs {needed_mb} MB)"
    return (
        f"status: {effective} MB in force is below the profile's {needed_mb} MB; "
        "run `./alab gpu-limit apply` (resets on reboot)"
    )


def confirm(prompt: str) -> bool:
    """Ask on the terminal; anything but y/yes, or no terminal at all, means no."""
    if not sys.stdin.isatty():
        raise GpuLimitError("confirmation needs a terminal; run it in one, or pass --yes")
    try:
        answer = input(f"{prompt} [y/N] ")
    except EOFError:
        return False
    return answer.strip().lower() in {"y", "yes"}


def run_command(argv: list[str]) -> int:
    """Run the sudo command in the foreground so sudo can ask for the password."""
    return subprocess.run(argv, check=False).returncode


def _require_macos() -> None:
    if platform.system() != "Darwin":
        raise GpuLimitError(f"{SYSCTL_NAME} only exists on macOS (this is {platform.system()})")


def _set(value_mb: int, prompt_lines: list[str], assume_yes: bool) -> None:
    argv = sysctl_command(value_mb)
    for line in prompt_lines:
        print(line)
    print(f"Command: {shlex.join(argv)}")
    if not assume_yes and not confirm("Run it?"):
        raise GpuLimitError("cancelled; nothing was changed")
    code = run_command(argv)
    if code != 0:
        raise GpuLimitError(f"sudo sysctl exited with status {code}; nothing was changed")
    now = macos.sysctl_int(SYSCTL_NAME)
    if now != value_mb:
        raise GpuLimitError(f"{SYSCTL_NAME} reads {now} after the change, expected {value_mb}")


def apply(profile: config.Profile, assume_yes: bool = False) -> None:
    """Raise the limit to the profile's ``gpu_wired_limit_mb`` after confirmation."""
    _require_macos()
    value = profile.system.gpu_wired_limit_mb
    state = read_state()
    if state.memory_bytes is None:
        raise GpuLimitError("cannot read physical memory, so the safe ceiling is unknown")
    ceiling = ceiling_mb(state.memory_bytes)
    if value > ceiling:
        raise GpuLimitError(
            f"refusing {value} MB: above the ceiling of {ceiling} MB "
            f"(physical memory {state.memory_bytes // MIB} MB minus {HEADROOM_MB} MB). "
            f"Lower [system] gpu_wired_limit_mb in {profile.path}"
        )
    if state.wired_limit_mb == value:
        print(f"{SYSCTL_NAME} is already {value} MB; nothing to do")
        return
    left = state.memory_bytes - value * MIB
    _set(
        value,
        [
            f"This sets {SYSCTL_NAME} from {_describe_limit(state)} to {value} MB "
            f"(profile {profile.name}).",
            f"  - Wired memory cannot be swapped out. If the model plus macOS and your apps need "
            f"more than the {_gb(left)} left, the Mac can stall or freeze until rebooted.",
            "  - Close memory-heavy apps before `./alab serve`.",
            "  - It is temporary: a reboot restores the default, "
            "and `./alab gpu-limit revert` restores it now.",
        ],
        assume_yes,
    )
    print(f"{SYSCTL_NAME} is now {value} MB until reboot or `./alab gpu-limit revert`")


def revert(assume_yes: bool = False) -> None:
    """Restore the system default (0) after confirmation."""
    _require_macos()
    current = macos.sysctl_int(SYSCTL_NAME)
    if current == SYSTEM_DEFAULT:
        print(f"{SYSCTL_NAME} is already 0 (system default); nothing to do")
        return
    shown = "unknown" if current is None else f"{current} MB"
    _set(
        SYSTEM_DEFAULT,
        [f"This restores {SYSCTL_NAME} from {shown} to 0 (the system default)."],
        assume_yes,
    )
    print(f"{SYSCTL_NAME} is back to 0 (system default)")
