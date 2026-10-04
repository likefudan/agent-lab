"""Load and validate profiles from ``config/profiles/*.toml`` (design section 6.4)."""

from __future__ import annotations

import re
import tomllib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from agent_lab import paths

DEFAULT_PROFILE = "mac-24gb"

# Cloudflare drops a connection after about 100 seconds without data (design section 7.3).
CLOUDFLARE_IDLE_TIMEOUT_SECONDS = 100

_SIZE_UNITS = {
    "B": 1,
    "KB": 1024,
    "MB": 1024**2,
    "GB": 1024**3,
    "TB": 1024**4,
    "KIB": 1024,
    "MIB": 1024**2,
    "GIB": 1024**3,
    "TIB": 1024**4,
}
_SIZE_RE = re.compile(r"\s*(\d+(?:\.\d+)?)\s*([A-Za-z]+)\s*")
_HOSTNAME_RE = re.compile(r"(?=.{1,253}\Z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")
_PROFILE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


class ConfigError(Exception):
    """A profile is missing, unreadable or invalid. The message lists every problem."""


def parse_size(text: str) -> int:
    """Parse a size such as ``"19.5GB"`` into bytes. Units are binary: 1GB = 1024**3 bytes."""
    match = _SIZE_RE.fullmatch(text)
    if not match or match.group(2).upper() not in _SIZE_UNITS:
        raise ValueError(f'invalid size "{text}" (expected a number and a unit, e.g. "19.5GB")')
    return int(float(match.group(1)) * _SIZE_UNITS[match.group(2).upper()])


@dataclass(frozen=True)
class ModelConfig:
    id: str


@dataclass(frozen=True)
class BackendConfig:
    port: int
    prefill_step_size: int
    prompt_cache_size: int
    prompt_cache_bytes: int
    metal_memory_limit: int


@dataclass(frozen=True)
class GatewayConfig:
    port: int
    max_context: int
    max_output_tokens: int
    min_output_tokens: int
    queue_size: int
    heartbeat_seconds: int


@dataclass(frozen=True)
class TunnelConfig:
    enabled: bool
    hostname: str


@dataclass(frozen=True)
class SystemConfig:
    gpu_wired_limit_mb: int


@dataclass(frozen=True)
class Profile:
    name: str
    path: Path
    model: ModelConfig
    backend: BackendConfig
    gateway: GatewayConfig
    tunnel: TunnelConfig
    system: SystemConfig


class _Section:
    """Reads typed fields from one table, collecting errors instead of stopping at the first."""

    def __init__(self, name: str, table: Any, errors: list[str]) -> None:
        self.name = name
        self.errors = errors
        self.seen: set[str] = set()
        if table is None:
            errors.append(f"missing section [{name}]")
            self.table: dict[str, Any] = {}
            self.valid = False
        elif not isinstance(table, dict):
            errors.append(f"[{name}] must be a table")
            self.table = {}
            self.valid = False
        else:
            self.table = table
            self.valid = True

    def _get(self, key: str) -> Any:
        self.seen.add(key)
        if key not in self.table:
            if self.valid:
                self.errors.append(f"[{self.name}] {key}: missing")
            return None
        return self.table[key]

    def _fail(self, key: str, message: str) -> None:
        self.errors.append(f"[{self.name}] {key}: {message}")

    def integer(self, key: str, minimum: int | None = None, maximum: int | None = None) -> int:
        value = self._get(key)
        if value is None:
            return 0
        if isinstance(value, bool) or not isinstance(value, int):
            self._fail(key, f"expected an integer, got {value!r}")
            return 0
        if minimum is not None and value < minimum:
            self._fail(key, f"must be at least {minimum}, got {value}")
        if maximum is not None and value > maximum:
            self._fail(key, f"must be at most {maximum}, got {value}")
        return value

    def string(self, key: str, check: Callable[[str], str | None] | None = None) -> str:
        value = self._get(key)
        if value is None:
            return ""
        if not isinstance(value, str) or not value:
            self._fail(key, f"expected a non-empty string, got {value!r}")
            return ""
        if check is not None and (problem := check(value)):
            self._fail(key, problem)
        return value

    def boolean(self, key: str) -> bool:
        value = self._get(key)
        if value is None:
            return False
        if not isinstance(value, bool):
            self._fail(key, f"expected true or false, got {value!r}")
            return False
        return value

    def size(self, key: str) -> int:
        value = self._get(key)
        if value is None:
            return 0
        if not isinstance(value, str):
            self._fail(key, f'expected a size string such as "2GB", got {value!r}')
            return 0
        try:
            size = parse_size(value)
        except ValueError as exc:
            self._fail(key, str(exc))
            return 0
        if size <= 0:
            self._fail(key, f"must be greater than zero, got {value!r}")
        return size

    def finish(self) -> None:
        for key in sorted(set(self.table) - self.seen):
            self._fail(key, "unknown field")


def _check_hostname(value: str) -> str | None:
    if _HOSTNAME_RE.fullmatch(value):
        return None
    return f'"{value}" is not a valid hostname (expected something like "api.example.com")'


def parse_profile(name: str, path: Path, data: dict[str, Any]) -> Profile:
    """Validate parsed TOML; raises ConfigError naming the file and every bad field."""
    errors: list[str] = []
    known_sections = {"model", "backend", "gateway", "tunnel", "system"}
    for section in sorted(set(data) - known_sections):
        errors.append(f"unknown section [{section}]")

    s = _Section("model", data.get("model"), errors)
    model = ModelConfig(id=s.string("id"))
    s.finish()

    s = _Section("backend", data.get("backend"), errors)
    backend = BackendConfig(
        port=s.integer("port", 1024, 65535),
        prefill_step_size=s.integer("prefill_step_size", 1),
        prompt_cache_size=s.integer("prompt_cache_size", 0),
        prompt_cache_bytes=s.size("prompt_cache_bytes"),
        metal_memory_limit=s.size("metal_memory_limit"),
    )
    s.finish()

    s = _Section("gateway", data.get("gateway"), errors)
    gateway = GatewayConfig(
        port=s.integer("port", 1024, 65535),
        max_context=s.integer("max_context", 1),
        max_output_tokens=s.integer("max_output_tokens", 1),
        min_output_tokens=s.integer("min_output_tokens", 1),
        queue_size=s.integer("queue_size", 0),
        heartbeat_seconds=s.integer("heartbeat_seconds", 1, CLOUDFLARE_IDLE_TIMEOUT_SECONDS - 1),
    )
    s.finish()

    s = _Section("tunnel", data.get("tunnel"), errors)
    tunnel = TunnelConfig(
        enabled=s.boolean("enabled"), hostname=s.string("hostname", _check_hostname)
    )
    s.finish()

    s = _Section("system", data.get("system"), errors)
    system = SystemConfig(gpu_wired_limit_mb=s.integer("gpu_wired_limit_mb", 1))
    s.finish()

    # Cross-field rules, only meaningful once the individual fields are valid.
    if not errors:
        if backend.port == gateway.port:
            errors.append(f"[backend] port and [gateway] port must differ (both {gateway.port})")
        if gateway.min_output_tokens >= gateway.max_context:
            errors.append(
                f"[gateway] min_output_tokens ({gateway.min_output_tokens}) must be less than "
                f"max_context ({gateway.max_context})"
            )
        if gateway.min_output_tokens > gateway.max_output_tokens:
            errors.append(
                f"[gateway] min_output_tokens ({gateway.min_output_tokens}) must not exceed "
                f"max_output_tokens ({gateway.max_output_tokens})"
            )
        if gateway.max_output_tokens > gateway.max_context:
            errors.append(
                f"[gateway] max_output_tokens ({gateway.max_output_tokens}) must not exceed "
                f"max_context ({gateway.max_context})"
            )
        wired_bytes = system.gpu_wired_limit_mb * 1024**2
        if backend.metal_memory_limit >= wired_bytes:
            errors.append(
                f"[backend] metal_memory_limit must be below [system] gpu_wired_limit_mb "
                f"({system.gpu_wired_limit_mb} MB)"
            )

    if errors:
        details = "\n".join(f"  - {e}" for e in errors)
        raise ConfigError(f"invalid profile {path}:\n{details}")

    return Profile(
        name=name,
        path=path,
        model=model,
        backend=backend,
        gateway=gateway,
        tunnel=tunnel,
        system=system,
    )


def profile_names() -> list[str]:
    return sorted(p.stem for p in paths.profiles_dir().glob("*.toml"))


def load_profile(name: str = DEFAULT_PROFILE) -> Profile:
    """Load ``config/profiles/<name>.toml``."""
    if not _PROFILE_NAME_RE.fullmatch(name):
        raise ConfigError(f'invalid profile name "{name}"')
    path = paths.profiles_dir() / f"{name}.toml"
    if not path.is_file():
        available = ", ".join(profile_names()) or "none"
        raise ConfigError(f'profile "{name}" not found at {path} (available: {available})')
    try:
        with path.open("rb") as f:
            data = tomllib.load(f)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"cannot parse {path}: {exc}") from exc
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc}") from exc
    return parse_profile(name, path, data)
