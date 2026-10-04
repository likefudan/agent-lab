"""The ``alab`` command line.

Built on argparse: it is in the standard library, so the CLI adds no
dependencies to the offline bundle and starts quickly, and subcommands
(``alab keys create``, ``alab gpu-limit apply``) need nothing more.
"""

from __future__ import annotations

import argparse
import platform
import sys

from agent_lab import __version__, doctor, paths


def _cmd_version(args: argparse.Namespace) -> int:
    print(f"agent-lab {__version__} (Python {platform.python_version()}, {sys.executable})")
    return 0


def _cmd_doctor(args: argparse.Namespace) -> int:
    return doctor.main()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="alab", description="Run Qwen3.8-27B locally with mlx-lm behind an API gateway."
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>", required=True)
    sub.add_parser("version", help="print the agent-lab version").set_defaults(func=_cmd_version)
    sub.add_parser("doctor", help="check the machine and the toolchain").set_defaults(
        func=_cmd_doctor
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    paths.ensure_layout()
    result: int = args.func(args)
    return result
