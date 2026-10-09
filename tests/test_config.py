from __future__ import annotations

import tomllib
from pathlib import Path
from typing import Any

import pytest

from agent_lab import config
from agent_lab.config import ConfigError, load_profile, parse_profile, parse_size

from .conftest import REPO_ROOT

GIB = 1024**3


def _default_data() -> dict[str, Any]:
    with (REPO_ROOT / "config/profiles/mac-24gb.toml").open("rb") as f:
        return tomllib.load(f)


def _errors(data: dict[str, Any]) -> str:
    with pytest.raises(ConfigError) as excinfo:
        parse_profile("test", Path("test.toml"), data)
    return str(excinfo.value)


def test_default_profile_loads(lab_home: Path) -> None:
    profile = load_profile()
    assert profile.name == "mac-24gb"
    assert profile.model.id == "qwen3.8-27b-mlx-4bit"
    assert profile.backend.port == 8100
    assert profile.backend.metal_memory_limit == int(19.5 * GIB)
    assert profile.backend.prompt_cache_bytes == int(2.2 * GIB)
    assert profile.gateway.port == 8000
    assert profile.gateway.max_context == 32768
    assert profile.gateway.heartbeat_seconds == 15
    assert profile.tunnel.enabled is True
    assert profile.tunnel.hostname == "api.llmat.dev"
    assert profile.system.gpu_wired_limit_mb == 20480


def test_every_committed_profile_is_valid(lab_home: Path) -> None:
    names = config.profile_names()
    assert "mac-24gb" in names
    for name in names:
        load_profile(name)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("19.5GB", int(19.5 * GIB)),
        ("2.2GB", int(2.2 * GIB)),
        ("512MB", 512 * 1024**2),
        ("1 GiB", GIB),
        ("100b", 100),
    ],
)
def test_parse_size(text: str, expected: int) -> None:
    assert parse_size(text) == expected


@pytest.mark.parametrize("text", ["", "GB", "19.5", "19.5 XB", "-1GB", "1e3GB", "1GB\nx"])
def test_parse_size_rejects(text: str) -> None:
    with pytest.raises(ValueError, match="invalid size"):
        parse_size(text)


def test_missing_field_and_section() -> None:
    data = _default_data()
    del data["gateway"]["max_context"]
    del data["tunnel"]
    message = _errors(data)
    assert "test.toml" in message
    assert "[gateway] max_context: missing" in message
    assert "missing section [tunnel]" in message


def test_wrong_types_are_all_reported() -> None:
    data = _default_data()
    data["backend"]["port"] = "8100"
    data["gateway"]["queue_size"] = True
    data["tunnel"]["enabled"] = "yes"
    data["backend"]["metal_memory_limit"] = 19
    message = _errors(data)
    assert "[backend] port: expected an integer, got '8100'" in message
    assert "[gateway] queue_size: expected an integer, got True" in message
    assert "[tunnel] enabled: expected true or false, got 'yes'" in message
    assert '[backend] metal_memory_limit: expected a size string such as "2GB"' in message


def test_unknown_fields_and_sections() -> None:
    data = _default_data()
    data["gateway"]["max_contxt"] = 1
    data["extra"] = {}
    message = _errors(data)
    assert "[gateway] max_contxt: unknown field" in message
    assert "unknown section [extra]" in message


def test_section_must_be_a_table() -> None:
    data = _default_data()
    data["model"] = "qwen"
    assert "[model] must be a table" in _errors(data)


@pytest.mark.parametrize(
    ("section", "key", "value", "expected"),
    [
        ("backend", "port", 80, "[backend] port: must be at least 1024, got 80"),
        ("gateway", "port", 70000, "[gateway] port: must be at most 65535, got 70000"),
        ("gateway", "heartbeat_seconds", 100, "must be at most 99"),
        ("gateway", "queue_size", -1, "must be at least 0"),
        ("tunnel", "hostname", "https://api.llmat.dev", "is not a valid hostname"),
        ("tunnel", "hostname", "api.llmat.dev\n", "is not a valid hostname"),
        ("model", "id", "", "expected a non-empty string"),
        ("backend", "prompt_cache_bytes", "0GB", "must be greater than zero"),
    ],
)
def test_field_ranges(section: str, key: str, value: Any, expected: str) -> None:
    data = _default_data()
    data[section][key] = value
    assert expected in _errors(data)


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        ({("backend", "port"): 8000}, "port and [gateway] port must differ"),
        ({("gateway", "min_output_tokens"): 32768}, "must be less than max_context"),
        (
            {("gateway", "min_output_tokens"): 4096, ("gateway", "max_output_tokens"): 2048},
            "must not exceed max_output_tokens",
        ),
        ({("gateway", "max_output_tokens"): 40000}, "must not exceed max_context"),
        ({("backend", "metal_memory_limit"): "20GB"}, "metal_memory_limit must be below"),
    ],
)
def test_cross_field_rules(changes: dict[tuple[str, str], Any], expected: str) -> None:
    data = _default_data()
    for (section, key), value in changes.items():
        data[section][key] = value
    assert expected in _errors(data)


def test_missing_profile_lists_available(lab_home: Path) -> None:
    with pytest.raises(
        ConfigError, match=r'profile "nope" not found .*available: ci-tiny, mac-24gb'
    ):
        load_profile("nope")


@pytest.mark.parametrize("name", ["../tools", "a/b", "", "mac-24gb\n"])
def test_profile_name_cannot_escape(lab_home: Path, name: str) -> None:
    with pytest.raises(ConfigError, match="invalid profile name"):
        load_profile(name)


def test_toml_syntax_error(lab_home: Path) -> None:
    (lab_home / "config/profiles/broken.toml").write_text("[gateway\nport = 1\n")
    with pytest.raises(ConfigError, match=r"cannot parse .*broken\.toml"):
        load_profile("broken")


def test_backend_launch_fields(lab_home: Path) -> None:
    backend = load_profile().backend
    assert backend.tool_parser == "qwen3_coder"
    assert backend.enable_thinking is False
    assert (backend.temperature, backend.top_p, backend.top_k) == (0.7, 0.8, 20)
    thinking = (backend.thinking_temperature, backend.thinking_top_p, backend.thinking_top_k)
    assert thinking == (0.6, 0.95, 20)
    assert backend.start_timeout_seconds == 600
    assert load_profile().gateway.model_name == "qwen3.8-27b"


@pytest.mark.parametrize(
    ("key", "value", "message"),
    [
        ("tool_parser", "../evil", "not a tool parser name"),
        ("temperature", 3.5, "must be between 0.0 and 2.0"),
        ("top_p", "0.8", "expected a number"),
        ("top_p", True, "expected a number"),
        ("top_k", -1, "must be at least 0"),
        ("enable_thinking", "no", "expected true or false"),
        ("start_timeout_seconds", 0, "must be at least 1"),
        ("thinking_temperature", 2.5, "must be between 0.0 and 2.0"),
        ("thinking_top_k", -1, "must be at least 0"),
    ],
)
def test_backend_launch_fields_are_validated(key: str, value: Any, message: str) -> None:
    data = _default_data()
    data["backend"][key] = value
    assert message in _errors(data)


@pytest.mark.parametrize("name", ["", "a b", "qwen/27b", "-x", "x" * 65])
def test_model_name_is_validated(name: str) -> None:
    data = _default_data()
    data["gateway"]["model_name"] = name
    assert "model_name" in _errors(data)


def test_integer_temperature_is_accepted() -> None:
    data = _default_data()
    data["backend"]["temperature"] = 1
    assert parse_profile("test", Path("test.toml"), data).backend.temperature == 1.0
