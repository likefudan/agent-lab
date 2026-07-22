# Agent Lab evaluations

This directory pins Promptfoo and defines versioned, deterministic regression
cases for the three approved Ollama artifacts. Promptfoo targets only
`http://127.0.0.1:11434`; sharing and telemetry are disabled, and the suite has
no hosted or LLM-graded assertions.

## Install and validate

Node.js 20 or newer is required. From this directory:

```sh
npm ci
npm run validate
```

The exact Promptfoo version is recorded in `package.json` and
`package-lock.json`. Validation parses the configuration without calling a
model. `fixtures/bad-response.json` supplies an intentionally wrong
`providerOutput`; this command proves the deterministic assertion rejects it
without calling Ollama:

```sh
npm run test:bad-fixture
```

The command succeeds only when Promptfoo reports an assertion failure.

The npm scripts preload `fixtures/node-keepalive.cjs` to work around Promptfoo
0.121.19's unreferenced shutdown timer on Node 26. The shim makes no requests
and changes no evaluation data; Promptfoo still performs its own normal exit.

## Run regressions

Start the reviewed Agent Lab stack, verify the cataloged model digests, and run:

```sh
npm run eval:fast
npm run eval:full
```

Both commands force concurrency to one for this laptop. The fast suite runs
chat, instruction-following, refusal, structured tool selection, and code cases
against `qwen3.5:4b`, `qwen3.5:9b`, and `gemma4:12b`. The full suite adds image,
RAG grounding, citation, and recorded-search cases. Provider allowlists keep the
image case on the only cataloged vision model, `gemma4:12b`.

Every case carries `suite`, `profile`, `capability`, `network_need`, and
`estimated_seconds_per_model` metadata. For example:

```sh
npm run eval:full -- --filter-metadata capability=vision
```

The search regression uses a recorded, versioned result and performs no live
network request. Live DuckDuckGo/Open WebUI integration remains covered by
`../tests/integration/test-search.sh`; RAG ingestion/retrieval remains covered
by `../tests/integration/test-rag.sh`. Promptfoo tests the model behavior after
context is supplied and does not claim to replace those integration tests.

## Multimodal fixture

`fixtures/vision-prompt.json` contains an Ollama chat message with the base64
bytes of the existing qualified `model-qualification/vision-card.svg.png`.
Regenerate it only when that image deliberately changes; the expected card is a
blue triangle labeled `AGENT 42`.

## Result handling

The package scripts use `--no-write`, `--no-cache`, and `--no-share`. For an
explicit qualification record, write output only beneath the ignored runtime
directory, for example:

```sh
NODE_OPTIONS='--require=./fixtures/node-keepalive.cjs' \
PROMPTFOO_DISABLE_TELEMETRY=1 PROMPTFOO_DISABLE_SHARING=1 \
PROMPTFOO_DISABLE_REMOTE_GENERATION=1 \
./node_modules/.bin/promptfoo eval -c promptfooconfig.yaml \
  --max-concurrency 1 --no-cache --no-share \
  --output ../.agent-lab/results/promptfoo-qualification.json
```

Record the Ollama version and model manifest digests beside any retained result
so comparisons refer to identical artifacts. Never use `--remote`, `--share`,
model-graded assertions, or a hosted grader for the Agent Lab acceptance gate.

## Native hardware benchmark

Run the quiet-host benchmark only when no other model workload is active:

```sh
bin/agent-lab benchmark --runs 3 \
  --ambient "indoor, unobstructed airflow, no other foreground workload"
```

The ignored JSON result records host and power metadata, exact component and
model digests, randomized sample order, prompt/output sizes, cold load, estimated
time to first token, tokens per second, total/switch latency, peak Ollama RSS,
system memory pressure, failure rate, dispersion, and sustained throughput
change. `--dry-run` validates a campaign without loading models. Compare two
results only when host and model digests match:

```sh
bin/agent-lab benchmark --compare baseline.json candidate.json
```

The command rejects mismatched host hardware or model manifests rather than
presenting an invalid performance delta.
