# 0006 — Ollama model lifecycle qualification

- **Status:** Accepted
- **Qualified:** 2026-07-18
- **Runtime:** Ollama `0.32.1`
- **Host:** Apple M5 MacBook Air with 24 GiB unified memory
- **Raw result:** ignored `.agent-lab/results/model-lifecycle.json`

## Decision

Keep `OLLAMA_MAX_LOADED_MODELS=1` for the MVP. All three approved standard
artifacts load, switch, unload, and recover on the target host without sustained
critical memory pressure. Agent Lab therefore delegates residency and switching
to Ollama and does not add a model supervisor.

Use Ollama's normal keep-alive behavior for now. Explicit `keep_alive: 0`
unloaded each tested model and returned `/api/ps` to an empty model list within
the 20-second bounded check. P8-T02 may tune the production keep-alive value
after longer latency, memory, and thermal benchmarks.

## Measured serial switching

The test started one isolated loopback Ollama server with cloud disabled, a
one-model limit, and a five-minute test keep-alive. Each request used a 4,096
token context and a deterministic short response.

| Model | Request plus cold load | Resident GPU bytes | System memory free |
| --- | ---: | ---: | ---: |
| `qwen3.5:4b` | 2 s | 3,219,547,749 | 60% |
| `qwen3.5:9b` | 3 s | 5,649,538,743 | 46% |
| `gemma4:12b` | 3 s | 8,047,254,567 | 41% |

`/api/ps` reported exactly one matching model after every switch and never more
than one model during the serial or concurrent-request cases. The memory figure
is Ollama's resident GPU allocation; the system percentage comes from
`memory_pressure -Q`. These are lifecycle safety observations, not the
instrumented peak-memory and thermal measurements owned by P8-T02.

The slowest observed short request plus cold load was three seconds. The test
allows 30 seconds for server health, 20 seconds for unload, and 240 seconds for
an inference request. Those bounds leave ample room for a thermally constrained
host and longer concurrent scheduling without treating a normal cold load as a
failure.

## Recovery and failure cases

The versioned integration test passed all of the following:

- a nonexistent model returned HTTP 404 locally and left the server healthy;
- two simultaneous requests for different approved models both completed while
  polling observed no more than one resident model;
- cancelling a long streaming client left the server healthy, and a following
  request completed normally;
- explicit unload released the model and left `/api/ps` empty;
- stopping and restarting the local server preserved the model store and served
  a new request without a pull or catalog change;
- final cleanup stopped the test-owned server and released port `11434`.

The test verifies only a process restart, not an operating-system crash or a
reboot. The launchd persistence drill remains a manual host test after the user
explicitly installs the Agent Lab LaunchAgent.

## Reproduction

Stop any existing process on loopback port `11434`, then run:

```sh
tests/integration/test-model-lifecycle.sh
```

The command verifies approved model manifests and blobs before starting its
temporary server. It does not pull, remove, or modify a model. Raw results are
written under the ignored `.agent-lab/results/` directory, and temporary logs
are removed when the test exits.

## Consequences

- P2 and P3 lifecycle scripts must retain the one-model limit.
- Clients may request any approved alias directly; Ollama owns serialization,
  unload, and switch behavior.
- A missing model remains a local error. Setup is the only approved pull path.
- P8 owns longer performance, peak-memory, and thermal qualification before a
  keep-alive default changes.
