"""Requests through the gateway with the official ``openai`` SDK (T05 integration test).

    .venv/bin/python tests/gateway_client_check.py --api-key sk-alab-... --model qwen3-0.6b

Sends a normal request, a streaming request, a request with tools, a
multi-turn request with a tool result and a thinking request, then checks
that a request over the context limit is refused with context_length_exceeded.
Exits non-zero on the first failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

import openai

WEATHER: Any = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
        },
    },
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000/v1")
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--max-context", type=int, default=8192)
    args = parser.parse_args()
    # Never through a proxy from http_proxy and friends: the gateway is on this machine.
    os.environ["NO_PROXY"] = os.environ["no_proxy"] = "127.0.0.1,localhost"
    client = openai.OpenAI(base_url=args.url, api_key=args.api_key, timeout=300, max_retries=0)

    models = [m.id for m in client.models.list()]
    assert models == [args.model], models
    print(f"models: {models}")

    reply = client.chat.completions.create(
        model=args.model,
        messages=[{"role": "user", "content": "Say hello in one short sentence."}],
        max_tokens=40,
    )
    text = reply.choices[0].message.content or ""
    assert text.strip(), "empty answer"
    assert reply.model == args.model and reply.usage is not None
    print(f"plain: {text!r} usage={reply.usage.model_dump()}")

    pieces = []
    usage = None
    stream = client.chat.completions.create(
        model=args.model,
        messages=[{"role": "user", "content": "Count from one to five."}],
        max_tokens=40,
        stream=True,
        stream_options={"include_usage": True},
    )
    for chunk in stream:
        if chunk.usage:
            usage = chunk.usage
        for choice in chunk.choices:
            pieces.append(choice.delta.content or "")
    assert "".join(pieces).strip(), "empty stream"
    assert usage is not None, "no usage chunk"
    print(f"stream: {''.join(pieces)!r} usage={usage.model_dump()}")

    question: Any = {"role": "user", "content": "What is the weather in Paris? Use the tool."}
    reply = client.chat.completions.create(
        model=args.model, messages=[question], tools=[WEATHER], max_tokens=200
    )
    message = reply.choices[0].message
    print(f"tools: finish={reply.choices[0].finish_reason} message={message.model_dump()}")
    # The tiny model does not always call the tool; the 27B device test checks the calls.
    call_id = message.tool_calls[0].id if message.tool_calls else "call-1"
    history: list[Any] = [
        question,
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": call_id,
                    "type": "function",
                    "function": {"name": "get_weather", "arguments": '{"city": "Paris"}'},
                }
            ],
        },
        {"role": "tool", "tool_call_id": call_id, "content": json.dumps({"temp_c": 21})},
    ]
    reply = client.chat.completions.create(
        model=args.model, messages=history, tools=[WEATHER], max_tokens=60
    )
    print(f"tool result: {reply.choices[0].message.content!r}")

    reply = client.chat.completions.create(
        model=args.model,
        messages=[{"role": "user", "content": "What is 2+2?"}],
        max_tokens=60,
        reasoning_effort="low",
    )
    print(f"reasoning_effort=low: usage={reply.usage.model_dump() if reply.usage else None}")

    try:
        client.chat.completions.create(
            model=args.model,
            messages=[{"role": "user", "content": "hello " * args.max_context}],
            max_tokens=10,
        )
    except openai.BadRequestError as exc:
        body = exc.body if isinstance(exc.body, dict) else {}
        assert body.get("code") == "context_length_exceeded", exc.body
        print(f"over the limit: {exc.status_code} {body.get('code')}")
    else:
        raise AssertionError("a request over max_context was accepted")

    try:
        openai.OpenAI(base_url=args.url, api_key="wrong", max_retries=0).models.list()
    except openai.AuthenticationError:
        print("wrong key: 401")
    else:
        raise AssertionError("a wrong key was accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
