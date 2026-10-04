"""``alab doctor``: check the machine and the project toolchain (design section 6.5).

T01 covers the chip, memory, macOS version, free disk space and toolchain
integrity. Later tasks add the GPU limit, ports and tunnel checks.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from agent_lab import config, paths, toolchain

GIB = 1024**3
MIN_MACOS = (14, 0)  # oldest macOS that MLX publishes wheels for
RECOMMENDED_MEMORY = 24 * GIB
MIN_FREE_DISK = 20 * GIB  # the Q4 model alone is about 16GB


class Status(StrEnum):
    OK = "ok"
    WARN = "warn"
    FAIL = "FAIL"


@dataclass(frozen=True)
class Check:
    name: str
    status: Status
    detail: str


@dataclass(frozen=True)
class SystemInfo:
    system: str  # platform.system(): "Darwin", "Linux", ...
    machine: str  # "arm64", "x86_64", ...
    chip: str
    memory_bytes: int | None
    macos_version: str  # "" when not macOS


def _sysctl(name: str) -> str:
    try:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", name], capture_output=True, text=True, check=True
        )
    except OSError, subprocess.CalledProcessError:
        return ""
    return result.stdout.strip()


def _linux_cpu_name() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.partition(":")[2].strip()
    except OSError:
        pass
    return ""


def collect_system() -> SystemInfo:
    system = platform.system()
    machine = platform.machine()
    if system == "Darwin":
        chip = _sysctl("machdep.cpu.brand_string")
        memsize = _sysctl("hw.memsize")
        memory = int(memsize) if memsize.isdigit() else None
        macos = platform.mac_ver()[0]
    else:
        chip = _linux_cpu_name() if system == "Linux" else ""
        try:
            memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
        except ValueError, OSError, AttributeError:
            memory = None
        macos = ""
    return SystemInfo(system, machine, chip or "unknown", memory, macos)


def _version_tuple(text: str) -> tuple[int, ...]:
    parts = []
    for part in text.split("."):
        if not part.isdigit():
            break
        parts.append(int(part))
    return tuple(parts)


def check_chip(info: SystemInfo) -> Check:
    detail = f"{info.chip} ({info.machine})"
    if info.system == "Darwin" and info.machine == "arm64":
        return Check("chip", Status.OK, detail)
    return Check("chip", Status.FAIL, f"{detail}; agent-lab needs an Apple Silicon Mac")


def check_memory(info: SystemInfo) -> Check:
    if info.memory_bytes is None:
        return Check("memory", Status.WARN, "could not read physical memory")
    detail = f"{info.memory_bytes / GIB:.0f} GB"
    if info.memory_bytes < RECOMMENDED_MEMORY:
        return Check("memory", Status.WARN, f"{detail}; the 27B profile is sized for 24 GB")
    return Check("memory", Status.OK, detail)


def check_macos(info: SystemInfo) -> Check:
    if info.system != "Darwin":
        return Check("macOS", Status.FAIL, f"not macOS ({info.system})")
    version = _version_tuple(info.macos_version)
    if not version:
        return Check("macOS", Status.WARN, "could not read the macOS version")
    minimum = ".".join(map(str, MIN_MACOS))
    if version < MIN_MACOS:
        return Check("macOS", Status.FAIL, f"{info.macos_version}; MLX needs macOS {minimum}+")
    return Check("macOS", Status.OK, info.macos_version)


def check_disk(home: Path, free_bytes: int | None = None) -> Check:
    if free_bytes is None:
        free_bytes = shutil.disk_usage(home).free
    detail = f"{free_bytes / GIB:.1f} GB free at {home}"
    if free_bytes < MIN_FREE_DISK:
        return Check("disk", Status.WARN, f"{detail}; models need about 20 GB")
    return Check("disk", Status.OK, detail)


def check_python() -> Check:
    executable = Path(sys.executable)
    try:
        pinned = toolchain.pinned_python_version()
    except OSError as exc:
        return Check("python", Status.FAIL, f"cannot read .python-version: {exc}")
    running = platform.python_version()
    real = executable.resolve()
    detail = f"{running} at {executable}"
    if real != executable:
        detail += f" -> {real}"
    if not real.is_relative_to(paths.tools_python_dir().resolve()):
        return Check("python", Status.FAIL, f"{detail}; not the Python in .tools/python")
    if running != pinned:
        return Check("python", Status.FAIL, f"{detail}; .python-version pins {pinned}")
    return Check("python", Status.OK, detail)


def check_tools(platform_name: str | None) -> list[Check]:
    if platform_name is None:
        return [Check("toolchain", Status.FAIL, "no pinned tools for this platform")]
    try:
        pins = toolchain.load_pins(platform_name)
    except toolchain.ToolchainError as exc:
        return [Check("toolchain", Status.FAIL, str(exc))]
    checks = []
    for pin in pins.values():
        problem = toolchain.verify_tool(pin)
        if problem:
            checks.append(Check(pin.name, Status.FAIL, f"{problem}; run ./bootstrap.sh"))
        else:
            checks.append(Check(pin.name, Status.OK, f"{pin.version}, sha256 verified"))
    return checks


def check_secrets_dir() -> Check:
    secrets = paths.secrets_dir()
    if not secrets.is_dir():
        return Check("secrets", Status.FAIL, f"{secrets} is missing; run ./bootstrap.sh")
    mode = secrets.stat().st_mode & 0o777
    if mode != paths.SECRETS_MODE:
        return Check(
            "secrets", Status.FAIL, f"{secrets} has mode {mode:o}; run chmod 700 {secrets}"
        )
    return Check("secrets", Status.OK, f"{secrets} (mode 700)")


def check_profile(name: str = config.DEFAULT_PROFILE) -> Check:
    try:
        profile = config.load_profile(name)
    except config.ConfigError as exc:
        return Check("profile", Status.FAIL, str(exc))
    return Check("profile", Status.OK, f"{name} (max_context {profile.gateway.max_context})")


def run_checks(info: SystemInfo | None = None) -> list[Check]:
    info = info or collect_system()
    home = paths.home()
    return [
        check_chip(info),
        check_memory(info),
        check_macos(info),
        check_disk(home),
        check_python(),
        *check_tools(toolchain.platform_key(info.system, info.machine)),
        check_secrets_dir(),
        check_profile(),
    ]


def main() -> int:
    print(f"agent-lab doctor ({paths.ENV_VAR}={paths.home()})")
    checks = run_checks()
    width = max(len(c.name) for c in checks)
    for c in checks:
        print(f"  {c.status.value:<4}  {c.name:<{width}}  {c.detail}")
    failed = [c for c in checks if c.status is Status.FAIL]
    warned = [c for c in checks if c.status is Status.WARN]
    if failed:
        print(f"{len(failed)} check(s) failed, {len(warned)} warning(s)")
        return 1
    print(f"all checks passed ({len(warned)} warning(s))")
    return 0
