from __future__ import annotations

import stat
from pathlib import Path

import pytest

from agent_lab import cli, paths
from agent_lab.gateway import keys


def test_create_stores_only_a_hash(lab_home: Path) -> None:
    key = keys.create("cursor")
    assert key.startswith(keys.KEY_PREFIX) and len(key) > 40
    text = paths.keys_file().read_text()
    assert key not in text
    assert keys.hash_key(key) in text
    assert stat.S_IMODE(paths.keys_file().stat().st_mode) == 0o600
    assert stat.S_IMODE(paths.secrets_dir().stat().st_mode) == 0o700
    assert [e.name for e in keys.load()] == ["cursor"]
    assert keys.create("opencode") != key


def test_names_are_checked(lab_home: Path) -> None:
    keys.create("cursor")
    with pytest.raises(keys.KeysError, match="already exists"):
        keys.create("cursor")
    for bad in ("", "Cursor", "a b", "x" * 65, "-x", 'a"b'):
        with pytest.raises(keys.KeysError, match="invalid key name"):
            keys.create(bad)
    with pytest.raises(keys.KeysError, match='no key named "nope"'):
        keys.revoke("nope")


def test_store_follows_the_file(lab_home: Path) -> None:
    store = keys.KeyStore()
    assert store.check("anything") is None  # no file yet
    first = keys.create("first")
    assert store.check(first) == "first"
    second = keys.create("second")
    assert store.check(second) == "second"
    keys.revoke("first")
    assert store.check(first) is None
    assert store.check(second) == "second"
    assert store.check("") is None
    assert store.check(second + "x") is None


def test_broken_file_accepts_no_key(lab_home: Path) -> None:
    key = keys.create("first")
    store = keys.KeyStore()
    assert store.check(key) == "first"
    paths.keys_file().write_text("[keys.first\nhash = ")
    assert store.check(key) is None
    with pytest.raises(keys.KeysError, match="cannot read"):
        keys.load()


def test_cli(lab_home: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert cli.main(["keys"]) == 0
    assert "no keys" in capsys.readouterr().out
    assert cli.main(["keys", "create", "opencode"]) == 0
    out = capsys.readouterr().out
    key = next(word for word in out.split() if word.startswith(keys.KEY_PREFIX))
    assert keys.KeyStore().check(key) == "opencode"
    assert cli.main(["keys", "list"]) == 0
    listing = capsys.readouterr().out
    assert "opencode" in listing and key not in listing
    assert cli.main(["keys", "create", "opencode"]) == 1
    assert "already exists" in capsys.readouterr().err
    assert cli.main(["keys", "revoke", "opencode"]) == 0
    assert keys.load() == []
