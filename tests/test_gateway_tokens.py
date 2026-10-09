"""The token counter with a real (tiny, locally built) Hugging Face tokenizer."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest
from tokenizers import Tokenizer, models, pre_tokenizers

from agent_lab import config
from agent_lab.gateway import server
from agent_lab.gateway.tokens import ChatTemplateCounter, normalize_messages, template_variables

TEMPLATE = (
    "{% for m in messages %}{{ m.role }} {{ m.content }} "
    "{% for c in m.tool_calls or [] %}call {{ c.function.name }} "
    "{% for k, v in c.function.arguments.items() %}{{ k }} {{ v }} {% endfor %}{% endfor %}"
    "{% endfor %}"
    "{% if tools %}{% for t in tools %}tool {{ t.function.name }} {% endfor %}{% endif %}"
    "{% if enable_thinking is defined and enable_thinking is false %}nothink {% endif %}"
    "{% if reasoning_effort is defined %}effort {{ reasoning_effort }} {% endif %}"
    "{% if add_generation_prompt %}assistant{% endif %}"
)


@pytest.fixture
def model_dir(tmp_path: Path) -> Path:
    words = "user system assistant tool call nothink effort low hi there get_weather city paris"
    vocab = {"[UNK]": 0, **{w: i + 1 for i, w in enumerate(words.split())}}
    tokenizer = Tokenizer(models.WordLevel(vocab, unk_token="[UNK]"))
    tokenizer.pre_tokenizer = pre_tokenizers.WhitespaceSplit()
    tokenizer.save(str(tmp_path / "tokenizer.json"))
    (tmp_path / "tokenizer_config.json").write_text(
        json.dumps(
            {
                "tokenizer_class": "PreTrainedTokenizerFast",
                "unk_token": "[UNK]",
                "chat_template": TEMPLATE,
            }
        )
    )
    return tmp_path


def test_counts_with_the_chat_template(model_dir: Path) -> None:
    counter = ChatTemplateCounter(model_dir)
    messages: list[dict[str, Any]] = [{"role": "user", "content": "hi there"}]
    # "user hi there" + "assistant"
    assert counter.count(messages, None, {}) == 4
    # + "nothink"
    assert counter.count(messages, None, {"enable_thinking": False}) == 5
    tools = [{"type": "function", "function": {"name": "get_weather"}}]
    # + "tool get_weather" + "effort low"
    args = {"enable_thinking": True, "reasoning_effort": "low"}
    assert counter.count(messages, tools, args) == 8
    call = {
        "type": "function",
        "function": {"name": "get_weather", "arguments": '{"city": "paris"}'},
    }
    history = [*messages, {"role": "assistant", "content": None, "tool_calls": [call]}]
    # + "assistant" + "" + "call get_weather city paris"
    assert counter.count(history, None, {}) == 4 + 5
    assert "reasoning_effort" in template_variables(counter.chat_template)


def test_normalize_messages_like_mlx_lm() -> None:
    call = {"function": {"name": "f", "arguments": '{"a": [1, 2]}'}}
    messages: list[dict[str, Any]] = [
        {"role": "user", "content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]},
        {"role": "assistant", "content": None, "tool_calls": [call]},
    ]
    result = normalize_messages(messages)
    assert result[0]["content"] == "ab"
    assert result[1]["content"] == ""
    assert result[1]["tool_calls"][0]["function"]["arguments"] == {"a": [1, 2]}
    assert messages[1]["tool_calls"][0]["function"]["arguments"] == '{"a": [1, 2]}'  # a copy


def test_rules_from_the_profile(lab_home: Path) -> None:
    profile = config.load_profile("mac-24gb")
    rules = server.rules_for(profile, "{{ reasoning_effort|default('xhigh') }}")
    assert rules.model_name == "qwen3.8-27b"
    assert rules.effort_variable == "reasoning_effort"
    assert rules.limits.max_context == profile.gateway.max_context
    assert (rules.thinking_sampling.temperature, rules.sampling.temperature) == (0.6, 0.7)
    assert server.rules_for(profile, "{{ enable_thinking }}").effort_variable is None
