# 0010 — MVP qualification

Status: **Accepted — MVP qualification complete**

Date: 2026-07-22 (America/Los_Angeles)

## Decision

The implementation on `codex/implement-local-ai-stack` at commit
`03516bb92ecba8204b511f22371d07755edf1d81` passes the local functional,
recovery, regression, search, hardware, and strict offline qualification rows
below. The final strict run combines the operator's physical/LuLu boundary
attestation with a checked in-container local preflight and failed external
probe; it does not independently inspect LuLu rules.

The annotated `v0.1.0-rc.1` tag was already published as the historical MVP
freeze at commit `a7bb65b2877b19c7041c85a36573d556a4b0f759` (its annotation records tested
commit `cb61eda11f457d06f822fcab15a373a01c6d96e1`). It is intentionally preserved
rather than moved after qualification hardening.

The tested host was `Mac17,3`, Apple M5, 24 GiB unified memory, macOS 26.5.2,
on AC power. The runtime was Ollama 0.32.1 and Open WebUI 0.10.2 at the immutable
OCI digest recorded in [components.json](../../config/components.json).

## Acceptance evidence

| Row | Command | Result |
| --- | --- | --- |
| Catalog/static | `make test-static` | Pass, including ShellCheck 0.11.0 at error severity, catalog semantics, Compose rendering, links, secret signatures, ignored runtime data, and whitespace |
| Smoke | `make test-smoke` | Pass: doctor, Open WebUI text/image/persistence, LLM CLI, and Aider repair/offline behavior |
| Integration | `make test-integration` | Pass: diagnostics, model helpers, stack lifecycle, RAG persistence, backup/restore, and isolated Ollama lifecycle |
| Online search | `tests/integration/test-search.sh` | Pass: both DuckDuckGo cases, citations, profile gating, and local automatic tool choice |
| Prompt regression | Command in [evals/README.md](../../evals/README.md) | 22/22 pass, zero errors, local Ollama only; ignored result `promptfoo-qualification.json` |
| Bad-response control | `npm run test:bad-fixture` in `evals/` | Pass: the deliberately incorrect response is rejected |
| Offline configuration | `make test-offline` | Pass: offline profile, local chat, denied search/pull/remote-model paths, and profile restoration |
| Offline full workflows | `bin/agent-lab offline verify --config-only --full` | Pass: WebUI text/image/persistence, LLM CLI, Aider, RAG, denial paths, and all three live model switches |
| Hardware | `bin/agent-lab benchmark --runs 3 ...` | Pass, no inference failures and no critical memory pressure; ignored result `benchmark-20260722T115952Z.json` |
| Recovery | Included by integration suite | Pass: disposable restored container recovered a conversation and RAG vectors; corrupt, incompatible, traversal, existing-volume, and live-volume targets were rejected |
| Strict zero egress | `bin/agent-lab offline verify --boundary-confirmed --full` | Pass at `2026-07-22T12:15:16Z`: operator-attested boundary plus WebUI probe, denied remote attempts, verified local core, restored `online-manual` |

The disposable restore drill creates a new volume and container, which is the
documented clean-room equivalent used for data recovery. The normal smoke and
RAG suites intentionally reuse the durable primary test volume to verify
persistence rather than erase existing user data.

## Hardware result

The three-run order was randomized and serialized, with unloading between
samples and a 4,096-token context. Values below are medians; spread is
`(max-min)/median`. Ollama's non-streaming response does not expose the first
token timestamp, so estimated TTFT is load time plus prompt evaluation plus one
average generated-token interval; it is not an observed streaming timestamp.

| Model | Decode tokens/s | Cold load | Estimated TTFT | Total latency | Peak Ollama RSS | Minimum free memory | Spread | Sustained change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `qwen3.5:4b` | 27.67 | 2.27 s | 2.50 s | 5.42 s | 4.64 GiB | 56% | 3.73% | -0.30% |
| `qwen3.5:9b` | 16.26 | 3.28 s | 3.66 s | 7.42 s | 7.02 GiB | 55% | 15.36% | -14.83% |
| `gemma4:12b` | 11.67 | 2.84 s | 3.39 s | 9.58 s | 7.91 GiB | 57% | 15.83% | -15.71% |

These results support the existing role defaults: Qwen 4B for fast work, Qwen
9B for general chat, and Gemma 12B for coding and vision. Keeping exactly one
large model resident remains appropriate on this 24 GiB host. The observed
performance is usable for local interactive work; Gemma is materially slower
and should be selected when its coding or vision capability is needed.

## Known limitations and evidence scope

- The strict verifier completed with boundary
  `user_attested_boundary_webui_probe_passed`. This combines the operator's
  physical/LuLu attestation with a checked in-container local preflight and
  failed external probe; it does not inspect LuLu's rules independently.
- DuckDuckGo is an external dependency in online profiles and may change or be
  unavailable. Its test is deliberately separate from offline evidence.
- Model output can include harmless Markdown fences even when compact JSON is
  requested. The vision regression accepts an optional JSON fence but still
  requires object-shaped output and the exact qualified visual facts.
- Promptfoo's Node runtime prints an experimental decompression warning. It did
  not affect the 22/22 result; telemetry, sharing, caching, remote generation,
  and hosted judges were disabled.

The strict boundary row passed. The fast release gate is rerun after this
documentation update, and the published historical `v0.1.0-rc.1` tag remains
unchanged.
