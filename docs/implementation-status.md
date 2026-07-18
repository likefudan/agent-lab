# Implementation status and continuation handoff

Updated: 2026-07-18 (America/Los_Angeles)

This document preserves the implementation state because `.cursor/` is local
editor metadata and is intentionally ignored. The detailed task definitions
remain in `.cursor/plans/agent-lab-implementation.plan.md` on this workstation.

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
- P6-T01, P6-T02, and P6-T04: validated profiles, DuckDuckGo search, and the
  decision to defer SearXNG
- P7-T01 through P7-T03: diagnostics, backup/restore, and recovery procedures

## In progress

### P6-T03: strict offline verification

Implemented:

- `scripts/offline-verify.sh`
- `tests/integration/test-offline.sh`
- `docs/privacy.md`
- Open WebUI recreation with `OFFLINE_MODE=true`
- local denial tests for search, model pulls, and unavailable remote models
- signal/exit restoration of the prior profile
- a configuration-only offline test that passes and makes no firewall claim

Remaining acceptance work:

1. Run the full workflow again without interruption:
   `bin/agent-lab offline verify --config-only --full`.
2. The interrupted run passed Open WebUI text/image/persistence and the complete
   LLM CLI suite, then was interrupted during Aider. Online-manual mode was
   restored manually afterward.
3. Perform the documented user-controlled boundary run with Wi-Fi/Ethernet off
   or reviewed LuLu rules:
   `bin/agent-lab offline verify --boundary-confirmed --full`.
4. Keep the distinction between application configuration and a measured
   zero-egress boundary explicit.

An experiment using a Docker `--internal` network was rejected because Docker
Desktop stopped forwarding the loopback browser port after the normal Compose
network was disconnected. The unused experimental network was removed; no
experimental code remains.

### P8-T01: Promptfoo regression suites

The subagent was stopped before it wrote Promptfoo configuration. Restart this
task from its plan section. Existing chat, image, RAG, and search fixtures are
ready to reuse.

## Pending plan tasks

- P8-T01: Promptfoo regression suites
- P8-T02: native hardware benchmark
- P8-T03: full MVP acceptance matrix and qualification decision
- P9-T01: final installation and first-run documentation
- P9-T02: final operations/privacy/recovery documentation pass
- P9-T03: manifest freeze and release-candidate gate

## Verified state at pause

- Ollama 0.32.1 is installed as the per-user managed LaunchAgent on
  `127.0.0.1:11434` with cloud integration disabled.
- Open WebUI 0.10.2 runs from the pinned OCI digest on
  `http://127.0.0.1:3000` with durable named-volume data.
- Active profile: `online-manual`.
- Qualified model presentation: `qwen3.5:4b`, `qwen3.5:9b`, and `gemma4:12b`.
- The local store also retains rejected MLX-tag artifacts as qualification
  evidence; they are hidden from normal WebUI use.
- Local RAG uses the bundled pinned `all-MiniLM-L6-v2` snapshot, Chroma, hybrid
  retrieval, and no reranker.
- Real DuckDuckGo search qualification passed both recorded cases.
- Backup/restore passed with a disposable restored container, conversation, and
  RAG vector verification.
- `make test-static` passed; ShellCheck remains an explicit release prerequisite
  and was skipped because it is not installed.

## Host-only changes already made

- Homebrew Ollama 0.32.1 and its managed per-user LaunchAgent
- LLM CLI 0.31.1 plus `llm-ollama` 0.16.1 in the user uv environment
- Aider 0.86.2 in a uv-managed Python 3.12.13 tool environment
- Six Ollama artifacts retained locally (three approved standard artifacts and
  three rejected MLX qualification artifacts)
- Docker named volume `agent-lab-open-webui-data`

Secrets, model weights, caches, chats, vectors, logs, results, `.env`, and
`.cursor/` remain ignored and must not be committed.
