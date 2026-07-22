# Implementation status and continuation handoff

Updated: 2026-07-22 (America/Los_Angeles)

The MVP implementation is functionally complete on
`codex/implement-local-ai-stack`. One user-controlled release test remains
before the release-candidate tag may be created: the strict physical or LuLu
zero-egress run described below. `.cursor/` remains ignored editor metadata;
this tracked document and [decision 0010](decisions/0010-mvp-qualification.md)
are the continuation authority.

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
- P8-T03 except its mandatory strict-boundary row: static, smoke, integration,
  search, Promptfoo, configuration-only full offline, benchmark, and recovery
  rows pass
- P9-T01/T02: installation, first-run, operations, privacy, limitations, and
  recovery documentation
- P9-T03 manifest work: runtime, UI, CLI, evaluation packages, embedding model,
  and model artifacts have exact versions plus immutable revisions/digests

## Release blocker

P6-T03 and the final P8/P9 release gates require a user-controlled outbound
boundary. LuLu is installed on the qualified Mac, but reviewed blocking rules
were not enabled during this task. The safe connected-host command has passed:

```sh
bin/agent-lab offline verify --config-only --full
```

That result explicitly does **not** prove zero egress. To clear the blocker,
turn off Wi-Fi and disconnect Ethernet, or enable reviewed LuLu rules that block
outbound traffic for Docker Desktop and Ollama while preserving local traffic,
then run:

```sh
bin/agent-lab offline verify --boundary-confirmed --full
```

The ignored `.agent-lab/results/offline-latest.json` must report status `pass`
and boundary `user_attested_boundary_webui_probe_passed`. Restore networking after
review. Only then rerun the fast release gate, record the final commit in
decision 0010, and create `v0.1.0-rc.1`.

## Verified host state

- Host: Mac17,3, Apple M5, 24 GiB unified memory, macOS 26.5.2
- Ollama 0.32.1: Agent Lab per-user LaunchAgent, loopback-only, cloud disabled,
  one loaded model maximum
- Open WebUI 0.10.2: immutable OCI digest, loopback port 3000, durable named
  volume
- Active default profile: `online-manual`
- Approved models: `qwen3.5:4b`, `qwen3.5:9b`, and `gemma4:12b`
- Local RAG: pinned `all-MiniLM-L6-v2`, Chroma, hybrid retrieval, no reranker
- Terminal clients: LLM CLI 0.31.1 with `llm-ollama` 0.16.1; Aider 0.86.2 on
  uv-managed Python 3.12.13
- Evaluation: Promptfoo 0.121.19; ShellCheck 0.11.0

Generated results, secrets, model weights, caches, chats, vectors, logs,
`.env`, `.agent-lab/`, and `.cursor/` remain outside Git.

## Post-MVP

P10 in the local Cursor plan is a separate multi-backend phase covering direct
MLX, llama.cpp, and optional LM Studio paths. It does not change the MVP release
gate and must not be reported as implemented by the Ollama-only MVP work.
