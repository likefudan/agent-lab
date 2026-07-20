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

`bin/agent-lab benchmark` dispatches `scripts/benchmark.sh` (Ollama MVP). Results
are written under ignored `.agent-lab/results/` and must not be committed.

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

## Multi-backend benchmark (P10)

`bin/agent-lab benchmark-backends` dispatches `scripts/benchmark-backends.sh`.
It builds a matrix of ready/startable backends × executable alias pins × fixed
prompts (thinking/tools off), serializes heavy servers, unloads between runs,
and writes comparable JSON plus a short markdown summary. Gemma vision is a
separate cell on vision-capable backends (`ollama`, `mlx_vlm`, …).

```sh
# Schema-valid stub (planned matrix; no inference)
bin/agent-lab benchmark-backends --dry-run

# Tiny live sample against one ready backend (keeps runtime short)
bin/agent-lab benchmark-backends --smoke --backends ollama --aliases qwen-4b

# Full comparative matrix (quiet host; one heavy server at a time — P10-T08)
bin/agent-lab benchmark-backends --runs 3 \
  --output .agent-lab/results/benchmark-backends-latest.json

# Refuse compare when digests/revisions (or matrix membership) differ
bin/agent-lab benchmark-backends --dry-run \
  --compare .agent-lab/results/benchmark-backends-latest.json
```

Default outputs: `.agent-lab/results/benchmark-backends-<timestamp>.json` and a
sibling `.md` summary. Do not commit results. Full campaign recording belongs in
decision `0013` (P10-T08), not in this harness task.

## Path B debug (Open WebUI → Ollama)

When browser chat feels slower than `benchmark`, use Path B: authenticated
`POST /ollama/api/chat` through Open WebUI (same hop as the Ollama provider),
with explicit `think` / `num_predict`. Default prompt is `世界杯是什么？`.

```sh
bin/agent-lab start
bin/agent-lab debug-webui-chat
bin/agent-lab debug-webui-chat --think on --compare-direct --runs 2
bin/agent-lab debug-webui-chat --alias qwen-9b --prompt '用三句话解释世界杯'
```

Results: `.agent-lab/results/debug-webui-chat-<timestamp>.{json,md}` (gitignored).
This is not the browser Advanced Params panel — if UI still diverges, inspect the
live request body in DevTools.

## Same-prompt backend compare

Compare `ollama` / `mlx_lm` / `mlx_vlm` on one fixed question (default
`世界杯是什么？`):

```sh
bin/agent-lab debug-backends-chat
bin/agent-lab debug-backends-chat --backends ollama,mlx_lm --aliases qwen-4b --runs 2
```

MLX cells stop Ollama by default for fair 24 GiB memory; pass `--keep-ollama` to
leave it running. Results: `.agent-lab/results/debug-backends-chat-<timestamp>.{json,md}`.
