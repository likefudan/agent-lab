from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

from agent_lab import toolchain
from agent_lab.toolchain import ToolPin, verify_tool

from .conftest import REPO_ROOT

PLATFORMS = ("darwin-arm64", "linux-x86_64")


def test_tools_toml_pins_are_consistent() -> None:
    with (REPO_ROOT / "config/tools.toml").open("rb") as f:
        data = tomllib.load(f)
    for name in toolchain.TOOLS:
        version = data[name]["version"]
        for platform_name in PLATFORMS:
            entry = data[name][platform_name]
            assert set(entry) == {"url", "sha256", "format", "binary"}
            assert re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
            assert entry["url"].startswith("https://")
            assert f"/{version}/" in entry["url"], "url must match the pinned version"
            assert entry["format"] in {"tar.gz", "binary"}
            assert bool(entry["binary"]) == (entry["format"] == "tar.gz")


def test_tools_toml_stays_line_parseable() -> None:
    """bootstrap.sh parses tools.toml line by line; keep it to simple string assignments."""
    for line in (REPO_ROOT / "config/tools.toml").read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        assert re.fullmatch(r'\[[a-z0-9._-]+\]|[a-z0-9_]+ = "[^"]*"', stripped), line


@pytest.mark.parametrize(
    ("system", "machine", "expected"),
    [
        ("Darwin", "arm64", "darwin-arm64"),
        ("Linux", "x86_64", "linux-x86_64"),
        ("Darwin", "x86_64", None),
        ("Windows", "AMD64", None),
    ],
)
def test_platform_key(system: str, machine: str, expected: str | None) -> None:
    assert toolchain.platform_key(system, machine) == expected


def test_load_pins(lab_home: Path) -> None:
    pins = toolchain.load_pins("darwin-arm64")
    assert set(pins) == {"uv", "cloudflared"}
    with pytest.raises(toolchain.ToolchainError, match="no uv entry for plan9"):
        toolchain.load_pins("plan9")


def _install_fake(lab_home: Path, pin: ToolPin, content: bytes = b"binary") -> Path:
    binary = lab_home / ".tools/bin" / pin.name
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(content)
    stamps = lab_home / ".tools/stamps"
    stamps.mkdir(parents=True, exist_ok=True)
    (stamps / pin.name).write_text(
        f"version={pin.version}\nsha256={pin.sha256}\n"
        f"binary_sha256={toolchain.sha256_file(binary)}\n"
    )
    return binary


def test_verify_tool(lab_home: Path) -> None:
    pin = ToolPin("uv", "1.0", "a" * 64)
    assert verify_tool(pin) is not None and "missing" in str(verify_tool(pin))

    binary = _install_fake(lab_home, pin)
    assert verify_tool(pin) is None

    assert "does not match" in str(verify_tool(ToolPin("uv", "1.1", "a" * 64)))
    assert "does not match" in str(verify_tool(ToolPin("uv", "1.0", "b" * 64)))

    binary.write_bytes(b"tampered")
    assert "modified after installation" in str(verify_tool(pin))
