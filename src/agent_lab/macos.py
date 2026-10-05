"""Read-only queries of macOS system state: sysctl values and memory statistics.

Every function returns ``None`` (or an empty string) instead of raising when the
value cannot be read, for example on Linux during development.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass

SYSCTL = "/usr/sbin/sysctl"
VM_STAT = "/usr/bin/vm_stat"

MIB = 1024**2

_UNIT_BYTES = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
_SWAP_USED_RE = re.compile(r"used\s*=\s*([\d.]+)([KMGT])")
_PAGE_SIZE_RE = re.compile(r"page size of (\d+) bytes")
_VM_STAT_LINE_RE = re.compile(r'^"?([^:"]+)"?:\s+(\d+)\.?\s*$')


def _run(argv: list[str]) -> str:
    try:
        result = subprocess.run(argv, capture_output=True, text=True, check=True)
    except OSError, subprocess.CalledProcessError:
        return ""
    return result.stdout


def sysctl(name: str) -> str:
    """``sysctl -n <name>``, or an empty string if it cannot be read."""
    return _run([SYSCTL, "-n", name]).strip()


def sysctl_int(name: str) -> int | None:
    value = sysctl(name)
    return int(value) if value.isdigit() else None


@dataclass(frozen=True)
class MemoryStats:
    available_bytes: int  # free + inactive + speculative pages: what can be had without swapping
    swap_used_bytes: int | None


def parse_vm_stat(text: str) -> int | None:
    """Available bytes (free + inactive + speculative pages) from ``vm_stat`` output."""
    page_size = _PAGE_SIZE_RE.search(text)
    if not page_size:
        return None
    pages: dict[str, int] = {}
    for line in text.splitlines():
        match = _VM_STAT_LINE_RE.match(line.strip())
        if match:
            pages[match.group(1).strip()] = int(match.group(2))
    wanted = ("Pages free", "Pages inactive", "Pages speculative")
    if not all(key in pages for key in wanted):
        return None
    return sum(pages[key] for key in wanted) * int(page_size.group(1))


def parse_swap_usage(text: str) -> int | None:
    """Used bytes from ``sysctl vm.swapusage``, e.g. ``total = 2048.00M  used = 1.25G  ...``."""
    match = _SWAP_USED_RE.search(text)
    if not match:
        return None
    return int(float(match.group(1)) * _UNIT_BYTES[match.group(2)])


def memory_stats() -> MemoryStats | None:
    available = parse_vm_stat(_run([VM_STAT]))
    if available is None:
        return None
    return MemoryStats(available, parse_swap_usage(sysctl("vm.swapusage")))
