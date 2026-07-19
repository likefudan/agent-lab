# Agent Lab evaluations

Agent Lab owns acceptance cases and hardware results. Promptfoo and the native
benchmark script execute them against **local** Ollama on `127.0.0.1:11434`.
Hosted evaluators, Promptfoo Cloud sharing, and remote inference endpoints are
not used by the default suites.

## Prerequisites

- Node.js >= 20 and npm (Homebrew `node` is fine)
- Promptfoo pinned in this directory (`promptfoo@0.121.19`)
- Approved Ollama models from `config/models.json` already pulled
- Ollama listening on loopback with cloud disabled

```sh
cd evals
npm ci
export OLLAMA_BASE_URL=http://127.0.0.1:11434
```

Install creates `node_modules/` (gitignored). Commit `package-lock.json` when it
changes so digests stay comparable across hosts.

## Suites and tags

Cases live in `fixtures/regression/cases.yaml` and reuse:

- `fixtures/model-qualification/` for chat, code, tools, and vision assets
- `fixtures/rag/questions.json` facts for RAG/citation prompts
- `fixtures/search/questions.json` facts for search-grounded prompts

Each case carries metadata:

| Key | Values | Purpose |
| --- | --- | --- |
| `suite` | `fast`, `full` | Separate quick regressions from longer qualification |
| `profile` | `offline`, `online-manual` | Required Agent Lab profile semantics |
| `capability` | `text`, `code`, `tools`, `vision`, `rag`, `citations`, `search` | Model or workflow capability |
| `network` | `none`, `egress` | Whether live outbound search is required |
| `cost` | `low`, `medium`, `high` | Relative runtime cost |

Live DuckDuckGo search is **not** part of Promptfoo. When host egress is
available (and LuLu Block rules for Docker/Ollama are relaxed), run
`tests/integration/test-search.sh` separately so offline proof stays
unambiguous.

## Commands

Validate configuration (no model calls):

```sh
cd evals
npm run validate
```

Fast suite against each eligible local model (`suite=fast`, concurrency 1):

```sh
mkdir -p ../.agent-lab/results
npm run eval:fast
```

Full suite (includes search-grounded context cases; still local-only):

```sh
npm run eval:full
```

Prove deterministic assertions can fail using deliberate bad responses (expects
non-zero exit):

```sh
npm run eval:selftest
node fixtures/assertions/verify-bad-responses.js
```

Raw Promptfoo JSON lands under ignored `.agent-lab/results/`.

## Providers

| Provider | Role |
| --- | --- |
| `ollama:chat:qwen3.5:4b` / `9b` / `gemma4:12b` | Text, instruction, refusal, JSON, code, RAG, citations, search-grounded |
| `fixtures/regression/providers/ollama-tools.js` | Native `/api/chat` tool calls for all three approved tags |
| `fixtures/regression/providers/ollama-vision.js` | Multimodal case for `gemma4:12b` only |
| `fixtures/assertions/bad-provider.js` | Offline assertion self-test (no network) |

`OLLAMA_BASE_URL` is pinned to `http://127.0.0.1:11434` in
`promptfooconfig.yaml`. Do not point providers at hosted APIs.

## Hardware benchmark

`bin/agent-lab benchmark` dispatches `scripts/benchmark.sh`. Results are written
under ignored `.agent-lab/results/` and must not be committed.

```sh
# Schema-valid stub without inference
bin/agent-lab benchmark --dry-run

# Timed samples (warm-up, randomized model order, median + stdev)
bin/agent-lab benchmark --runs 3 --output .agent-lab/results/benchmark-latest.json

# Dedicated same-model concurrency case (optional)
bin/agent-lab benchmark --runs 3 --concurrency

# Reject comparison when component/model digests differ
bin/agent-lab benchmark --dry-run --compare .agent-lab/results/benchmark-latest.json
```

The report records host baseline, component and model digests, active profile,
ambient memory pressure, prompt/input size, output token budget, cold load,
TTFT, tokens/sec, peak Ollama RSS, system free-memory percent, switch time,
failure rate, and a sustained-run proxy for thermal throttling. Keep-alive and
default chat recommendations are emitted for the 24 GB Apple Silicon target.
