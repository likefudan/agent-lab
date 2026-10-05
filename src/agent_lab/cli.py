"""The ``alab`` command line.

Built on argparse: it is in the standard library, so the CLI adds no
dependencies to the offline bundle and starts quickly, and subcommands
(``alab keys create``, ``alab gpu-limit apply``) need nothing more.
"""

from __future__ import annotations

import argparse
import platform
import sys

from agent_lab import __version__, config, doctor, gpulimit, paths, pull, registry, serve
from agent_lab.backend import process


def _cmd_version(args: argparse.Namespace) -> int:
    print(f"agent-lab {__version__} (Python {platform.python_version()}, {sys.executable})")
    return 0


def _cmd_doctor(args: argparse.Namespace) -> int:
    return doctor.main()


def _cmd_pull(args: argparse.Namespace) -> int:
    try:
        model_id = args.model or config.load_profile(args.profile).model.id
        entry = registry.get_entry(model_id)
        limit = config.parse_size(args.limit_rate) if args.limit_rate else None
    except (config.ConfigError, ValueError) as exc:
        print(f"alab pull: {exc}", file=sys.stderr)
        return 1
    print(
        f"pulling {entry.id} ({registry.format_size(entry.total_size)}, {len(entry.files)} files)"
    )
    try:
        result = pull.pull(entry, recheck=args.recheck, limit_rate=limit)
    except KeyboardInterrupt:
        print("\ninterrupted; run the same command again to resume", file=sys.stderr)
        return 130
    except (pull.PullError, OSError) as exc:
        print(f"alab pull: {exc}", file=sys.stderr)
        return 1
    print(
        f"{entry.id}: all {len(entry.files)} files verified at {pull.model_dir(entry.id)} "
        f"(downloaded {registry.format_size(result.downloaded_bytes)} in {result.seconds:.0f}s, "
        f"disk usage {registry.format_size(result.disk_usage)})"
    )
    return 0


def _cmd_models_list(args: argparse.Namespace) -> int:
    try:
        entries = registry.load_registry()
    except config.ConfigError as exc:
        print(f"alab models: {exc}", file=sys.stderr)
        return 1
    rows = [("ID", "STATE", "SIZE", "SOURCE")]
    for entry in sorted(entries.values(), key=lambda e: e.id):
        rows.append(
            (
                entry.id,
                pull.local_state(entry).value,
                registry.format_size(entry.total_size),
                f"{entry.repo}@{entry.revision[:12]}",
            )
        )
    widths = [max(len(r[i]) for r in rows) for i in range(3)]
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r[:3], widths, strict=True)) + "  " + r[3])
    return 0


def _cmd_models_lock(args: argparse.Namespace) -> int:
    try:
        description = args.description
        if description is None:
            existing = registry.load_registry()
            entry = existing.get(args.model)
            description = entry.description if entry else args.repo
        entry = registry.lock_entry(args.model, args.repo, args.revision, description)
        if args.write:
            registry.write_entry(entry)
    except config.ConfigError as exc:
        print(f"alab models lock: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # network and Hugging Face errors
        print(f"alab models lock: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    if args.write:
        print(f"wrote {entry.id} ({entry.repo}@{entry.revision}) to {paths.models_toml()}")
    else:
        print(registry.render_entry(entry), end="")
    return 0


def _cmd_gpu_limit(args: argparse.Namespace) -> int:
    try:
        if args.gpu_command == "revert":
            gpulimit.revert(assume_yes=args.yes)
            return 0
        profile = config.load_profile(args.profile)
        if args.gpu_command == "apply":
            gpulimit.apply(profile, assume_yes=args.yes)
        else:
            gpulimit.show(profile)
    except (config.ConfigError, gpulimit.GpuLimitError) as exc:
        print(f"alab gpu-limit: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ncancelled; nothing was changed", file=sys.stderr)
        return 130
    return 0


def _cmd_serve(args: argparse.Namespace) -> int:
    try:
        profile = config.load_profile(args.profile)
        lines = serve.serve(profile, force=args.force)
    except (config.ConfigError, serve.ServeError, process.BackendError) as exc:
        print(f"alab serve: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted; nothing was left running", file=sys.stderr)
        return 130
    print("\n".join(lines))
    return 0


def _cmd_stop(args: argparse.Namespace) -> int:
    try:
        record, was_running = process.stop()
    except process.BackendError as exc:
        print(f"alab stop: {exc}", file=sys.stderr)
        return 1
    if record is None:
        print("backend: not running")
    elif was_running:
        print(f"backend: stopped (pid {record.pid})")
    else:
        print(f"backend: had already exited (pid {record.pid}); cleared its record")
    return 0


# Exit codes of `alab status`, as for LSB init scripts.
_STATUS_CODES = {
    process.State.RUNNING: 0,
    process.State.LOADING: 0,
    process.State.UNHEALTHY: 1,
    process.State.EXITED: 1,
    process.State.STOPPED: 3,
}


def _cmd_status(args: argparse.Namespace) -> int:
    status = process.status()
    print("\n".join(serve.describe(status)))
    return _STATUS_CODES[status.state]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="alab", description="Run Qwen3.8-27B locally with mlx-lm behind an API gateway."
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>", required=True)
    sub.add_parser("version", help="print the agent-lab version").set_defaults(func=_cmd_version)
    sub.add_parser("doctor", help="check the machine and the toolchain").set_defaults(
        func=_cmd_doctor
    )

    p = sub.add_parser("pull", help="download and verify a model from the registry")
    p.add_argument("model", nargs="?", help="model id (default: the profile's model)")
    p.add_argument("--profile", default=config.DEFAULT_PROFILE, help="profile whose model to pull")
    p.add_argument(
        "--recheck", action="store_true", help="hash files again even if already verified"
    )
    p.add_argument(
        "--limit-rate", metavar="SIZE", help='maximum download speed per second, e.g. "20MB"'
    )
    p.set_defaults(func=_cmd_pull)

    p = sub.add_parser("models", help="list registry models and their local state")
    p.set_defaults(func=_cmd_models_list)
    models_sub = p.add_subparsers(dest="models_command", metavar="<command>")
    models_sub.add_parser("list", help="list models (the default)").set_defaults(
        func=_cmd_models_list
    )
    lock = models_sub.add_parser(
        "lock", help="generate a registry entry from Hugging Face (maintainers)"
    )
    lock.add_argument("model", help="model id for the entry")
    lock.add_argument("--repo", required=True, help="Hugging Face repository, owner/name")
    lock.add_argument("--revision", default="main", help="branch, tag or commit (default: main)")
    lock.add_argument("--description", help="entry description (default: keep the existing one)")
    lock.add_argument(
        "--write", action="store_true", help="update config/models.toml instead of printing"
    )
    lock.set_defaults(func=_cmd_models_lock)

    p = sub.add_parser(
        "gpu-limit", help="show, temporarily raise or restore the GPU wired memory limit"
    )
    p.add_argument("--profile", default=config.DEFAULT_PROFILE, help="profile to compare with")
    p.set_defaults(func=_cmd_gpu_limit, gpu_command="show")
    gpu_sub = p.add_subparsers(dest="gpu_command", metavar="<command>")
    gpu_show = gpu_sub.add_parser(
        "show", help="show the limit and what the profile needs (the default)"
    )
    gpu_apply = gpu_sub.add_parser(
        "apply", help="raise the limit to the profile's value with sudo (until reboot)"
    )
    for command in (gpu_show, gpu_apply):
        # SUPPRESS keeps `alab gpu-limit --profile x apply` from being reset to the default.
        command.add_argument("--profile", default=argparse.SUPPRESS, help="profile to use")
    gpu_revert = gpu_sub.add_parser("revert", help="restore the system default with sudo")
    for command in (gpu_apply, gpu_revert):
        command.add_argument("--yes", action="store_true", help="skip the confirmation prompt")

    p = sub.add_parser("serve", help="start the inference backend (mlx-lm on 127.0.0.1)")
    p.add_argument("--profile", default=config.DEFAULT_PROFILE, help="profile to serve")
    p.add_argument(
        "--force", action="store_true", help="start even if the GPU limit is below the profile's"
    )
    p.set_defaults(func=_cmd_serve)
    sub.add_parser("stop", help="stop the backend").set_defaults(func=_cmd_stop)
    sub.add_parser(
        "status", help="show whether the backend runs, its memory and logs"
    ).set_defaults(func=_cmd_status)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    result: int = args.func(args)
    return result
