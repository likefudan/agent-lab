"""Prompts of a chosen token length, and the agent simulation's tools and tool results.

Lengths are counted with the same chat template and tokenizer the gateway
uses (``gateway.tokens``), so a "16K" prompt is 16K tokens as the backend
sees it. Text is deterministic filler built from common English words: each
prompt starts with its own seed, so prompts never share a prefix by accident
(the prompt cache must only hit where a test means it to).
"""

from __future__ import annotations

import json
import random
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from agent_lab.gateway.tokens import PromptCounter

# Common words, so the filler tokenizes like ordinary prose (about 1.3 tokens a word).
_WORD_LIST = (
    "the of and to in is that for it as with was on be by this are from or at an have "
    "not but which they one all were their there can has more when will would been "
    "other into some time these could than then first also new any only after over "
    "such use most made work used through where much before must years well should "
    "system data model memory request server client cache token value file test build "
    "change state error result number between under while because small large early "
    "later point group order line case part place world area power level light water "
    "house paper market report review design method process program project question "
    "answer reason simple common public local single final major minor clear quick"
)
WORDS = tuple(_WORD_LIST.split())

SENTENCE_WORDS = 14
MAX_FIT_STEPS = 12
FIT_TOLERANCE = 0.005  # a fitted prompt is within 0.5% (and at least 8 tokens) of its target


@dataclass(frozen=True)
class Prompt:
    messages: list[dict[str, Any]]
    tools: list[dict[str, Any]] | None = None
    tokens: int = 0  # as counted by the gateway's counter


def filler(seed: str, n_words: int) -> str:
    """``n_words`` words of deterministic prose for ``seed``."""
    rng = random.Random(seed)
    sentences = []
    for start in range(0, n_words, SENTENCE_WORDS):
        words = [rng.choice(WORDS) for _ in range(min(SENTENCE_WORDS, n_words - start))]
        sentences.append(" ".join(words).capitalize() + ".")
    return " ".join(sentences)


def file_listing(seed: str, n_words: int) -> str:
    """Filler shaped like a tool's output: numbered lines of about ten words."""
    rng = random.Random(seed)
    lines = []
    for number, start in enumerate(range(0, n_words, 10), start=1):
        words = [rng.choice(WORDS) for _ in range(min(10, n_words - start))]
        lines.append(f"{number:5d}  {' '.join(words)}")
    return "\n".join(lines)


@dataclass
class Counter:
    """Counts prompts with the gateway's counter and the profile's chat template arguments."""

    counter: PromptCounter
    template_args: dict[str, Any] = field(default_factory=dict)

    def count(self, messages: list[dict[str, Any]], tools: list[dict[str, Any]] | None) -> int:
        return self.counter.count(messages, tools, self.template_args)

    def tokens_per_word(self) -> float:
        empty = self.count([{"role": "user", "content": ""}], None)
        full = self.count([{"role": "user", "content": filler("ratio", 2000)}], None)
        return max((full - empty) / 2000, 0.01)


def fit(build: Callable[[int], Prompt], target: int, counter: Counter) -> Prompt:
    """The prompt ``build(n)`` with the most tokens that is still at most ``target`` tokens.

    ``build(n)`` must grow with ``n`` (a number of filler words). The search
    stops once the prompt is within ``FIT_TOLERANCE`` of the target.
    """

    def measured(n: int) -> Prompt:
        prompt = build(n)
        return Prompt(prompt.messages, prompt.tools, counter.count(prompt.messages, prompt.tools))

    base = measured(0)
    if base.tokens > target:
        raise ValueError(f"even an empty prompt has {base.tokens} tokens, over {target}")
    tolerance = max(8, int(target * FIT_TOLERANCE))
    per_word = counter.tokens_per_word()
    best = base
    n = int((target - base.tokens) / per_word)
    for _ in range(MAX_FIT_STEPS):
        if n <= 0:
            break
        prompt = measured(n)
        if prompt.tokens <= target:
            if prompt.tokens > best.tokens:
                best = prompt
            gap = target - prompt.tokens
            if gap <= tolerance:
                break
            n += max(1, int(gap / per_word))
        else:
            n -= max(1, int((prompt.tokens - target) / per_word) + 1)
    return best


def plain_prompt(seed: str, target: int, counter: Counter) -> Prompt:
    """One user message of about ``target`` tokens that asks for a short answer."""

    def build(n: int) -> Prompt:
        text = (
            f"Document {seed}.\n\n{filler(seed, n)}\n\n"
            "In one short sentence, what is the document above about?"
        )
        return Prompt([{"role": "user", "content": text}])

    return fit(build, target, counter)


def long_answer_prompt(seed: str) -> list[dict[str, Any]]:
    """A short request for a long answer: for decode speed."""
    return [
        {
            "role": "user",
            "content": (
                f"(Request {seed}.) Write a long, detailed technical guide about running large "
                "language models on a laptop: hardware, memory, quantization, serving, "
                "monitoring and troubleshooting. Use many sections and examples. Keep "
                "writing; do not stop early or summarize."
            ),
        }
    ]


def _tool(name: str, description: str, properties: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": list(properties),
            },
        },
    }


def _string(description: str) -> dict[str, str]:
    return {"type": "string", "description": description}


# Tools shaped like a coding agent's (Cursor and opencode send about 10-20 such tools).
AGENT_TOOLS = [
    _tool(
        "read_file",
        "Read a file from the workspace and return its contents with line numbers. Use it "
        "before changing a file, and read the whole file when it is short.",
        {"path": _string("Path of the file, relative to the workspace root.")},
    ),
    _tool(
        "list_directory",
        "List the files and directories in a directory of the workspace, one per line, "
        "directories with a trailing slash.",
        {"path": _string("Directory to list, relative to the workspace root.")},
    ),
    _tool(
        "search",
        "Search the workspace for a regular expression and return matching lines with "
        "their file paths and line numbers.",
        {
            "pattern": _string("A regular expression."),
            "path": _string("Directory to search in; use . for the whole workspace."),
        },
    ),
    _tool(
        "write_file",
        "Replace the contents of a file in the workspace, creating it if needed.",
        {
            "path": _string("Path of the file, relative to the workspace root."),
            "content": _string("The complete new contents of the file."),
        },
    ),
    _tool(
        "edit_file",
        "Replace one exact occurrence of a string in a file with another string.",
        {
            "path": _string("Path of the file, relative to the workspace root."),
            "old": _string("The exact text to replace; it must occur exactly once."),
            "new": _string("The replacement text."),
        },
    ),
    _tool(
        "run_command",
        "Run a shell command in the workspace and return its exit status and output.",
        {"command": _string("The command line to run.")},
    ),
]

AGENT_SYSTEM = (
    "You are a coding agent working in a software project. Work step by step. Use the "
    "tools to inspect the project: call exactly one tool in each reply, and never answer "
    "from memory when a tool can tell you. Keep any text outside tool calls very short.\n\n"
    "Project notes follow; they are background for the task.\n\n"
)

AGENT_TASK = (
    "Find out how the request cache in this project works: read the relevant files one "
    "at a time with read_file, starting with src/cache.py, and keep reading files until "
    "I tell you to stop."
)


def agent_start(seed: str, target: int, counter: Counter) -> Prompt:
    """The agent's first request (system prompt, tools and task) of about ``target`` tokens."""

    def build(n: int) -> Prompt:
        system = AGENT_SYSTEM + f"Notes {seed}.\n\n" + filler(seed, n)
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": AGENT_TASK},
        ]
        return Prompt(messages, AGENT_TOOLS)

    return fit(build, target, counter)


def tool_result(seed: str, n_words: int) -> str:
    return json.dumps({"path": f"src/{seed}.py", "content": file_listing(seed, n_words)})
