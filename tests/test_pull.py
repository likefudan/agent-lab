from __future__ import annotations

import contextlib
import hashlib
import http.server
import io
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import Any, ClassVar

import pytest

from agent_lab import cli, pull, registry
from agent_lab.registry import ModelEntry, ModelFile

REV = "0123456789abcdef0123456789abcdef01234567"
CONTENT = {
    "config.json": b'{"model": "tiny"}',
    "weights/model.safetensors": bytes(range(256)) * 4000,  # ~1MB, several chunks
}


def _entry(content: dict[str, bytes] = CONTENT, shas: dict[str, str] | None = None) -> ModelEntry:
    shas = shas or {}
    files = tuple(
        ModelFile(name, len(data), shas.get(name, hashlib.sha256(data).hexdigest()))
        for name, data in content.items()
    )
    return ModelEntry("tiny", "test", "owner/tiny", REV, 1024**3, files)


class FakeHub:
    """A Fetcher serving CONTENT, honouring ranges, optionally failing mid-stream."""

    def __init__(self, content: dict[str, bytes] = CONTENT) -> None:
        self.content = content
        self.requests: list[tuple[str, int]] = []
        self.interrupt_after: int | None = None  # raise KeyboardInterrupt after this many bytes
        self.ignore_range = False
        self.chunk = 64 * 1024

    def name(self, url: str) -> str:
        return url.split(f"/resolve/{REV}/", 1)[1]

    @contextlib.contextmanager
    def __call__(self, url: str, offset: int) -> Iterator[tuple[int, Iterator[bytes]]]:
        name = self.name(url)
        self.requests.append((name, offset))
        data = self.content[name]
        if self.ignore_range:
            offset = 0
        status = 206 if offset else 200

        def chunks() -> Iterator[bytes]:
            sent = 0
            for i in range(offset, len(data), self.chunk):
                piece = data[i : i + self.chunk]
                if self.interrupt_after is not None and sent + len(piece) > self.interrupt_after:
                    yield piece[: self.interrupt_after - sent]
                    raise KeyboardInterrupt
                sent += len(piece)
                yield piece

        yield status, chunks()


def _pull(entry: ModelEntry, hub: FakeHub, **kwargs: Any) -> tuple[pull.PullResult, str]:
    out = io.StringIO()
    result = pull.pull(entry, fetch=hub, out=out, **kwargs)
    return result, out.getvalue()


def test_pull_downloads_and_verifies(lab_home: Path) -> None:
    entry, hub = _entry(), FakeHub()
    assert pull.local_state(entry) is pull.LocalState.NOT_DOWNLOADED
    result, out = _pull(entry, hub)
    root = lab_home / "var" / "models" / "tiny"
    for name, data in CONTENT.items():
        assert (root / name).read_bytes() == data
    assert "sha256 verified" in out
    assert result.downloaded_bytes == sum(len(d) for d in CONTENT.values())
    assert pull.local_state(entry) is pull.LocalState.DOWNLOADED
    assert not list((root / ".alab" / "partial").iterdir())


def test_second_pull_skips_without_hashing(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    entry, hub = _entry(), FakeHub()
    _pull(entry, hub)
    hub.requests.clear()
    monkeypatch.setattr(pull, "sha256_file", lambda p: pytest.fail("hashed again"))
    result, _ = _pull(entry, hub)
    assert hub.requests == []
    assert result.downloaded_bytes == 0


def test_existing_unrecorded_files_are_verified_not_downloaded(lab_home: Path) -> None:
    entry, hub = _entry(), FakeHub()
    root = lab_home / "var" / "models" / "tiny"
    for name, data in CONTENT.items():
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_bytes(data)
    assert pull.local_state(entry) is pull.LocalState.UNVERIFIED
    _, out = _pull(entry, hub)
    assert hub.requests == []
    assert "verifying existing file" in out
    assert pull.local_state(entry) is pull.LocalState.DOWNLOADED


def test_changed_file_is_replaced(lab_home: Path) -> None:
    entry, hub = _entry(), FakeHub()
    _pull(entry, hub)
    path = lab_home / "var" / "models" / "tiny" / "config.json"
    path.write_bytes(b"tampered")
    assert pull.local_state(entry) is pull.LocalState.UNVERIFIED
    hub.requests.clear()
    _, out = _pull(entry, hub)
    assert "does not match the registry" in out
    assert hub.requests == [("config.json", 0)]
    assert path.read_bytes() == CONTENT["config.json"]


def test_registry_hash_mismatch_fails_and_deletes(lab_home: Path) -> None:
    good, hub = _entry(), FakeHub()
    _pull(good, hub)
    bad = _entry(shas={"config.json": "f" * 64})
    with pytest.raises(pull.PullError, match="did not match the sha256"):
        _pull(bad, hub)
    root = lab_home / "var" / "models" / "tiny"
    assert not (root / "config.json").exists()
    assert (root / "weights" / "model.safetensors").exists()
    assert pull.local_state(bad) is pull.LocalState.FAILED
    # Back to the right registry: the file comes back and the failure is cleared.
    _pull(good, hub)
    assert pull.local_state(good) is pull.LocalState.DOWNLOADED


def test_interrupted_download_resumes(lab_home: Path) -> None:
    content = {"weights/model.safetensors": CONTENT["weights/model.safetensors"]}
    entry, hub = _entry(content), FakeHub(content)
    hub.interrupt_after = 300_000
    with pytest.raises(KeyboardInterrupt):
        _pull(entry, hub)
    assert pull.local_state(entry) is pull.LocalState.INCOMPLETE
    hub.interrupt_after = None
    result, out = _pull(entry, hub)
    assert hub.requests[-1] == ("weights/model.safetensors", 300_000)
    assert "resuming at" in out
    assert result.downloaded_bytes == len(content["weights/model.safetensors"]) - 300_000
    assert pull.local_state(entry) is pull.LocalState.DOWNLOADED


def test_server_ignoring_range_restarts(lab_home: Path) -> None:
    content = {"weights/model.safetensors": CONTENT["weights/model.safetensors"]}
    entry, hub = _entry(content), FakeHub(content)
    hub.interrupt_after = 300_000
    with pytest.raises(KeyboardInterrupt):
        _pull(entry, hub)
    hub.interrupt_after = None
    hub.ignore_range = True
    _, out = _pull(entry, hub)
    assert "starting over" in out
    assert pull.local_state(entry) is pull.LocalState.DOWNLOADED


def test_transient_errors_retry_then_fail(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("agent_lab.pull.time.sleep", lambda s: None)
    entry = _entry({"config.json": CONTENT["config.json"]})
    calls = []

    @contextlib.contextmanager
    def flaky(url: str, offset: int) -> Iterator[tuple[int, Iterator[bytes]]]:
        calls.append(offset)
        if len(calls) < 3:
            raise ConnectionResetError("reset")
        yield 200, iter([CONTENT["config.json"]])

    out = io.StringIO()
    pull.pull(entry, fetch=flaky, out=out)
    assert len(calls) == 3
    assert "retrying" in out.getvalue()

    entry2 = _entry({"config.json": CONTENT["config.json"]}, {"config.json": "e" * 64})
    calls.clear()

    @contextlib.contextmanager
    def dead(url: str, offset: int) -> Iterator[tuple[int, Iterator[bytes]]]:
        calls.append(offset)
        raise ConnectionResetError("reset")
        yield 200, iter([])  # pragma: no cover

    with pytest.raises(pull.PullError, match="after 3 attempts"):
        pull.pull(entry2, fetch=dead, out=io.StringIO())


def test_not_enough_disk_space(lab_home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "agent_lab.pull.shutil.disk_usage", lambda p: type("U", (), {"free": 1000})()
    )
    hub = FakeHub()
    with pytest.raises(pull.PullError, match="not enough disk space"):
        _pull(_entry(), hub)
    assert hub.requests == []


def test_concurrent_pull_is_refused(lab_home: Path) -> None:
    entry = _entry()
    with pull._pull_lock(entry.id), pytest.raises(pull.PullError, match="is running"):
        _pull(entry, FakeHub())


def test_stray_partials_are_removed(lab_home: Path) -> None:
    entry = _entry()
    stray = lab_home / "var" / "models" / "tiny" / ".alab" / "partial" / ("0" * 64 + ".part")
    stray.parent.mkdir(parents=True)
    stray.write_bytes(b"old revision")
    _pull(entry, FakeHub())
    assert not stray.exists()


# --- the real HTTP path, against a local server ------------------------------------


class _RangeHandler(http.server.BaseHTTPRequestHandler):
    content: ClassVar[dict[str, bytes]] = {}

    def do_GET(self) -> None:
        name = self.path.split(f"/resolve/{REV}/", 1)[1]
        data = self.content.get(name)
        if data is None:
            self.send_error(404)
            return
        start = 0
        if rng := self.headers.get("Range"):
            start = int(rng.removeprefix("bytes=").rstrip("-"))
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(data) - start))
        self.end_headers()
        self.wfile.write(data[start:])

    def log_message(self, *args: Any) -> None:
        pass


@pytest.fixture
def local_hub(monkeypatch: pytest.MonkeyPatch) -> Iterator[str]:
    for var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    _RangeHandler.content = CONTENT
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _RangeHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()


def test_http_download_resumes_with_range(lab_home: Path, local_hub: str) -> None:
    entry = _entry()
    big = next(f for f in entry.files if f.name.endswith(".safetensors"))
    partial = lab_home / "var" / "models" / "tiny" / ".alab" / "partial" / f"{big.sha256}.part"
    partial.parent.mkdir(parents=True)
    partial.write_bytes(CONTENT[big.name][:123_456])
    out = io.StringIO()
    pull.pull(entry, endpoint=local_hub, out=out)
    assert "resuming at" in out.getvalue()
    assert pull.local_state(entry) is pull.LocalState.DOWNLOADED


def test_http_404_is_reported(lab_home: Path, local_hub: str) -> None:
    entry = _entry({"missing.bin": b"x"})
    with pytest.raises(Exception, match="404"):
        pull.pull(entry, endpoint=local_hub, out=io.StringIO())


# --- CLI ------------------------------------------------------------------------------


def _write_registry(lab_home: Path, entry: ModelEntry) -> None:
    (lab_home / "config" / "models.toml").write_text(
        registry.HEADER + "\n" + registry.render_entry(entry)
    )


def test_cli_models_and_pull(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    entry = _entry()
    _write_registry(lab_home, entry)
    assert cli.main(["models"]) == 0
    assert "not downloaded" in capsys.readouterr().out

    hub = FakeHub()
    real_pull = pull.pull
    monkeypatch.setattr(pull, "pull", lambda e, **kw: real_pull(e, fetch=hub, **kw))
    assert cli.main(["pull", "tiny", "--limit-rate", "100MB"]) == 0
    assert "all 2 files verified" in capsys.readouterr().out
    assert cli.main(["models", "list"]) == 0
    assert "downloaded" in capsys.readouterr().out

    hub.interrupt_after = 10
    monkeypatch.setattr(pull, "pull", lambda e, **kw: real_pull(e, fetch=hub, recheck=True))
    (lab_home / "var" / "models" / "tiny" / "config.json").unlink()
    assert cli.main(["pull", "tiny"]) == 130
    assert "run the same command again to resume" in capsys.readouterr().err


def test_cli_pull_errors(lab_home: Path, capsys: pytest.CaptureFixture[str]) -> None:
    _write_registry(lab_home, _entry())
    assert cli.main(["pull", "nope"]) == 1
    assert "not in the registry" in capsys.readouterr().err
    assert cli.main(["pull", "tiny", "--limit-rate", "fast"]) == 1
    assert "invalid size" in capsys.readouterr().err
    # Without a model id, the default profile's model is used.
    assert cli.main(["pull"]) == 1
    assert "qwen3.8-27b-mlx-4bit" in capsys.readouterr().err


def test_cli_lock_prints_and_writes(
    lab_home: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_registry(lab_home, _entry())
    seen: dict[str, str] = {}

    def fake_lock(model_id: str, repo: str, revision: str, description: str) -> ModelEntry:
        seen.update(id=model_id, repo=repo, revision=revision, description=description)
        return ModelEntry(model_id, description, repo, REV, 1024**3, _entry().files)

    monkeypatch.setattr(registry, "lock_entry", fake_lock)
    assert cli.main(["models", "lock", "tiny", "--repo", "owner/tiny"]) == 0
    assert seen == {"id": "tiny", "repo": "owner/tiny", "revision": "main", "description": "test"}
    assert capsys.readouterr().out.startswith('[[model]]\nid = "tiny"')

    assert cli.main(["models", "lock", "new", "--repo", "o/n", "--write"]) == 0
    assert seen["description"] == "o/n"
    assert set(registry.load_registry()) == {"tiny", "new"}
