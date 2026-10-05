"""What the backend runs: the ``mlx_lm.server`` arguments derived from a profile.

Kept free of MLX imports so it can be tested anywhere and so ``alab`` can show
what it is about to run before anything heavy is loaded.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from agent_lab import config, pull

HOST = "127.0.0.1"  # never listen beyond this machine (design section 9)
LOG_LEVEL = "INFO"  # mlx-lm logs request bodies only at DEBUG
# mlx-lm answers every origin with "Access-Control-Allow-Origin: *" by default, which
# would let any web page read the unauthenticated backend. No browser sends this origin.
NO_BROWSER_ORIGINS = "none"
AUTO_TOOL_PARSER = "auto"


@dataclass(frozen=True)
class LaunchSettings:
    profile: str
    model_id: str
    model_dir: Path
    port: int
    memory_limit: int  # bytes; the launch wrapper stops the server above this
    tool_parser: str | None  # None leaves the choice to mlx-lm's auto-detection
    server_args: tuple[str, ...]

    @property
    def url(self) -> str:
        return f"http://{HOST}:{self.port}"


def launch_settings(profile: config.Profile) -> LaunchSettings:
    backend = profile.backend
    directory = pull.model_dir(profile.model.id)
    template_args = {"enable_thinking": backend.enable_thinking}
    args = (
        "--model", str(directory),
        "--host", HOST,
        "--port", str(backend.port),
        "--allowed-origins", NO_BROWSER_ORIGINS,
        "--log-level", LOG_LEVEL,
        # One request at a time: concurrency multiplies KV cache memory; the gateway queues.
        "--decode-concurrency", "1",
        "--prompt-concurrency", "1",
        "--prefill-step-size", str(backend.prefill_step_size),
        "--prompt-cache-size", str(backend.prompt_cache_size),
        # mlx-lm reads a bare number as bytes (its units are decimal, ours binary).
        "--prompt-cache-bytes", str(backend.prompt_cache_bytes),
        "--chat-template-args", json.dumps(template_args),
        "--temp", repr(backend.temperature),
        "--top-p", repr(backend.top_p),
        "--top-k", str(backend.top_k),
        # Used when a request sets no max_tokens; mlx-lm's own default is 512.
        "--max-tokens", str(profile.gateway.max_output_tokens),
    )  # fmt: skip
    parser = None if backend.tool_parser == AUTO_TOOL_PARSER else backend.tool_parser
    return LaunchSettings(
        profile=profile.name,
        model_id=profile.model.id,
        model_dir=directory,
        port=backend.port,
        memory_limit=backend.metal_memory_limit,
        tool_parser=parser,
        server_args=args,
    )
