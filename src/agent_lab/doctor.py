"""``alab doctor``: check the machine and the project toolchain (design section 6.5).

T01 covers the chip, memory, macOS version, free disk space and toolchain
integrity; T03 adds the GPU limit, available memory, swap and ports. The tunnel
check comes with T07.
"""

from __future__ import annotations

import os
import platform
import shutil
import socket
import subprocess
import sys
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from agent_lab import config, gpulimit, macos, paths, toolchain

GIB = 1024**3
MIN_MACOS = (14, 0)  # oldest macOS that MLX publishes wheels for
RECOMMENDED_MEMORY = 24 * GIB
MIN_FREE_DISK = 20 * GIB  # the Q4 model alone is about 16GB
SWAP_WARN = 1 * GIB  # more swap than this means memory is already under pressure
LSOF = "/usr/sbin/lsof"


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
        chip = macos.sysctl("machdep.cpu.brand_string")
        memory = macos.sysctl_int("hw.memsize")
        macos_version = platform.mac_ver()[0]
    else:
        chip = _linux_cpu_name() if system == "Linux" else ""
        try:
            memory = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
        except ValueError, OSError, AttributeError:
            memory = None
        macos_version = ""
    return SystemInfo(system, machine, chip or "unknown", memory, macos_version)


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


def check_profile(name: str = config.DEFAULT_PROFILE) -> tuple[Check, config.Profile | None]:
    try:
        profile = config.load_profile(name)
    except config.ConfigError as exc:
        return Check("profile", Status.FAIL, str(exc)), None
    detail = f"{name} (max_context {profile.gateway.max_context})"
    return Check("profile", Status.OK, detail), profile


def check_gpu_limit(
    info: SystemInfo, profile: config.Profile, state: gpulimit.LimitState | None = None
) -> Check:
    if info.system != "Darwin":
        return Check("GPU limit", Status.WARN, f"{gpulimit.SYSCTL_NAME} only exists on macOS")
    state = state or gpulimit.read_state()
    needed = profile.system.gpu_wired_limit_mb
    if state.memory_bytes and needed > gpulimit.ceiling_mb(state.memory_bytes):
        return Check(
            "GPU limit",
            Status.WARN,
            f"profile {profile.name} needs {needed} MB, above this machine's ceiling of "
            f"{gpulimit.ceiling_mb(state.memory_bytes)} MB; it cannot run here",
        )
    effective = state.effective_mb()
    if effective is None:
        reason = state.metal.note if state.wired_limit_mb == 0 else "cannot read the sysctl"
        return Check("GPU limit", Status.WARN, f"limit in force is unknown: {reason}")
    source = (
        f"{gpulimit.SYSCTL_NAME}={state.wired_limit_mb}"
        if state.wired_limit_mb
        else f"system default, Metal recommends {effective} MB"
    )
    if effective < needed:
        return Check(
            "GPU limit",
            Status.WARN,
            f"{source}, below the {needed} MB the profile needs; "
            "run ./alab gpu-limit apply before serving (resets on reboot)",
        )
    return Check("GPU limit", Status.OK, f"{source} (profile needs {needed} MB)")


def check_memory_pressure(
    info: SystemInfo, profile: config.Profile, stats: macos.MemoryStats | None = None
) -> list[Check]:
    if info.system != "Darwin":
        return [Check("free memory", Status.WARN, "only checked on macOS")]
    stats = stats or macos.memory_stats()
    if stats is None:
        return [Check("free memory", Status.WARN, "could not read vm_stat")]
    needed = profile.backend.metal_memory_limit
    available = f"{stats.available_bytes / GIB:.1f} GB available"
    if stats.available_bytes < needed:
        free = Check(
            "free memory",
            Status.WARN,
            f"{available}, less than the model's {needed / GIB:.1f} GB; "
            "close memory-heavy apps before serving",
        )
    else:
        free = Check("free memory", Status.OK, available)
    if stats.swap_used_bytes is None:
        swap = Check("swap", Status.WARN, "could not read vm.swapusage")
    elif stats.swap_used_bytes > SWAP_WARN:
        swap = Check(
            "swap",
            Status.WARN,
            f"{stats.swap_used_bytes / GIB:.1f} GB in use; memory is already under pressure",
        )
    else:
        swap = Check("swap", Status.OK, f"{stats.swap_used_bytes / GIB:.1f} GB in use")
    return [free, swap]


def port_in_use(port: int, host: str = "127.0.0.1") -> bool:
    """True if something accepts connections on the port, or it cannot be bound."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        if probe.connect_ex((host, port)) == 0:
            return True
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        # Like the servers themselves, ignore connections lingering in TIME_WAIT.
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((host, port))
        except OSError:
            return True
    return False


def port_owner(port: int) -> str:
    """The listening process as "name (pid N)", or "" if lsof cannot tell."""
    try:
        result = subprocess.run(
            [LSOF, "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpc"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return ""
    pid = command = ""
    for line in result.stdout.splitlines():
        if line.startswith("p") and not pid:
            pid = line[1:]
        elif line.startswith("c") and not command:
            command = line[1:]
    return f"{command} (pid {pid})" if pid else ""


def check_ports(profile: config.Profile) -> list[Check]:
    checks = []
    for role, port in (("gateway", profile.gateway.port), ("backend", profile.backend.port)):
        name = f"port {port}"
        if not port_in_use(port):
            checks.append(Check(name, Status.OK, f"free for the {role}"))
            continue
        owner = port_owner(port)
        by = f" by {owner}" if owner else ""
        checks.append(
            Check(
                name, Status.WARN, f"in use{by}; the {role} cannot start unless that is agent-lab"
            )
        )
    return checks


def run_checks(info: SystemInfo | None = None) -> list[Check]:
    info = info or collect_system()
    home = paths.home()
    profile_check, profile = check_profile()
    checks = [
        check_chip(info),
        check_memory(info),
        check_macos(info),
        check_disk(home),
        check_python(),
        *check_tools(toolchain.platform_key(info.system, info.machine)),
        check_secrets_dir(),
        profile_check,
    ]
    if profile is not None:
        checks += [
            check_gpu_limit(info, profile),
            *check_memory_pressure(info, profile),
            *check_ports(profile),
        ]
    return checks


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
