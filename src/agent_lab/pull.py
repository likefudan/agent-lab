"""Download and verify registry models into ``var/models/<id>/`` (``alab pull``, ``alab models``).

Layout of a model directory::

    var/models/<id>/<files>             the repository files, exactly as listed in the registry
    var/models/<id>/.alab/state.json    files already verified: size, mtime and sha256
    var/models/<id>/.alab/partial/      interrupted downloads, named <sha256>.part
    var/models/<id>/.alab/lock          held while a pull runs

Downloads use the Hugging Face client's HTTP session and headers (so
``HF_TOKEN`` and the proxy settings it honours apply), but not
``hf_hub_download``: since huggingface_hub 2.x it deletes partial files on
failure, and this command must resume a 16GB download after Ctrl-C. Each file
is fetched from the pinned commit with an HTTP Range request starting where
the partial file ends, then hashed before it is moved into place.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import shutil
import sys
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import IO, Any

from agent_lab import paths
from agent_lab.registry import ModelEntry, ModelFile, format_size

STATE_DIR = ".alab"
DISK_MARGIN = 512 * 1024**2  # free space to leave after the download
CHUNK = 1024**2
RETRIES = 3
CONNECT_TIMEOUT = 30.0
READ_TIMEOUT = 120.0


class PullError(Exception):
    pass


class LocalState(StrEnum):
    NOT_DOWNLOADED = "not downloaded"
    INCOMPLETE = "incomplete"
    UNVERIFIED = "unverified"
    DOWNLOADED = "downloaded"
    FAILED = "failed verification"


def model_dir(model_id: str) -> Path:
    return paths.models_dir() / model_id


def _state_dir(model_id: str) -> Path:
    return model_dir(model_id) / STATE_DIR


def _partial_path(model_id: str, f: ModelFile) -> Path:
    return _state_dir(model_id) / "partial" / f"{f.sha256}.part"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


# --- verification records -------------------------------------------------------


@dataclass
class _Records:
    """What ``.alab/state.json`` remembers, so unchanged files are not hashed again."""

    verified: dict[str, dict[str, Any]]  # name -> {"size", "mtime_ns", "sha256"}
    failed: list[str]  # names whose last download did not match the registry

    @classmethod
    def load(cls, model_id: str) -> _Records:
        path = _state_dir(model_id) / "state.json"
        try:
            data = json.loads(path.read_text())
            verified = data.get("verified", {})
            failed = data.get("failed", [])
            if isinstance(verified, dict) and isinstance(failed, list):
                return cls(verified, [str(n) for n in failed])
        except OSError, ValueError, AttributeError:
            pass
        return cls({}, [])

    def save(self, model_id: str) -> None:
        path = _state_dir(model_id) / "state.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name("state.json.tmp")
        tmp.write_text(json.dumps({"verified": self.verified, "failed": self.failed}, indent=2))
        tmp.replace(path)

    def known_sha256(self, path: Path, name: str) -> str | None:
        """The recorded sha256 of ``path`` if it has not changed since it was hashed."""
        record = self.verified.get(name)
        if not isinstance(record, dict):
            return None
        try:
            st = path.stat()
        except OSError:
            return None
        if record.get("size") == st.st_size and record.get("mtime_ns") == st.st_mtime_ns:
            sha = record.get("sha256")
            return sha if isinstance(sha, str) else None
        return None

    def remember(self, path: Path, name: str, sha256: str) -> None:
        st = path.stat()
        self.verified[name] = {"size": st.st_size, "mtime_ns": st.st_mtime_ns, "sha256": sha256}
        if name in self.failed:
            self.failed.remove(name)

    def forget(self, name: str) -> None:
        self.verified.pop(name, None)


def local_state(entry: ModelEntry) -> LocalState:
    """The model's state from files on disk and the verification records, without hashing."""
    root = model_dir(entry.id)
    records = _Records.load(entry.id)
    if any(f.name in records.failed for f in entry.files):
        return LocalState.FAILED
    present = [f for f in entry.files if (root / f.name).is_file()]
    if len(present) == len(entry.files):
        if all(records.known_sha256(root / f.name, f.name) == f.sha256 for f in present):
            return LocalState.DOWNLOADED
        return LocalState.UNVERIFIED
    partial_dir = _state_dir(entry.id) / "partial"
    if present or (partial_dir.is_dir() and any(partial_dir.iterdir())):
        return LocalState.INCOMPLETE
    return LocalState.NOT_DOWNLOADED


# --- downloading ----------------------------------------------------------------


class _Progress:
    """A single updating line on a terminal; silent otherwise (CI logs get one line per file)."""

    def __init__(self, name: str, total: int, start: int, stream: IO[str]) -> None:
        self.name, self.total, self.done, self.stream = name, total, start, stream
        self.tty = stream.isatty()
        self.started = time.monotonic()
        self.start_bytes = start
        self.last = 0.0

    def update(self, n: int) -> None:
        self.done += n
        now = time.monotonic()
        if self.tty and now - self.last >= 0.5:
            self.last = now
            rate = (self.done - self.start_bytes) / max(now - self.started, 1e-6)
            pct = 100 * self.done / self.total if self.total else 100.0
            self.stream.write(
                f"\r  {self.name}: {format_size(self.done)} / {format_size(self.total)} "
                f"({pct:.0f}%, {format_size(int(rate))}/s)   "
            )
            self.stream.flush()

    def close(self) -> None:
        if self.tty:
            self.stream.write("\r\033[K")
            self.stream.flush()


class _RateLimiter:
    def __init__(self, bytes_per_second: int | None) -> None:
        self.rate = bytes_per_second
        self.started = time.monotonic()
        self.sent = 0

    def wait(self, n: int) -> None:
        if not self.rate:
            return
        self.sent += n
        ahead = self.sent / self.rate - (time.monotonic() - self.started)
        if ahead > 0:
            time.sleep(ahead)


# fetch(url, offset) yields (status_code, chunks); status 206 means the server honoured the range.
Fetcher = Callable[[str, int], contextlib.AbstractContextManager[tuple[int, Iterator[bytes]]]]


@contextlib.contextmanager
def _hf_fetch(url: str, offset: int) -> Iterator[tuple[int, Iterator[bytes]]]:
    import httpx2
    from huggingface_hub.utils import build_hf_headers, get_session, hf_raise_for_status

    headers = build_hf_headers()
    if offset:
        headers["Range"] = f"bytes={offset}-"
    timeout = httpx2.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT)
    with get_session().stream("GET", url, headers=headers, timeout=timeout) as response:
        hf_raise_for_status(response)
        yield response.status_code, response.iter_bytes(CHUNK)


def _transient_errors() -> tuple[type[BaseException], ...]:
    import httpx2

    return (httpx2.TransportError, OSError)


def file_url(entry: ModelEntry, f: ModelFile, endpoint: str | None = None) -> str:
    from huggingface_hub import hf_hub_url

    return hf_hub_url(entry.repo, f.name, revision=entry.revision, endpoint=endpoint)


def _download(
    url: str,
    partial: Path,
    f: ModelFile,
    fetch: Fetcher,
    limiter: _RateLimiter,
    out: IO[str],
    transient: tuple[type[BaseException], ...],
) -> None:
    """Fetch ``url`` into ``partial`` until it has ``f.size`` bytes, resuming what is there."""
    partial.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, RETRIES + 1):
        offset = partial.stat().st_size if partial.exists() else 0
        if offset > f.size:
            partial.unlink()
            offset = 0
        if offset == f.size:
            return
        if offset:
            print(
                f"  {f.name}: resuming at {format_size(offset)} of {format_size(f.size)}", file=out
            )
        progress = _Progress(f.name, f.size, offset, out)
        try:
            with fetch(url, offset) as (status, chunks):
                if offset and status != 206:
                    print(f"  {f.name}: server ignored the range; starting over", file=out)
                    offset = 0
                    progress = _Progress(f.name, f.size, 0, out)
                with partial.open("ab" if offset else "wb") as fh:
                    for chunk in chunks:
                        fh.write(chunk)
                        progress.update(len(chunk))
                        limiter.wait(len(chunk))
                        if fh.tell() > f.size:
                            break
        except transient as exc:
            progress.close()
            if attempt == RETRIES:
                raise PullError(
                    f"{f.name}: download failed after {RETRIES} attempts: {exc}"
                ) from exc
            print(f"  {f.name}: {exc}; retrying ({attempt}/{RETRIES - 1})", file=out)
            time.sleep(2**attempt)
            continue
        progress.close()
        size = partial.stat().st_size
        if size == f.size:
            return
        if size > f.size:
            partial.unlink()
            raise PullError(f"{f.name}: server sent more than the expected {f.size} bytes")
        if attempt == RETRIES:
            raise PullError(f"{f.name}: download stopped at {size} of {f.size} bytes")
        print(f"  {f.name}: connection closed early; retrying ({attempt}/{RETRIES - 1})", file=out)


@contextlib.contextmanager
def _pull_lock(model_id: str) -> Iterator[None]:
    lock_path = _state_dir(model_id) / "lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PullError(f"another `alab pull {model_id}` is running") from exc
        yield


def _remove_stray_partials(entry: ModelEntry) -> None:
    """Delete partial downloads that no file of ``entry`` refers to (an older revision's)."""
    partial_dir = _state_dir(entry.id) / "partial"
    if not partial_dir.is_dir():
        return
    wanted = {f"{f.sha256}.part" for f in entry.files}
    for p in partial_dir.iterdir():
        if p.name not in wanted:
            p.unlink()


@dataclass(frozen=True)
class PullResult:
    downloaded_bytes: int
    seconds: float
    disk_usage: int


def _disk_usage(root: Path) -> int:
    return sum(p.stat().st_blocks * 512 for p in root.rglob("*") if p.is_file())


def pull(
    entry: ModelEntry,
    *,
    recheck: bool = False,
    limit_rate: int | None = None,
    fetch: Fetcher | None = None,
    endpoint: str | None = None,
    out: IO[str] = sys.stdout,
) -> PullResult:
    """Make ``var/models/<id>/`` hold exactly the registry's files, verified.

    Files whose recorded hash matches are skipped (``recheck`` hashes them again).
    A file that does not match the registry, before or after downloading, is
    deleted; a mismatch after downloading fails the pull once every file has been tried.
    """
    root = model_dir(entry.id)
    root.mkdir(parents=True, exist_ok=True)
    transient = _transient_errors() if fetch is None else (OSError,)
    fetch = fetch or _hf_fetch
    started = time.monotonic()
    with _pull_lock(entry.id):
        _remove_stray_partials(entry)
        records = _Records.load(entry.id)

        # 1. Which files are already in place and verified?
        missing: list[ModelFile] = []
        for f in entry.files:
            target = root / f.name
            if not target.is_file():
                records.forget(f.name)
                missing.append(f)
                continue
            known = None if recheck else records.known_sha256(target, f.name)
            if known is None:
                print(f"  {f.name}: verifying existing file", file=out)
                known = sha256_file(target)
                records.remember(target, f.name, known)
            if known == f.sha256:
                continue
            print(f"  {f.name}: does not match the registry; downloading it again", file=out)
            target.unlink()
            records.forget(f.name)
            missing.append(f)
        records.save(entry.id)

        # 2. Is there room for the rest?
        remaining = 0
        for f in missing:
            partial = _partial_path(entry.id, f)
            have = partial.stat().st_size if partial.exists() else 0
            remaining += f.size - have if have <= f.size else f.size
        free = shutil.disk_usage(root).free
        if remaining + DISK_MARGIN > free:
            raise PullError(
                f"not enough disk space at {root}: need {format_size(remaining)} plus "
                f"{format_size(DISK_MARGIN)} headroom, {format_size(free)} free"
            )
        if missing:
            print(
                f"downloading {len(missing)} of {len(entry.files)} files "
                f"({format_size(remaining)}) from {entry.repo}@{entry.revision[:12]}",
                file=out,
            )

        # 3. Download, verify, move into place.
        limiter = _RateLimiter(limit_rate)
        mismatched: list[str] = []
        for f in missing:
            partial = _partial_path(entry.id, f)
            _download(file_url(entry, f, endpoint), partial, f, fetch, limiter, out, transient)
            actual = sha256_file(partial)
            if actual != f.sha256:
                partial.unlink()
                if f.name not in records.failed:
                    records.failed.append(f.name)
                records.save(entry.id)
                print(f"  {f.name}: FAILED verification (sha256 {actual}); deleted", file=out)
                mismatched.append(f.name)
                continue
            target = root / f.name
            target.parent.mkdir(parents=True, exist_ok=True)
            partial.replace(target)
            records.remember(target, f.name, actual)
            records.save(entry.id)
            print(f"  {f.name}: {format_size(f.size)}, sha256 verified", file=out)

        if mismatched:
            raise PullError(
                f"{len(mismatched)} file(s) did not match the sha256 in the registry and were "
                f"deleted: {', '.join(mismatched)}"
            )
        records.failed = []
        records.save(entry.id)
    seconds = time.monotonic() - started
    return PullResult(remaining, seconds, _disk_usage(root))
