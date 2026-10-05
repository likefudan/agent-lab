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


def models_toml() -> Path:
    return config_dir() / "models.toml"


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


def backend_log() -> Path:
    """The backend's own log, rotated at midnight (older days get a date suffix)."""
    return logs_dir() / "backend.log"


def backend_console_log() -> Path:
    """Raw stdout/stderr of the last backend run: crashes from native code end up here."""
    return logs_dir() / "backend.console.log"


def backend_state() -> Path:
    """pid, port and profile of the backend started by ``alab serve``."""
    return run_dir() / "backend.json"


def backend_ready() -> Path:
    """Written by the backend once the model is loaded."""
    return run_dir() / "backend.ready.json"


def backend_lock() -> Path:
    return run_dir() / "backend.lock"


def bench_dir() -> Path:
    return var_dir() / "bench"


def secrets_dir() -> Path:
    return var_dir() / "secrets"


def cache_dir() -> Path:
    return var_dir() / "cache"


def ensure_layout() -> None:
    """Create any missing ``var/`` directories; a new ``var/secrets`` gets mode 700.

    An existing ``var/secrets`` is left as it is, so that ``alab doctor`` can
    report a wrong mode instead of it being fixed silently.
    """
    for directory in (models_dir(), logs_dir(), run_dir(), bench_dir(), cache_dir()):
        directory.mkdir(parents=True, exist_ok=True)
    secrets = secrets_dir()
    try:
        secrets.mkdir(mode=SECRETS_MODE)
    except FileExistsError:
        return
    # mkdir's mode is filtered by the umask.
    secrets.chmod(SECRETS_MODE)
