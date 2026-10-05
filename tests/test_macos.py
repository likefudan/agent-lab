from __future__ import annotations

from agent_lab import macos

VM_STAT = """\
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               10000.
Pages active:                            400000.
Pages inactive:                          200000.
Pages speculative:                         5000.
Pages throttled:                              0.
Pages wired down:                        300000.
"Translation faults":                 123456789.
"""


def test_parse_vm_stat() -> None:
    assert macos.parse_vm_stat(VM_STAT) == (10000 + 200000 + 5000) * 16384
    assert macos.parse_vm_stat("") is None
    assert macos.parse_vm_stat(VM_STAT.replace("Pages inactive", "Pages gone")) is None


def test_parse_swap_usage() -> None:
    text = "total = 2048.00M  used = 1536.50M  free = 511.50M  (encrypted)"
    assert macos.parse_swap_usage(text) == int(1536.5 * 1024**2)
    assert macos.parse_swap_usage("total = 4.00G  used = 1.25G  free = 2.75G") == int(
        1.25 * 1024**3
    )
    assert macos.parse_swap_usage("total = 0.00M  used = 0.00M  free = 0.00M") == 0
    assert macos.parse_swap_usage("") is None


def test_sysctl_unreadable_returns_nothing() -> None:
    assert macos.sysctl_int("no.such.sysctl.name") is None
