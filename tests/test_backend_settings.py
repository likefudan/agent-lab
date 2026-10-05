from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

from agent_lab import config
from agent_lab.backend.settings import HOST, launch_settings


def _arg(args: tuple[str, ...], name: str) -> str:
    return args[args.index(name) + 1]


def test_server_arguments_come_from_the_profile(lab_home: Path) -> None:
    profile = config.load_profile()
    settings = launch_settings(profile)
    args = settings.server_args
    assert settings.model_dir == lab_home / "var/models/qwen3.8-27b-mlx-4bit"
    assert _arg(args, "--model") == str(settings.model_dir)
    assert _arg(args, "--host") == HOST == "127.0.0.1"
    assert _arg(args, "--port") == "8100"
    assert _arg(args, "--decode-concurrency") == "1"
    assert _arg(args, "--prompt-concurrency") == "1"
    assert _arg(args, "--prefill-step-size") == "2048"
    assert _arg(args, "--prompt-cache-size") == "1"
    assert _arg(args, "--prompt-cache-bytes") == str(int(2.2 * 1024**3))
    assert json.loads(_arg(args, "--chat-template-args")) == {"enable_thinking": False}
    assert (_arg(args, "--temp"), _arg(args, "--top-p"), _arg(args, "--top-k")) == (
        "0.7",
        "0.8",
        "20",
    )
    assert _arg(args, "--max-tokens") == "8192"
    assert _arg(args, "--allowed-origins") != "*"
    assert settings.memory_limit == int(19.5 * 1024**3)
    assert settings.tool_parser == "qwen3_coder"
    assert settings.url == "http://127.0.0.1:8100"


def test_auto_tool_parser_leaves_detection_to_mlx_lm(lab_home: Path) -> None:
    profile = config.load_profile("ci-tiny")
    assert launch_settings(profile).tool_parser is None


def test_thinking_can_be_enabled(lab_home: Path) -> None:
    profile = config.load_profile()
    profile = replace(profile, backend=replace(profile.backend, enable_thinking=True))
    args = launch_settings(profile).server_args
    assert json.loads(_arg(args, "--chat-template-args")) == {"enable_thinking": True}
