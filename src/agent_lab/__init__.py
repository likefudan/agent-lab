"""agent-lab: self-contained local LLM serving on Apple Silicon."""

from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("agent-lab")
except PackageNotFoundError:  # running from a source tree without installing
    __version__ = "0+unknown"
