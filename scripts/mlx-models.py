#!/usr/bin/env python3
"""Download and verify revision-pinned MLX model snapshots."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "config" / "mlx" / "models.json"


def cache_root() -> Path:
    hf_home = Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface"))
    return hf_home / "hub"


def load_catalog() -> list[dict]:
    with CATALOG_PATH.open(encoding="utf-8") as handle:
        catalog = json.load(handle)
    if catalog.get("schema_version") != 1 or not isinstance(catalog.get("models"), list):
        raise ValueError(f"invalid MLX model catalog: {CATALOG_PATH}")
    return catalog["models"]


def select_model(models: list[dict], alias: str) -> dict:
    matches = [model for model in models if model.get("alias") == alias]
    if len(matches) != 1:
        raise ValueError(f"unknown MLX model alias: {alias}")
    return matches[0]


def snapshot_path(model: dict) -> Path:
    return cache_root() / model["cache_directory"] / "snapshots" / model["revision"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify(model: dict, quick: bool = False) -> tuple[bool, str]:
    snapshot = snapshot_path(model)
    if not snapshot.is_dir():
        return False, f"missing snapshot {snapshot}"
    for expected in model["files"]:
        path = snapshot / expected["path"]
        if not path.is_file():
            return False, f"missing file {expected['path']}"
        actual_size = path.stat().st_size
        if actual_size != expected["bytes"]:
            return False, f"size mismatch {expected['path']}: expected {expected['bytes']}, got {actual_size}"
        if not quick:
            actual_digest = sha256(path)
            if actual_digest != expected["sha256"]:
                return False, f"digest mismatch {expected['path']}"
    return True, str(snapshot)


def download(model: dict) -> None:
    from huggingface_hub import snapshot_download

    downloaded = Path(
        snapshot_download(
            repo_id=model["repository"],
            revision=model["revision"],
            cache_dir=cache_root(),
            local_files_only=False,
        )
    ).resolve()
    expected = snapshot_path(model).resolve()
    if downloaded != expected:
        raise RuntimeError(f"download resolved to unexpected revision: {downloaded}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("alias", nargs="?")
    verify_parser.add_argument("--quick", action="store_true")
    download_parser = subparsers.add_parser("download")
    download_parser.add_argument("alias")
    path_parser = subparsers.add_parser("path")
    path_parser.add_argument("alias")
    args = parser.parse_args()

    try:
        models = load_catalog()
        if args.command == "list":
            print("ALIAS\tBACKEND\tREPOSITORY\tLOCAL STATUS")
            for model in models:
                valid, _ = verify(model, quick=True)
                print(
                    f"{model['alias']}\t{model['backend']}\t{model['repository']}\t"
                    f"{'verified' if valid else 'missing-or-invalid'}"
                )
            return 0
        if args.command == "path":
            model = select_model(models, args.alias)
            valid, detail = verify(model, quick=True)
            if not valid:
                raise RuntimeError(detail)
            print(snapshot_path(model))
            return 0
        if args.command == "download":
            model = select_model(models, args.alias)
            valid, _ = verify(model, quick=False)
            if not valid:
                download(model)
            valid, detail = verify(model, quick=False)
            if not valid:
                raise RuntimeError(detail)
            print(f"verified {model['alias']} -> {detail}")
            return 0
        selected = models if args.alias is None else [select_model(models, args.alias)]
        failed = False
        for model in selected:
            valid, detail = verify(model, quick=args.quick)
            print(f"{'verified' if valid else 'invalid'} {model['alias']}: {detail}")
            failed = failed or not valid
        return 1 if failed else 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
