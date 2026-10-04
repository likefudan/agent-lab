"""The pinned toolchain that bootstrap.sh installs (``config/tools.toml``, ``.tools/``)."""

from __future__ import annotations

import hashlib
import platform
import tomllib
from dataclasses import dataclass
from pathlib import Path

from agent_lab import paths

TOOLS = ("uv", "cloudflared")


class ToolchainError(Exception):
    pass


@dataclass(frozen=True)
class ToolPin:
    name: str
    version: str
    sha256: str


def platform_key(system: str | None = None, machine: str | None = None) -> str | None:
    """The tools.toml platform key for this machine, matching bootstrap.sh."""
    system = system or platform.system()
    machine = machine or platform.machine()
    return {
        ("Darwin", "arm64"): "darwin-arm64",
        ("Linux", "x86_64"): "linux-x86_64",
    }.get((system, machine))


def load_pins(platform_name: str) -> dict[str, ToolPin]:
    path = paths.tools_toml()
    try:
        with path.open("rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ToolchainError(f"cannot read {path}: {exc}") from exc
    pins = {}
    for name in TOOLS:
        try:
            pins[name] = ToolPin(
                name=name,
                version=data[name]["version"],
                sha256=data[name][platform_name]["sha256"],
            )
        except (KeyError, TypeError) as exc:
            raise ToolchainError(f"{path}: no {name} entry for {platform_name}") from exc
    return pins


def read_stamp(name: str) -> dict[str, str]:
    """What bootstrap.sh recorded when it installed ``name`` (empty if never installed)."""
    stamp = paths.tools_stamps_dir() / name
    if not stamp.is_file():
        return {}
    values = {}
    for line in stamp.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key] = value
    return values


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_tool(pin: ToolPin) -> str | None:
    """Return a problem description, or None if the installed tool matches its pin."""
    binary = paths.tools_bin_dir() / pin.name
    if not binary.is_file():
        return f"{binary} is missing"
    stamp = read_stamp(pin.name)
    if stamp.get("version") != pin.version or stamp.get("sha256") != pin.sha256:
        installed = stamp.get("version", "unknown version")
        return f"installed {installed} does not match config/tools.toml ({pin.version})"
    if stamp.get("binary_sha256") != sha256_file(binary):
        return f"{binary} was modified after installation"
    return None


def pinned_python_version() -> str:
    return paths.python_version_file().read_text().strip()
