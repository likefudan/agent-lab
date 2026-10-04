from __future__ import annotations

import hashlib
import tomllib
from pathlib import Path
from typing import Any

import pytest

from agent_lab import paths, registry
from agent_lab.config import ConfigError, parse_size

SHA_A = hashlib.sha256(b"a").hexdigest()
REV = "0123456789abcdef0123456789abcdef01234567"


def _entry(**overrides: Any) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "id": "tiny",
        "description": "test model",
        "repo": "owner/tiny",
        "revision": REV,
        "disk_space": "0.1GB",
        "files": [{"name": "config.json", "size": 1, "sha256": SHA_A}],
    }
    entry.update(overrides)
    return entry


def _errors(data: dict[str, Any]) -> str:
    with pytest.raises(ConfigError) as excinfo:
        registry.parse_registry(Path("models.toml"), data)
    return str(excinfo.value)


def test_repository_registry_is_valid() -> None:
    entries = registry.load_registry(paths.models_toml())
    assert "qwen3.8-27b-mlx-4bit" in entries
    big = entries["qwen3.8-27b-mlx-4bit"]
    assert big.repo == "mlx-community/Qwen3.8-27B-4bit"
    assert any(f.name.endswith(".safetensors") for f in big.files)
    # The CI model is small enough to download on every CI run.
    small = [e for e in entries.values() if e.total_size < 1024**3]
    assert small, "no CI-sized model in the registry"


def test_repository_registry_is_in_generated_layout() -> None:
    text = paths.models_toml().read_text()
    entries = registry.load_registry(paths.models_toml())
    expected = registry.HEADER + "".join(
        "\n" + registry.render_entry(entries[k]) for k in sorted(entries)
    )
    assert text == expected


def test_parse_valid_entry() -> None:
    entries = registry.parse_registry(Path("m.toml"), {"model": [_entry()]})
    e = entries["tiny"]
    assert e.revision == REV
    assert e.files[0].name == "config.json"
    assert e.total_size == 1


@pytest.mark.parametrize(
    ("override", "message"),
    [
        ({"id": "Bad ID"}, "not a valid model id"),
        ({"repo": "noslash"}, "not a Hugging Face repository"),
        ({"revision": "main"}, "not a full commit hash"),
        ({"disk_space": "lots"}, "invalid size"),
        ({"files": []}, "non-empty list"),
        ({"files": [{"name": "../x", "size": 1, "sha256": SHA_A}]}, '".."'),
        ({"files": [{"name": "/etc/x", "size": 1, "sha256": SHA_A}]}, "relative path"),
        ({"files": [{"name": ".alab/state.json", "size": 1, "sha256": SHA_A}]}, "reserved"),
        ({"files": [{"name": "a", "size": -1, "sha256": SHA_A}]}, "non-negative"),
        ({"files": [{"name": "a", "size": 1, "sha256": "abc"}]}, "64 lowercase hex"),
        ({"files": [{"name": "a", "size": 1, "sha256": SHA_A, "x": 1}]}, "x: unknown field"),
        ({"files": [{"size": 1, "sha256": SHA_A}]}, "name: missing"),
        (
            {"files": [{"name": "a", "size": 1, "sha256": SHA_A}] * 2},
            "listed twice",
        ),
        (
            {"disk_space": "1MB", "files": [{"name": "a", "size": 2 * 1024**2, "sha256": SHA_A}]},
            "less than the files' total size",
        ),
        ({"extra": 1}, "extra: unknown field"),
    ],
)
def test_invalid_entries(override: dict[str, Any], message: str) -> None:
    assert message in _errors({"model": [_entry(**override)]})


def test_duplicate_ids_and_unknown_keys() -> None:
    assert "id: listed twice" in _errors({"model": [_entry(), _entry()]})
    assert "unknown top-level key" in _errors({"models": []})


def test_get_entry_unknown(lab_home: Path) -> None:
    with pytest.raises(ConfigError, match="not in the registry"):
        registry.get_entry("nope")


@pytest.mark.parametrize("total", [1, 1024**3, 1024**3 + 1, 17_293_000_000, 5 * 1024**3 - 1])
def test_disk_space_covers_total(total: int) -> None:
    text = registry.disk_space_for(total)
    assert parse_size(text) >= total
    assert parse_size(text) - total < 0.11 * 1024**3


def test_render_round_trip_and_write(tmp_path: Path) -> None:
    entry = registry.parse_registry(Path("m"), {"model": [_entry(description='say "hi"')]})["tiny"]
    parsed = registry.parse_registry(Path("m"), tomllib.loads(registry.render_entry(entry)))
    assert parsed["tiny"] == entry

    target = tmp_path / "models.toml"
    registry.write_entry(entry, target)
    other = registry.parse_registry(Path("m"), {"model": [_entry(id="another")]})["another"]
    registry.write_entry(other, target)
    changed = registry.parse_registry(Path("m"), {"model": [_entry(description="new")]})["tiny"]
    registry.write_entry(changed, target)
    loaded = registry.load_registry(target)
    assert list(loaded) == ["another", "tiny"]
    assert loaded["tiny"].description == "new"
    assert target.read_text().startswith(registry.HEADER)


@pytest.mark.parametrize(
    ("size", "text"),
    [
        (0, "0B"),
        (1023, "1023B"),
        (4932, "4.8KB"),
        (335_450_584, "319.9MB"),
        (16 * 1024**3, "16.0GB"),
    ],
)
def test_format_size(size: int, text: str) -> None:
    assert registry.format_size(size) == text
