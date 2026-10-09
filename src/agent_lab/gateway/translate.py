"""Turn a client's chat request into the backend's (design section 6.3, parameters).

Pure functions, so every rule can be tested without a server:

- only known fields are forwarded; anything else (mlx-lm's ``adapters``,
  ``draft_model``, ``num_draft_tokens``, ``role_mapping`` ...) is dropped, so a
  client cannot make the backend load other weights;
- the public model name is checked and replaced with the backend's own;
- ``reasoning_effort`` becomes chat template arguments;
- unset sampling parameters get the recommended values for the mode;
- ``max_tokens`` is clamped to what fits (``limit``), after the prompt is counted.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Any

# mlx-lm serves its --model under this name; any other name is a repository to download.
BACKEND_MODEL = "default_model"

THINKING_SWITCH = "enable_thinking"
# The model card's names for the effort levels; "high" is the model's "xhigh".
EFFORT_LEVELS = {"low": "low", "medium": "medium", "high": "xhigh", "xhigh": "xhigh"}
NO_THINKING = {"none", "minimal"}

MESSAGE_ROLES = {"system", "developer", "user", "assistant", "tool"}
# Sampling and stopping fields passed on unchanged once their types are checked.
_NUMBER_FIELDS = {
    "temperature": (0.0, 2.0),
    "top_p": (0.0, 1.0),
    "min_p": (0.0, 1.0),
    "presence_penalty": (-2.0, 2.0),
    "frequency_penalty": (-2.0, 2.0),
    "repetition_penalty": (0.0, 10.0),
}
SAMPLING_FIELDS = ("temperature", "top_p", "top_k")


class ApiError(Exception):
    """An error for the client, in OpenAI's format."""

    def __init__(
        self,
        status: int,
        message: str,
        code: str | None = None,
        param: str | None = None,
        type_: str = "invalid_request_error",
    ) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code
        self.param = param
        self.type = type_

    def body(self) -> dict[str, Any]:
        return {
            "error": {
                "message": self.message,
                "type": self.type,
                "param": self.param,
                "code": self.code,
            }
        }


@dataclass(frozen=True)
class Sampling:
    temperature: float
    top_p: float
    top_k: int

    def as_dict(self) -> dict[str, Any]:
        return {"temperature": self.temperature, "top_p": self.top_p, "top_k": self.top_k}


@dataclass(frozen=True)
class Limits:
    max_context: int
    max_output_tokens: int
    min_output_tokens: int


@dataclass(frozen=True)
class Rules:
    """What the gateway needs to know about the model and the profile."""

    model_name: str  # the public name, e.g. qwen3.8-27b
    limits: Limits
    default_thinking: bool  # the backend's enable_thinking (its --chat-template-args)
    sampling: Sampling  # recommended values without thinking
    thinking_sampling: Sampling  # recommended values with thinking
    effort_variable: str | None  # the template's effort argument, if it has one


@dataclass
class Prepared:
    """A validated request: what to count and what to send (``max_tokens`` comes later)."""

    body: dict[str, Any]  # for the backend, without max_tokens
    messages: list[dict[str, Any]]
    tools: list[dict[str, Any]] | None
    template_args: dict[str, Any]  # all chat template arguments, as the backend applies them
    requested_max_tokens: int | None
    stream: bool
    include_usage: bool
    thinking: bool
    effort: str


def _bad(message: str, param: str | None = None) -> ApiError:
    return ApiError(400, message, code="invalid_value" if param else None, param=param)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return (_is_int(value) or isinstance(value, float)) and math.isfinite(value)


def _check_content(content: Any, where: str) -> None:
    if content is None or isinstance(content, str):
        return
    if not isinstance(content, list):
        raise _bad(f"{where}.content must be a string or a list of parts", f"{where}.content")
    for j, part in enumerate(content):
        kind = part.get("type") if isinstance(part, dict) else None
        if kind != "text":
            raise _bad(
                f"{where}.content[{j}] has type {kind!r}: only text is supported "
                "(this server does not accept images, audio or files in v1)",
                f"{where}.content",
            )
        if not isinstance(part.get("text"), str):
            raise _bad(f"{where}.content[{j}].text must be a string", f"{where}.content")


def _check_tool_calls(calls: Any, where: str) -> None:
    if calls is None:
        return
    if not isinstance(calls, list):
        raise _bad(f"{where}.tool_calls must be a list", f"{where}.tool_calls")
    for j, call in enumerate(calls):
        function = call.get("function") if isinstance(call, dict) else None
        if not isinstance(function, dict) or not isinstance(function.get("name"), str):
            raise _bad(f"{where}.tool_calls[{j}] needs a function name", f"{where}.tool_calls")
        arguments = function.get("arguments")
        if arguments is None or arguments == "":
            continue
        if not isinstance(arguments, str):
            raise _bad(
                f"{where}.tool_calls[{j}].function.arguments must be a JSON string",
                f"{where}.tool_calls",
            )
        try:
            json.loads(arguments)
        except ValueError:
            raise _bad(
                f"{where}.tool_calls[{j}].function.arguments is not valid JSON",
                f"{where}.tool_calls",
            ) from None


def _messages(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise _bad("messages must be a non-empty list", "messages")
    result = []
    for i, message in enumerate(value):
        where = f"messages[{i}]"
        if not isinstance(message, dict):
            raise _bad(f"{where} must be an object", "messages")
        role = message.get("role")
        if role not in MESSAGE_ROLES:
            raise _bad(f"{where}.role must be one of {sorted(MESSAGE_ROLES)}", "messages")
        _check_content(message.get("content"), where)
        _check_tool_calls(message.get("tool_calls"), where)
        message = dict(message)
        if role == "developer":
            message["role"] = "system"  # newer OpenAI clients; the chat template knows system
        result.append(message)
    return result


def _tools(value: Any, tool_choice: Any) -> list[dict[str, Any]] | None:
    if value is None or value == []:
        return None
    if not isinstance(value, list):
        raise _bad("tools must be a list", "tools")
    for i, tool in enumerate(value):
        function = tool.get("function") if isinstance(tool, dict) else None
        if (
            not isinstance(tool, dict)
            or tool.get("type", "function") != "function"
            or not isinstance(function, dict)
            or not isinstance(function.get("name"), str)
        ):
            raise _bad(f"tools[{i}] must be a function with a name", "tools")
    # mlx-lm has no tool_choice; "none" can still be honoured by not offering the tools.
    if tool_choice == "none":
        return None
    return value


def _effort(value: Any, rules: Rules) -> tuple[str, bool, dict[str, Any]]:
    """(effort, thinking, chat template arguments to send) for ``reasoning_effort``."""
    if value is None:
        return ("default", rules.default_thinking, {})
    if not isinstance(value, str) or (value not in NO_THINKING and value not in EFFORT_LEVELS):
        raise _bad("reasoning_effort must be one of none, low, medium or high", "reasoning_effort")
    if value in NO_THINKING:
        # Sent only when it differs from the backend's default: mlx-lm skips its prompt
        # cache for requests that change the template arguments.
        off: dict[str, Any] = {THINKING_SWITCH: False} if rules.default_thinking else {}
        return ("none", False, off)
    on: dict[str, Any] = {THINKING_SWITCH: True}
    if rules.effort_variable:
        on[rules.effort_variable] = EFFORT_LEVELS[value]
    return (value, True, on)


def prepare(body: Any, rules: Rules) -> Prepared:
    """Validate a chat completion request; raises ApiError for the client."""
    if not isinstance(body, dict):
        raise _bad("the request body must be a JSON object")
    model = body.get("model")
    if model is not None and model != rules.model_name:
        raise ApiError(
            404,
            f"The model `{model}` does not exist; this server only has `{rules.model_name}`.",
            code="model_not_found",
            param="model",
        )
    messages = _messages(body.get("messages"))
    tools = _tools(body.get("tools"), body.get("tool_choice"))

    stream = body.get("stream", False)
    if stream is None:
        stream = False
    if not isinstance(stream, bool):
        raise _bad("stream must be true or false", "stream")
    options = body.get("stream_options")
    include_usage = False
    if isinstance(options, dict):
        include_usage = options.get("include_usage") is True
    elif options is not None:
        raise _bad("stream_options must be an object", "stream_options")

    n = body.get("n")
    if n is not None and n != 1:
        raise _bad("only n=1 is supported", "n")

    forward: dict[str, Any] = {"model": BACKEND_MODEL, "messages": messages}
    if tools:
        forward["tools"] = tools

    for name, (low, high) in _NUMBER_FIELDS.items():
        value = body.get(name)
        if value is None:
            continue
        if not _is_number(value) or not low <= value <= high:
            raise _bad(f"{name} must be a number between {low} and {high}", name)
        forward[name] = value
    if (top_k := body.get("top_k")) is not None:
        if not _is_int(top_k) or top_k < 0:
            raise _bad("top_k must be a non-negative integer", "top_k")
        forward["top_k"] = top_k
    if (seed := body.get("seed")) is not None:
        if not _is_int(seed):
            raise _bad("seed must be an integer", "seed")
        forward["seed"] = seed
    if (stop := body.get("stop")) is not None:
        if isinstance(stop, str):
            stop = [stop]
        if not isinstance(stop, list) or not all(isinstance(s, str) and s for s in stop):
            raise _bad("stop must be a string or a list of strings", "stop")
        if stop:
            forward["stop"] = stop
    if (bias := body.get("logit_bias")) is not None:
        if not isinstance(bias, dict) or not all(
            isinstance(k, str) and k.isdigit() and _is_number(v) for k, v in bias.items()
        ):
            raise _bad("logit_bias must map token ids to numbers", "logit_bias")
        if bias:
            forward["logit_bias"] = bias

    requested = None
    for name in ("max_completion_tokens", "max_tokens"):
        value = body.get(name)
        if value is None:
            continue
        if not _is_int(value) or value < 1:
            raise _bad(f"{name} must be a positive integer", name)
        requested = value
        break  # max_completion_tokens wins when both are set, as in OpenAI's API

    effort_name, thinking, template_args = _effort(body.get("reasoning_effort"), rules)
    if template_args:
        forward["chat_template_kwargs"] = template_args
    defaults = rules.thinking_sampling if thinking else rules.sampling
    for name, value in defaults.as_dict().items():
        forward.setdefault(name, value)

    # The backend always streams to the gateway (so a client that leaves can be
    # cancelled at once) and always reports usage (for the log).
    forward["stream"] = True
    forward["stream_options"] = {"include_usage": True}

    applied = {THINKING_SWITCH: rules.default_thinking, **template_args}
    return Prepared(
        body=forward,
        messages=messages,
        tools=tools,
        template_args=applied,
        requested_max_tokens=requested,
        stream=stream,
        include_usage=include_usage,
        thinking=thinking,
        effort=effort_name,
    )


def limit(prompt_tokens: int, requested: int | None, limits: Limits) -> int:
    """``max_tokens`` for the backend, or ApiError if the prompt leaves too little room."""
    budget = limits.max_context - limits.min_output_tokens
    if prompt_tokens > budget:
        raise ApiError(
            400,
            f"This model's maximum context length is {limits.max_context} tokens, of which "
            f"{limits.min_output_tokens} are kept for the answer. Your messages resulted in "
            f"{prompt_tokens} tokens; please shorten them or start a new conversation.",
            code="context_length_exceeded",
            param="messages",
        )
    allowed = min(limits.max_output_tokens, limits.max_context - prompt_tokens)
    return allowed if requested is None else min(requested, allowed)
