"""Check tool calls, thinking and speed against a running OpenAI-compatible endpoint.

Device test for T04 (design section 7.4): run it against the backend on the Mac
with the 27B model. It prints every request and response as Markdown, ready to
paste into the PR, and exits non-zero if any check fails. T05 can point it at
the gateway with ``--url http://127.0.0.1:8000 --api-key ...``.

    ./alab serve
    .venv/bin/python tests/tool_call_check.py --output var/bench/tool-call-check.md

Only the standard library is used, so it runs with any Python 3.11+.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

WEATHER_TOOL = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name, e.g. Paris"},
                "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]},
            },
            "required": ["city"],
        },
    },
}
WRITE_FILE_TOOL = {
    "type": "function",
    "function": {
        "name": "write_file",
        "description": "Create or overwrite a text file with the given content.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path of the file"},
                "content": {"type": "string", "description": "Full content of the file"},
            },
            "required": ["path", "content"],
        },
    },
}
TOOLS = [WEATHER_TOOL, WRITE_FILE_TOOL]

# Double quotes, escaped quotes, single quotes, a backslash, a tab escape and newlines.
FILE_CONTENT = (
    "def greet(name):\n"
    '    print("Hello, \\"" + name + "\\"!")\n'
    "    path = 'C:\\\\temp\\\\out.txt'\n"
    "    return f'{name}\\tdone'\n"
)


@dataclass
class Result:
    """One request: what was sent, what came back, and the checks on it."""

    name: str
    request: dict[str, Any]
    raw: str = ""
    message: dict[str, Any] = field(default_factory=dict)
    finish_reason: str | None = None
    usage: dict[str, Any] | None = None
    seconds: float = 0.0
    first_token_seconds: float | None = None
    checks: list[tuple[str, bool]] = field(default_factory=list)
    error: str | None = None

    def check(self, description: str, ok: bool) -> None:
        self.checks.append((description, ok))

    @property
    def passed(self) -> bool:
        return self.error is None and all(ok for _, ok in self.checks)


class Client:
    def __init__(self, url: str, api_key: str | None, model: str | None, timeout: float) -> None:
        self.url = url.rstrip("/") + "/v1/chat/completions"
        self.api_key = api_key
        self.model = model
        self.timeout = timeout

    def _open(self, body: dict[str, Any]) -> Any:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        request = urllib.request.Request(
            self.url, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        return urllib.request.urlopen(request, timeout=self.timeout)

    def run(self, name: str, body: dict[str, Any]) -> Result:
        if self.model:
            body = {"model": self.model, **body}
        result = Result(name, body)
        started = time.monotonic()
        try:
            if body.get("stream"):
                self._stream(result, started)
            else:
                with self._open(body) as response:
                    result.raw = response.read().decode()
                data = json.loads(result.raw)
                choice = data["choices"][0]
                result.message = choice["message"]
                result.finish_reason = choice.get("finish_reason")
                result.usage = data.get("usage")
        except urllib.error.HTTPError as exc:
            result.error = f"HTTP {exc.code}: {exc.read().decode(errors='replace')}"
        except (OSError, ValueError, KeyError, IndexError) as exc:
            result.error = f"{type(exc).__name__}: {exc}"
        result.seconds = time.monotonic() - started
        return result

    def _stream(self, result: Result, started: float) -> None:
        """Read SSE chunks and assemble them into one message like a client would."""
        content: list[str] = []
        reasoning: list[str] = []
        calls: dict[int, dict[str, Any]] = {}
        raw_lines = []
        with self._open(result.request) as response:
            for line_bytes in response:
                line = line_bytes.decode().rstrip("\r\n")
                if not line:
                    continue
                raw_lines.append(line)
                if not line.startswith("data:"):
                    continue
                payload = line[len("data:") :].strip()
                if payload == "[DONE]":
                    break
                chunk = json.loads(payload)
                if chunk.get("usage"):
                    result.usage = chunk["usage"]
                for choice in chunk.get("choices", []):
                    delta = choice.get("delta", {})
                    if delta.get("content"):
                        if result.first_token_seconds is None:
                            result.first_token_seconds = time.monotonic() - started
                        content.append(delta["content"])
                    if delta.get("reasoning"):
                        reasoning.append(delta["reasoning"])
                    for i, call in enumerate(delta.get("tool_calls") or []):
                        index = call.get("index", i)
                        slot = calls.setdefault(
                            index,
                            {
                                "id": "",
                                "type": "function",
                                "function": {"name": "", "arguments": ""},
                            },
                        )
                        slot["id"] = call.get("id") or slot["id"]
                        function = call.get("function", {})
                        slot["function"]["name"] += function.get("name") or ""
                        slot["function"]["arguments"] += function.get("arguments") or ""
                    if choice.get("finish_reason"):
                        result.finish_reason = choice["finish_reason"]
        result.raw = "\n".join(raw_lines)
        result.message = {"role": "assistant", "content": "".join(content)}
        if reasoning:
            result.message["reasoning"] = "".join(reasoning)
        if calls:
            result.message["tool_calls"] = [calls[i] for i in sorted(calls)]


def tool_calls(result: Result) -> list[tuple[str, Any]]:
    """(name, parsed arguments) of each tool call; arguments are None if not valid JSON."""
    parsed = []
    for call in result.message.get("tool_calls") or []:
        function = call.get("function", {})
        try:
            arguments = json.loads(function.get("arguments", ""))
        except ValueError:
            arguments = None
        parsed.append((function.get("name"), arguments))
    return parsed


def no_thinking(result: Result) -> None:
    text = result.message.get("content") or ""
    result.check("no reasoning field", not result.message.get("reasoning"))
    result.check(
        "no <think> or tool-call markup in content",
        "<think>" not in text and "<tool_call>" not in text,
    )


def check_single(result: Result) -> None:
    calls = tool_calls(result)
    result.check('finish_reason is "tool_calls"', result.finish_reason == "tool_calls")
    result.check("exactly one tool call", len(calls) == 1)
    if calls:
        name, args = calls[0]
        result.check("function is get_weather", name == "get_weather")
        result.check("arguments are a JSON object", isinstance(args, dict))
        result.check(
            'city is "Paris"',
            isinstance(args, dict) and "paris" in str(args.get("city", "")).lower(),
        )
    for call in result.message.get("tool_calls") or []:
        result.check("tool call has an id", bool(call.get("id")))
    no_thinking(result)


def check_parallel(result: Result) -> None:
    calls = tool_calls(result)
    cities = sorted(
        str(a.get("city", "")).lower()
        for n, a in calls
        if n == "get_weather" and isinstance(a, dict)
    )
    result.check('finish_reason is "tool_calls"', result.finish_reason == "tool_calls")
    result.check("two get_weather calls", len(calls) == 2 and len(cities) == 2)
    result.check(
        "one for Paris and one for Tokyo",
        any("paris" in c for c in cities) and any("tokyo" in c for c in cities),
    )
    ids = [c.get("id") for c in result.message.get("tool_calls") or []]
    result.check("tool call ids are distinct", len(set(ids)) == len(ids))
    no_thinking(result)


def check_special(result: Result) -> None:
    calls = tool_calls(result)
    result.check('finish_reason is "tool_calls"', result.finish_reason == "tool_calls")
    result.check("exactly one write_file call", len(calls) == 1 and calls[0][0] == "write_file")
    if calls and isinstance(calls[0][1], dict):
        args = calls[0][1]
        result.check('path is "hello.py"', str(args.get("path", "")).endswith("hello.py"))
        content = args.get("content")
        result.check(
            "content matches exactly (quotes, backslashes, newlines; trailing newline ignored)",
            isinstance(content, str) and content.rstrip("\n") == FILE_CONTENT.rstrip("\n"),
        )
    else:
        result.check("arguments are a JSON object", False)
    no_thinking(result)


def check_answer(result: Result) -> None:
    text = result.message.get("content") or ""
    result.check("no tool calls", not result.message.get("tool_calls"))
    result.check("non-empty answer", bool(text.strip()))
    no_thinking(result)


def check_round_trip(result: Result) -> None:
    check_answer(result)
    text = (result.message.get("content") or "").lower()
    result.check("answer uses the tool result (mentions 18)", "18" in text)


SINGLE = [{"role": "user", "content": "What is the weather in Paris right now? Use celsius."}]
PARALLEL = [
    {
        "role": "user",
        "content": "What is the weather in Paris and in Tokyo right now? "
        "Call the weather tool once for each city, both in this turn.",
    }
]
SPECIAL = [
    {
        "role": "user",
        "content": "Create the file hello.py with exactly this content, character for character, "
        "with nothing added or changed:\n\n```python\n" + FILE_CONTENT + "```",
    }
]
ROUND_TRIP = [
    *SINGLE,
    {
        "role": "assistant",
        "content": "",
        "tool_calls": [
            {
                "id": "call_1",
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "arguments": json.dumps({"city": "Paris", "unit": "celsius"}),
                },
            }
        ],
    },
    {
        "role": "tool",
        "tool_call_id": "call_1",
        "content": json.dumps({"temperature": 18, "sky": "cloudy"}),
    },
]
PLAIN = [{"role": "user", "content": "In about 150 words, explain why the sky is blue."}]

Case = tuple[str, dict[str, Any], Callable[[Result], None]]


def cases() -> list[Case]:
    out: list[Case] = []
    for stream in (False, True):
        mode = "streaming" if stream else "non-streaming"
        extra: dict[str, Any] = (
            {"stream": True, "stream_options": {"include_usage": True}} if stream else {}
        )
        out += [
            (
                f"single tool call, {mode}",
                {"messages": SINGLE, "tools": TOOLS, **extra},
                check_single,
            ),
            (
                f"two tool calls, {mode}",
                {"messages": PARALLEL, "tools": TOOLS, **extra},
                check_parallel,
            ),
            (
                f"arguments with quotes and newlines, {mode}",
                {"messages": SPECIAL, "tools": TOOLS, **extra},
                check_special,
            ),
            (
                f"answer from a tool result, {mode}",
                {"messages": ROUND_TRIP, "tools": TOOLS, **extra},
                check_round_trip,
            ),
        ]
    out.append(
        (
            "plain answer of about 200 tokens, streaming (speed, no thinking)",
            {
                "messages": PLAIN,
                "max_tokens": 400,
                "stream": True,
                "stream_options": {"include_usage": True},
            },
            check_answer,
        )
    )
    return out


def speed(result: Result) -> str:
    usage = result.usage or {}
    tokens = usage.get("completion_tokens")
    parts = [f"{result.seconds:.1f}s total"]
    if usage.get("prompt_tokens") is not None:
        parts.append(f"{usage['prompt_tokens']} prompt tokens")
    if tokens:
        parts.append(f"{tokens} completion tokens")
    if result.first_token_seconds is not None:
        parts.append(f"first token after {result.first_token_seconds:.1f}s")
        decode = result.seconds - result.first_token_seconds
        if tokens and tokens > 1 and decode > 0:
            parts.append(f"generation {(tokens - 1) / decode:.1f} tok/s")
    return ", ".join(parts)


def report(results: list[Result], url: str) -> str:
    lines = [f"# Tool-call check against {url}", ""]
    passed = sum(r.passed for r in results)
    lines += [
        f"{passed} of {len(results)} cases passed.",
        "",
        "| Case | Result | Time |",
        "| --- | --- | --- |",
    ]
    for r in results:
        lines.append(f"| {r.name} | {'PASS' if r.passed else 'FAIL'} | {speed(r)} |")
    for r in results:
        lines += ["", f"## {r.name}: {'PASS' if r.passed else 'FAIL'}", ""]
        for description, ok in r.checks:
            lines.append(f"- [{'x' if ok else ' '}] {description}")
        if r.error:
            lines.append(f"- error: {r.error}")
        lines += [
            "",
            f"Timing: {speed(r)}",
            "",
            "Request:",
            "",
            "```json",
            json.dumps(r.request, indent=2, ensure_ascii=False),
            "```",
        ]
        if r.request.get("stream"):
            lines += [
                "",
                "Assembled message:",
                "",
                "```json",
                json.dumps(r.message, indent=2, ensure_ascii=False),
                "```",
            ]
            lines += ["", "Raw stream:", "", "```text", r.raw, "```"]
        elif r.raw:
            try:
                pretty = json.dumps(json.loads(r.raw), indent=2, ensure_ascii=False)
            except ValueError:
                pretty = r.raw
            lines += ["", "Response:", "", "```json", pretty, "```"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default="http://127.0.0.1:8100", help="server base URL")
    parser.add_argument("--api-key", help="Bearer key (for the gateway)")
    parser.add_argument("--model", help="model name to send (default: none, the server default)")
    parser.add_argument("--timeout", type=float, default=900, help="seconds per request")
    parser.add_argument("--output", help="also write the report to this file")
    args = parser.parse_args(argv)

    client = Client(args.url, args.api_key, args.model, args.timeout)
    results = []
    for name, body, check in cases():
        print(f"running: {name} ...", file=sys.stderr, flush=True)
        result = client.run(name, body)
        if result.error is None:
            check(result)
        print(
            f"  {'PASS' if result.passed else 'FAIL'} ({speed(result)})",
            file=sys.stderr,
            flush=True,
        )
        results.append(result)
    text = report(results, args.url)
    print(text)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
    return 0 if all(r.passed for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
