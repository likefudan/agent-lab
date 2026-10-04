from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

from agent_lab import paths

from .conftest import REPO_ROOT


def test_home_defaults_to_repo_root(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("AGENT_LAB_HOME", raising=False)
    assert paths.home() == REPO_ROOT


def test_every_path_derives_from_home(lab_home: Path) -> None:
    assert paths.home() == lab_home.resolve()
    expected = {
        paths.models_dir(): "var/models",
        paths.logs_dir(): "var/logs",
        paths.run_dir(): "var/run",
        paths.bench_dir(): "var/bench",
        paths.secrets_dir(): "var/secrets",
        paths.cache_dir(): "var/cache",
        paths.tools_dir(): ".tools",
        paths.tools_bin_dir(): ".tools/bin",
        paths.tools_python_dir(): ".tools/python",
        paths.venv_dir(): ".venv",
        paths.profiles_dir(): "config/profiles",
        paths.tools_toml(): "config/tools.toml",
    }
    for path, relative in expected.items():
        assert path == lab_home.resolve() / relative


def test_ensure_layout_creates_var_with_private_secrets(lab_home: Path) -> None:
    old_umask = os.umask(0)
    try:
        paths.ensure_layout()
    finally:
        os.umask(old_umask)
    for name in ("models", "logs", "run", "bench", "cache"):
        assert (lab_home / "var" / name).is_dir()
    assert (lab_home / "var/secrets").stat().st_mode & 0o777 == 0o700


def test_ensure_layout_leaves_existing_secrets_dir_for_doctor(lab_home: Path) -> None:
    secrets = lab_home / "var/secrets"
    secrets.mkdir(parents=True)
    secrets.chmod(0o755)
    paths.ensure_layout()
    assert secrets.stat().st_mode & 0o777 == 0o755


def test_no_other_module_builds_project_paths() -> None:
    pattern = re.compile(r"__file__|[\"']var/|[\"']\.tools|[\"']\.venv|AGENT_LAB_HOME")
    package = REPO_ROOT / "src/agent_lab"
    offenders = [
        f"{source.name}:{number}: {line.strip()}"
        for source in sorted(package.glob("*.py"))
        if source.name != "paths.py"
        for number, line in enumerate(source.read_text().splitlines(), 1)
        if pattern.search(line)
    ]
    assert offenders == []
