"""API keys: ``alab keys create / list / revoke`` and the gateway's checks (design section 6.3).

``var/secrets/keys.toml`` stores one table per key with the SHA-256 of the key,
never the key itself. Keys are 32 random bytes, so a plain hash is enough: there
is nothing to brute-force that a slow hash would protect.

The gateway re-reads the file whenever it changes (checked on every request),
so new and revoked keys take effect without a restart.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import hmac
import logging
import os
import re
import secrets
import tempfile
import tomllib
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from agent_lab import paths

log = logging.getLogger("agent_lab.gateway")

KEY_PREFIX = "sk-alab-"
KEY_BYTES = 32
FILE_MODE = 0o600
NAME_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
_HASH_RE = re.compile(r"sha256:[0-9a-f]{64}")


class KeysError(Exception):
    """A key command failed or ``keys.toml`` is invalid; the message says why."""


@dataclass(frozen=True)
class KeyEntry:
    name: str
    hash: str  # "sha256:<hex>"
    created: str  # ISO 8601, UTC


def hash_key(key: str) -> str:
    return "sha256:" + hashlib.sha256(key.encode()).hexdigest()


def load(path: Path | None = None) -> list[KeyEntry]:
    """The stored keys; an empty list if the file does not exist."""
    path = path or paths.keys_file()
    try:
        with path.open("rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        return []
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise KeysError(f"cannot read {path}: {exc}") from exc
    table = data.get("keys", {})
    if not isinstance(table, dict):
        raise KeysError(f"{path}: [keys] must be a table")
    entries = []
    for name, item in table.items():
        if (
            not NAME_RE.fullmatch(name)
            or not isinstance(item, dict)
            or not isinstance(item.get("hash"), str)
            or not _HASH_RE.fullmatch(item["hash"])
        ):
            raise KeysError(f"{path}: invalid entry [keys.{name}]")
        entries.append(KeyEntry(name, item["hash"], str(item.get("created", ""))))
    return entries


def _render(entries: list[KeyEntry]) -> str:
    lines = [
        "# API keys for the gateway, managed by `alab keys`. Only hashes are stored.",
        "",
    ]
    for entry in entries:
        lines += [
            f"[keys.{entry.name}]",
            f'hash = "{entry.hash}"',
            f'created = "{entry.created}"',
            "",
        ]
    return "\n".join(lines)


def _save(entries: list[KeyEntry], path: Path) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".keys.", suffix=".tmp")
    try:
        os.fchmod(fd, FILE_MODE)
        with os.fdopen(fd, "w") as f:
            f.write(_render(entries))
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


@contextlib.contextmanager
def _locked() -> Iterator[Path]:
    paths.ensure_layout()
    path = paths.keys_file()
    with (paths.secrets_dir() / "keys.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield path


def check_name(name: str) -> None:
    if not NAME_RE.fullmatch(name):
        raise KeysError(
            f'invalid key name "{name}": use lowercase letters, digits, "-" and "_" '
            "(up to 64 characters), e.g. cursor or opencode"
        )


def create(name: str) -> str:
    """Add a key named ``name`` and return it; only its hash is stored."""
    check_name(name)
    with _locked() as path:
        entries = load(path)
        if any(e.name == name for e in entries):
            raise KeysError(f'a key named "{name}" already exists; revoke it first')
        key = KEY_PREFIX + secrets.token_urlsafe(KEY_BYTES)
        created = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        _save([*entries, KeyEntry(name, hash_key(key), created)], path)
    return key


def revoke(name: str) -> None:
    with _locked() as path:
        entries = load(path)
        kept = [e for e in entries if e.name != name]
        if len(kept) == len(entries):
            raise KeysError(f'no key named "{name}"')
        _save(kept, path)


class KeyStore:
    """The gateway's view of ``keys.toml``, reloaded whenever the file changes."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or paths.keys_file()
        self._stamp: tuple[int, int, int] | None = None
        self._hashes: list[tuple[str, bytes]] = []

    def _refresh(self) -> None:
        try:
            st = self.path.stat()
            stamp = (st.st_ino, st.st_mtime_ns, st.st_size)
        except FileNotFoundError:
            stamp = None
        if stamp == self._stamp and stamp is not None:
            return
        try:
            entries = load(self.path)
        except KeysError as exc:
            # A broken file accepts no key at all: failing closed is the safe choice.
            log.error("%s; no key is accepted until it is fixed", exc)
            entries = []
        self._hashes = [(e.name, bytes.fromhex(e.hash.removeprefix("sha256:"))) for e in entries]
        self._stamp = stamp

    def check(self, key: str) -> str | None:
        """The name of the key, or None if it is not a valid key."""
        self._refresh()
        digest = hashlib.sha256(key.encode()).digest()
        found = None
        for name, stored in self._hashes:
            # Compare against every key, so the time taken does not depend on which matched.
            if hmac.compare_digest(digest, stored):
                found = name
        return found
