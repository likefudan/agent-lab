from __future__ import annotations

import shutil
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def lab_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """An AGENT_LAB_HOME in a temporary directory, with the repository's config copied in."""
    home = tmp_path / "lab"
    home.mkdir()
    shutil.copytree(REPO_ROOT / "config", home / "config")
    shutil.copy(REPO_ROOT / ".python-version", home / ".python-version")
    monkeypatch.setenv("AGENT_LAB_HOME", str(home))
    return home
