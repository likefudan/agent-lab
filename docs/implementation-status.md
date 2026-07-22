# Implementation status and continuation handoff

Updated: 2026-07-22 (America/Los_Angeles)

The MVP implementation and qualification are complete on
`codex/implement-local-ai-stack`. The final user-controlled physical or LuLu
zero-egress run passed on 2026-07-22. `.cursor/` remains ignored editor
metadata; this tracked document and
[decision 0010](decisions/0010-mvp-qualification.md) are the continuation
authority.

## Completed

- P0–P5: host/runtime/model qualification, safety helpers, CLI, managed Ollama,
  pinned Open WebUI, browser/terminal/coding interfaces, and local RAG
- P6-T01/T02/T04: three validated profiles, DuckDuckGo search, and the decision
  to defer SearXNG
- P7: diagnostics, backup/restore, and failure-recovery procedures
- P8-T01: pinned local-only Promptfoo suite; 22/22 full regressions pass and the
  deliberately bad response is rejected
- P8-T02: native M5 benchmark with schema validation, cleanup, randomized
  serialized samples, digest-safe comparison, and recorded hardware evidence
- P8-T03: static, smoke, integration, search, Promptfoo, configuration-only and
  strict full offline, benchmark, and recovery rows pass
- P9-T01/T02: installation, first-run, operations, privacy, limitations, and
  recovery documentation
- P9-T03 manifest work: runtime, UI, CLI, evaluation packages, embedding model,
  and model artifacts have exact versions plus immutable revisions/digests
- P10 direct MLX phase: MLX-LM 0.31.3 for Qwen 9B text, MLX-VLM 0.6.6 for
  Gemma 12B vision, revision-pinned Hugging Face snapshots, exclusive backend
  switching, and Open WebUI model presets

## Release qualification

The final strict command passed at `2026-07-22T12:15:16Z`:

```sh
bin/agent-lab offline verify --boundary-confirmed --full
```

The ignored evidence reported status `pass`, boundary
`user_attested_boundary_webui_probe_passed`, denied search/model-pull/remote-model
attempts, verified models/embedding cache/chat, and restored `online-manual`.
This clears the final qualification blocker. The result relies on the operator's
boundary attestation and does not independently inspect LuLu rules.

The annotated `v0.1.0-rc.1` tag remains the published historical MVP freeze at
commit `a7bb65b2877b19c7041c85a36573d556a4b0f759`; release history was not rewritten
after the later qualification hardening. Decision 0010 records the subsequently
qualified implementation commit.

## Verified host state

- Host: Mac17,3, Apple M5, 24 GiB unified memory, macOS 26.5.2
- Ollama 0.32.1: Agent Lab per-user LaunchAgent, loopback-only, cloud disabled,
  one loaded model maximum
- Open WebUI 0.10.2: immutable OCI digest, loopback port 3000, durable named
  volume
- Active default profile: `online-manual`
- Approved models: `qwen3.5:4b`, `qwen3.5:9b`, and `gemma4:12b`
- Direct MLX models: Qwen 3.5 9B 4-bit revision `938d8919…` and Gemma 4 12B
  IT 4-bit revision `73bcf090…`; complete 12.7 GB cache verified by SHA-256
- MLX runtime: Python 3.12.13, MLX-LM 0.31.3 on port 8081, MLX-VLM 0.6.6 on
  port 8082, with one active backend at a time
- Local RAG: pinned `all-MiniLM-L6-v2`, Chroma, hybrid retrieval, no reranker
- Terminal clients: LLM CLI 0.31.1 with `llm-ollama` 0.16.1; Aider 0.86.2 on
  uv-managed Python 3.12.13
- Evaluation: Promptfoo 0.121.19; ShellCheck 0.11.0

Generated results, secrets, model weights, caches, chats, vectors, logs,
`.env`, `.agent-lab/`, and `.cursor/` remain outside Git.

## Post-MVP

The direct MLX portion of P10 is implemented and qualified independently of the
historical Ollama-only `v0.1.0-rc.1` release gate. llama.cpp and optional LM
Studio paths remain unimplemented.
