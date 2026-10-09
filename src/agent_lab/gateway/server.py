"""The gateway process: ``python -m agent_lab.gateway --profile <name>``.

``alab serve`` starts it once the backend is ready. It loads the model's
tokenizer (for the token limit), records ``gateway.ready.json`` and serves the
app with uvicorn on 127.0.0.1 only.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import os
import sys
import time
from typing import Any

import uvicorn

from agent_lab import config, paths, pull
from agent_lab.backend.launch import OFFLINE_ENV, setup_logging, write_json
from agent_lab.backend.settings import HOST
from agent_lab.gateway import translate
from agent_lab.gateway.app import Gateway, GatewaySettings, create_app
from agent_lab.gateway.keys import KeyStore
from agent_lab.gateway.tokens import ChatTemplateCounter, template_variables

log = logging.getLogger("agent_lab.gateway")

EXIT_CONFIG = 2
EFFORT_VARIABLE = "reasoning_effort"  # the Qwen3.8 chat template's name for it
GRACEFUL_SHUTDOWN_SECONDS = 3  # open streams are cut after this on `alab stop`


def rules_for(profile: config.Profile, chat_template: str) -> translate.Rules:
    backend, gateway = profile.backend, profile.gateway
    has_effort = EFFORT_VARIABLE in template_variables(chat_template)
    return translate.Rules(
        model_name=gateway.model_name,
        limits=translate.Limits(
            max_context=gateway.max_context,
            max_output_tokens=gateway.max_output_tokens,
            min_output_tokens=gateway.min_output_tokens,
        ),
        default_thinking=backend.enable_thinking,
        sampling=translate.Sampling(backend.temperature, backend.top_p, backend.top_k),
        thinking_sampling=translate.Sampling(
            backend.thinking_temperature, backend.thinking_top_p, backend.thinking_top_k
        ),
        effort_variable=EFFORT_VARIABLE if has_effort else None,
    )


def uvicorn_config(app: Any, port: int) -> uvicorn.Config:
    return uvicorn.Config(
        app,
        host=HOST,
        port=port,
        log_config=None,  # our handlers (setup_logging) stay in place
        access_log=False,  # the gateway writes its own request lines, without bodies
        server_header=False,  # no software names or versions to the internet
        date_header=False,
        timeout_graceful_shutdown=GRACEFUL_SHUTDOWN_SECONDS,
    )


def _queue_writer() -> Any:
    path = paths.gateway_queue()
    pid = os.getpid()

    def write(active: int, waiting: int) -> None:
        try:
            write_json(
                path, {"pid": pid, "active": active, "waiting": waiting, "updated": time.time()}
            )
        except OSError:
            log.exception("cannot record the queue length")

    return write


def run(profile: config.Profile) -> None:
    started = time.monotonic()
    model_dir = pull.model_dir(profile.model.id)
    counter = ChatTemplateCounter(model_dir)
    rules = rules_for(profile, counter.chat_template)
    settings = GatewaySettings(
        rules=rules,
        backend_url=f"http://{HOST}:{profile.backend.port}",
        queue_size=profile.gateway.queue_size,
        heartbeat_seconds=profile.gateway.heartbeat_seconds,
    )
    on_queue = _queue_writer()
    gateway = Gateway(settings, KeyStore(), counter, on_queue)
    on_queue(0, 0)
    app = create_app(gateway)
    log.info(
        "gateway for %s (%s) on %s:%d, backend %s; context %d, output up to %d, queue %d; "
        "reasoning_effort %s",
        rules.model_name,
        profile.model.id,
        HOST,
        profile.gateway.port,
        settings.backend_url,
        rules.limits.max_context,
        rules.limits.max_output_tokens,
        settings.queue_size,
        f"maps to {rules.effort_variable}" if rules.effort_variable else "only switches thinking",
    )
    server = uvicorn.Server(uvicorn_config(app, profile.gateway.port))

    async def serve() -> None:
        task = asyncio.ensure_future(server.serve())
        while not server.started:
            if task.done():
                await task  # failed to start (port in use ...): the error is logged
                return
            await asyncio.sleep(0.05)
        write_json(
            paths.gateway_ready(),
            {
                "pid": os.getpid(),
                "port": profile.gateway.port,
                "model_name": rules.model_name,
                "start_seconds": round(time.monotonic() - started, 1),
                "effort_variable": rules.effort_variable,
            },
        )
        log.info("listening after %.1fs", time.monotonic() - started)
        await task

    asyncio.run(serve())
    if not server.started:
        sys.exit(1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agent_lab.gateway")
    parser.add_argument("--profile", default=config.DEFAULT_PROFILE)
    args = parser.parse_args(argv)
    try:
        profile = config.load_profile(args.profile)
    except config.ConfigError as exc:
        print(f"gateway: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    os.environ.update(OFFLINE_ENV)  # before transformers loads huggingface_hub
    setup_logging(paths.gateway_log())
    logging.getLogger("httpx").setLevel(logging.WARNING)  # a line per backend call is noise
    try:
        run(profile)
    except Exception:
        log.exception("the gateway failed")
        return 1
    finally:
        with contextlib.suppress(OSError):
            paths.gateway_queue().unlink(missing_ok=True)
    return 0
