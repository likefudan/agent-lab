from __future__ import annotations

from typing import Any

import pytest

from agent_lab.gateway import translate
from agent_lab.gateway.translate import ApiError
from tests.gateway_fakes import MODEL, rules

HELLO = [{"role": "user", "content": "hi"}]


def prepare(rules_: translate.Rules | None = None, **body: Any) -> translate.Prepared:
    return translate.prepare({"messages": HELLO, **body}, rules_ or rules())


def error(**body: Any) -> ApiError:
    with pytest.raises(ApiError) as caught:
        prepare(**body)
    return caught.value


def test_defaults() -> None:
    p = prepare()
    assert p.body == {
        "model": "default_model",
        "messages": HELLO,
        "temperature": 0.7,
        "top_p": 0.8,
        "top_k": 20,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    assert p.template_args == {"enable_thinking": False}
    assert (p.stream, p.include_usage, p.thinking, p.effort) == (False, False, False, "default")
    assert p.requested_max_tokens is None


def test_model_name() -> None:
    assert prepare(model=MODEL).body["model"] == "default_model"
    e = error(model="default_model")  # the backend's internal name is not public
    assert (e.status, e.code) == (404, "model_not_found")
    assert error(model="mlx-community/Qwen3-0.6B-4bit").status == 404


def test_only_known_fields_are_forwarded() -> None:
    p = prepare(
        adapters="x",
        draft_model="y",
        num_draft_tokens=3,
        role_mapping={},
        chat_template_kwargs={"enable_thinking": True},
        logprobs=True,
        top_logprobs=3,
        response_format={"type": "json_object"},
        user="someone",
        stop="END",
        seed=1,
        min_p=0.05,
        presence_penalty=1.5,
        logit_bias={"42": -100},
    )
    assert set(p.body) == {
        "model",
        "messages",
        "temperature",
        "top_p",
        "top_k",
        "stream",
        "stream_options",
        "stop",
        "seed",
        "min_p",
        "presence_penalty",
        "logit_bias",
    }
    assert p.body["stop"] == ["END"]


@pytest.mark.parametrize(
    ("body", "param"),
    [
        ({"temperature": "hot"}, "temperature"),
        ({"temperature": 3}, "temperature"),
        ({"top_p": 1.5}, "top_p"),
        ({"top_k": 1.5}, "top_k"),
        ({"top_k": True}, "top_k"),
        ({"max_tokens": 0}, "max_tokens"),
        ({"max_tokens": "10"}, "max_tokens"),
        ({"max_completion_tokens": -1}, "max_completion_tokens"),
        ({"stream": "yes"}, "stream"),
        ({"stop": [1]}, "stop"),
        ({"seed": 1.5}, "seed"),
        ({"logit_bias": {"a": 1}}, "logit_bias"),
        ({"n": 2}, "n"),
        ({"reasoning_effort": "max"}, "reasoning_effort"),
        ({"messages": []}, "messages"),
        ({"messages": [{"role": "robot", "content": "x"}]}, "messages"),
        ({"messages": ["hi"]}, "messages"),
        ({"tools": [{"type": "retrieval"}]}, "tools"),
        ({"tools": "get_weather"}, "tools"),
    ],
)
def test_invalid_values(body: dict[str, Any], param: str) -> None:
    e = error(**body)
    assert (e.status, e.param) == (400, param)


def test_not_an_object() -> None:
    with pytest.raises(ApiError):
        translate.prepare([HELLO], rules())


def test_non_text_content() -> None:
    image = {"type": "image_url", "image_url": {"url": "https://example.com/a.png"}}
    e = error(messages=[{"role": "user", "content": [image]}])
    assert e.status == 400 and "only text is supported" in e.message
    text = [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]
    assert prepare(messages=[{"role": "user", "content": text}]).messages[0]["content"] == text


def test_developer_role_becomes_system() -> None:
    messages = [{"role": "developer", "content": "be brief"}, *HELLO]
    assert prepare(messages=messages).messages[0]["role"] == "system"


def test_tool_call_arguments_must_be_json() -> None:
    function = {"name": "f", "arguments": "{bad"}
    call = {"id": "1", "type": "function", "function": function}
    messages = [*HELLO, {"role": "assistant", "content": None, "tool_calls": [call]}]
    assert error(messages=messages).param == "messages[1].tool_calls"
    function["arguments"] = '{"a": 1}'
    assert prepare(messages=messages).messages[1]["tool_calls"] == [call]


def test_tools() -> None:
    tools = [{"type": "function", "function": {"name": "get_weather", "parameters": {}}}]
    p = prepare(tools=tools, tool_choice="auto")
    assert p.tools == tools and p.body["tools"] == tools
    p = prepare(tools=tools, tool_choice="none")
    assert p.tools is None and "tools" not in p.body
    assert prepare(tools=[]).tools is None


def test_stream_options() -> None:
    p = prepare(stream=True, stream_options={"include_usage": True})
    assert (p.stream, p.include_usage) == (True, True)
    assert prepare(stream=None).stream is False


@pytest.mark.parametrize(
    ("effort", "template", "thinking"),
    [
        ("none", {}, False),
        ("minimal", {}, False),
        ("low", {"enable_thinking": True, "reasoning_effort": "low"}, True),
        ("medium", {"enable_thinking": True, "reasoning_effort": "medium"}, True),
        ("high", {"enable_thinking": True, "reasoning_effort": "xhigh"}, True),
        ("xhigh", {"enable_thinking": True, "reasoning_effort": "xhigh"}, True),
    ],
)
def test_reasoning_effort(effort: str, template: dict[str, Any], thinking: bool) -> None:
    p = prepare(reasoning_effort=effort)
    assert p.body.get("chat_template_kwargs", {}) == template
    assert p.template_args == {"enable_thinking": False, **template}
    assert p.thinking is thinking
    sampling = (0.6, 0.95, 20) if thinking else (0.7, 0.8, 20)
    assert (p.body["temperature"], p.body["top_p"], p.body["top_k"]) == sampling


def test_reasoning_effort_without_template_support() -> None:
    p = prepare(rules(effort_variable=None), reasoning_effort="low")
    assert p.body["chat_template_kwargs"] == {"enable_thinking": True}


def test_thinking_on_by_default_in_the_profile() -> None:
    from dataclasses import replace

    thinking = replace(rules(), default_thinking=True)
    p = prepare(thinking)
    assert "chat_template_kwargs" not in p.body and p.thinking
    assert p.body["temperature"] == 0.6
    p = prepare(thinking, reasoning_effort="none")
    assert p.body["chat_template_kwargs"] == {"enable_thinking": False}
    assert p.template_args == {"enable_thinking": False}


def test_client_sampling_values_win() -> None:
    p = prepare(reasoning_effort="low", temperature=0, top_k=0)
    assert (p.body["temperature"], p.body["top_p"], p.body["top_k"]) == (0, 0.95, 0)


def test_max_tokens_preference() -> None:
    assert prepare(max_tokens=10, max_completion_tokens=20).requested_max_tokens == 20
    assert prepare(max_tokens=10).requested_max_tokens == 10


LIMITS = translate.Limits(max_context=32768, max_output_tokens=8192, min_output_tokens=1024)


def test_limit() -> None:
    assert translate.limit(1000, None, LIMITS) == 8192
    assert translate.limit(1000, 32000, LIMITS) == 8192  # opencode's 32000 is clamped
    assert translate.limit(1000, 100, LIMITS) == 100
    assert translate.limit(30000, None, LIMITS) == 2768
    assert translate.limit(31744, 32000, LIMITS) == 1024  # exactly the reserved room
    with pytest.raises(ApiError) as caught:
        translate.limit(31745, None, LIMITS)
    assert caught.value.code == "context_length_exceeded"
    assert caught.value.body()["error"]["type"] == "invalid_request_error"
