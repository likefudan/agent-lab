"""Count prompt tokens exactly as the backend will (design section 6.3, token limit).

mlx-lm 0.32.0 renders a chat request with the Hugging Face tokenizer's
``apply_chat_template(messages, tools=tools, tokenize=True,
add_generation_prompt=True, **chat_template_args)`` after normalising the
messages (``process_message_content`` in ``mlx_lm/server.py``). This module
does the same with the same ``transformers`` tokenizer, loaded from the same
model directory, so the count matches the backend's ``usage.prompt_tokens``.
The CI integration test and the device test compare the two.
"""

from __future__ import annotations

import copy
import json
import os
import re
import threading
from pathlib import Path
from typing import Any, Protocol


class PromptCounter(Protocol):
    def count(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None,
        template_args: dict[str, Any],
    ) -> int: ...


def normalize_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """A copy of the messages as mlx-lm hands them to the chat template.

    Text parts are joined into one string, a missing content becomes "", and
    tool-call arguments (a JSON string in the OpenAI format) become objects.
    Non-text parts are rejected earlier by the gateway.
    """
    result = copy.deepcopy(messages)
    for message in result:
        content = message.get("content")
        if isinstance(content, list):
            message["content"] = "".join(part["text"] for part in content)
        elif content is None:
            message["content"] = ""
        for call in message.get("tool_calls") or []:
            function = call.get("function") if isinstance(call, dict) else None
            if isinstance(function, dict) and function.get("arguments"):
                function["arguments"] = json.loads(function["arguments"])
    return result


class ChatTemplateCounter:
    """The model's tokenizer and chat template, loaded once from the model directory."""

    def __init__(self, model_dir: Path) -> None:
        os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")  # no "PyTorch not found"
        from transformers import AutoTokenizer

        # The same arguments mlx-lm's ModelProvider passes (trust_remote_code off).
        self._tokenizer = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=False)
        self._lock = threading.Lock()  # the gateway counts in worker threads
        template = self._tokenizer.chat_template
        self.chat_template: str = template if isinstance(template, str) else ""

    def count(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None,
        template_args: dict[str, Any],
    ) -> int:
        with self._lock:
            tokens = self._tokenizer.apply_chat_template(
                normalize_messages(messages),
                tools=tools,  # type: ignore[arg-type]
                tokenize=True,
                add_generation_prompt=True,
                return_dict=False,
                **template_args,
            )
        return len(tokens)


def template_variables(chat_template: str) -> set[str]:
    """Names the template reads, roughly: enough to see which switches it supports."""
    return set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", chat_template))
