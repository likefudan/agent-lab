# Implementation status and continuation handoff

Updated: 2026-07-19 (America/Los_Angeles)

This document preserves the implementation state because `.cursor/` is local
editor metadata and is intentionally ignored. The detailed task definitions
remain in `.cursor/plans/agent-lab-implementation.plan.md` on this workstation.

Work continues on branch `cursor-impl` only. Do not mutate `main` or
`codex/implement-local-ai-stack` from this handoff.

## Completed plan tasks

- P0-T01 through P0-T05: host, runtime, model, Open WebUI, and RAG-model
  qualification
- P1-T01 through P1-T04: catalogs, safety helpers, CLI dispatcher, and static
  checks
- P2-T01 through P2-T03: managed Ollama, approved model setup, and single-model
  lifecycle
- P3-T01 through P3-T03: pinned Open WebUI, lifecycle, browser/API chat,
  multimodal input, model presentation, and persistence
- P4-T01 and P4-T02: LLM CLI and Aider local interfaces
- P5-T01 through P5-T03: RAG corpus, built-in local RAG, and extraction decision
- P6-T01 through P6-T04: profiles, DuckDuckGo search, strict offline boundary
  verification, and the decision to defer SearXNG
- P7-T01 through P7-T03: diagnostics, backup/restore, and recovery procedures

## In progress

### P8-T01: Promptfoo regression suites

The earlier subagent stopped before writing Promptfoo configuration. Restart
this task from its plan section. Existing chat, image, RAG, and search fixtures
are ready to reuse.

## Pending plan tasks

- P8-T01: Promptfoo regression suites
- P8-T02: native hardware benchmark
- P8-T03: full MVP acceptance matrix and qualification decision
- P9-T01: final installation and first-run documentation
- P9-T02: final operations/privacy/recovery documentation pass
- P9-T03: manifest freeze and release-candidate gate

## P6-T03 completion notes

Repository changes on `cursor-impl`:

- `scripts/offline-verify.sh`
- `tests/integration/test-offline.sh`
- `docs/privacy.md`

Verified commands:

1. `tests/integration/test-offline.sh` — PASS
2. `bin/agent-lab offline verify --config-only --full` — PASS
   (`boundary=configuration_only`)
3. `bin/agent-lab offline verify --boundary-confirmed --full` — PASS
   (`boundary=user_controlled_egress_block_verified`)

Host-only boundary setup used for the third command:

- LuLu 4.3.2 installed via Homebrew cask
- `lulu-cli` installed via `woop/tap/lulu-cli`
- Explicit Block rules for Docker.app, `com.docker.backend`,
  `com.docker.virtualization`, `com.docker.vmnetd`, and the Homebrew Ollama
  binary
- LuLu preference `allowLocalHost=true` preserved so container→host Ollama
  loopback continued to work

Those LuLu Block rules remain active after verification. Relax or delete them
in LuLu (or via `lulu-cli`) when normal Docker outbound access is needed again.

## Verified state at pause

- Ollama 0.32.1 is installed as the per-user managed LaunchAgent on
  `127.0.0.1:11434` with cloud integration disabled.
- Open WebUI 0.10.2 runs from the pinned OCI digest on
  `http://127.0.0.1:3000` with durable named-volume data.
- Active profile: `online-manual`.
- Qualified model presentation: `qwen3.5:4b`, `qwen3.5:9b`, and `gemma4:12b`.
- Offline configuration-only and LuLu boundary-confirmed full verification both
  passed on 2026-07-19; profile restored to `online-manual`.
- `make test-static` passed previously; ShellCheck remains an explicit release
  prerequisite and was skipped because it is not installed.

## Host-only changes already made

- Homebrew Ollama 0.32.1 and its managed per-user LaunchAgent
- LLM CLI 0.31.1 plus `llm-ollama` 0.16.1 in the user uv environment
- Aider 0.86.2 in a uv-managed Python 3.12.13 tool environment
- Six Ollama artifacts retained locally (three approved standard artifacts and
  three rejected MLX qualification artifacts)
- Docker named volume `agent-lab-open-webui-data`
- LuLu 4.3.2 plus Docker/Ollama outbound Block rules (still active)

Secrets, model weights, caches, chats, vectors, logs, results, `.env`, and
`.cursor/` remain ignored and must not be committed.
