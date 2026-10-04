"""Every filesystem location agent-lab uses (design section 6.2).

All paths derive from ``AGENT_LAB_HOME``, which defaults to the repository root.
Other modules must get their paths from here instead of building their own.
"""

from __future__ import annotations

import os
from pathlib import Path

ENV_VAR = "AGENT_LAB_HOME"

SECRETS_MODE = 0o700

# src/agent_lab/paths.py -> repository root
_REPO_ROOT = Path(__file__).resolve().parents[2]


def home() -> Path:
    """The project directory: ``$AGENT_LAB_HOME``, or the repository root if unset."""
    value = os.environ.get(ENV_VAR)
    return Path(value).resolve() if value else _REPO_ROOT


def config_dir() -> Path:
    return home() / "config"


def profiles_dir() -> Path:
    return config_dir() / "profiles"


def tools_toml() -> Path:
    return config_dir() / "tools.toml"


def python_version_file() -> Path:
    return home() / ".python-version"


def tools_dir() -> Path:
    return home() / ".tools"


def tools_bin_dir() -> Path:
    return tools_dir() / "bin"


def tools_python_dir() -> Path:
    return tools_dir() / "python"


def tools_stamps_dir() -> Path:
    return tools_dir() / "stamps"


def env_sh() -> Path:
    return tools_dir() / "env.sh"


def venv_dir() -> Path:
    return home() / ".venv"


def var_dir() -> Path:
    return home() / "var"


def models_dir() -> Path:
    return var_dir() / "models"


def logs_dir() -> Path:
    return var_dir() / "logs"


def run_dir() -> Path:
    return var_dir() / "run"


def bench_dir() -> Path:
    return var_dir() / "bench"


def secrets_dir() -> Path:
    return var_dir() / "secrets"


def cache_dir() -> Path:
    return var_dir() / "cache"


def ensure_layout() -> None:
    """Create the ``var/`` directories; ``var/secrets`` always ends up mode 700."""
    for directory in (models_dir(), logs_dir(), run_dir(), bench_dir(), cache_dir()):
        directory.mkdir(parents=True, exist_ok=True)
    secrets = secrets_dir()
    secrets.mkdir(mode=SECRETS_MODE, parents=True, exist_ok=True)
    # mkdir's mode is filtered by the umask and ignored for existing directories.
    secrets.chmod(SECRETS_MODE)
