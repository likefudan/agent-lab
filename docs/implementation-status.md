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
- P8-T01: Promptfoo regression suites (pinned local-only Promptfoo 0.121.19)
- P8-T02: native hardware benchmark (`scripts/benchmark.sh` / `agent-lab benchmark`)
- P8-T03: MVP acceptance matrix and qualification decision
  (`docs/decisions/0010-mvp-qualification.md`)
- P9-T01: installation and first-run documentation (`README.md`,
  `docs/installation.md`) with recorded operator walkthrough
- P9-T02: operations, privacy, and recovery documentation finalized with the
  same walkthrough (offline + backup/restore)
- P9-T03: MVP manifest freeze and release candidate `v0.1.0-rc.1`

## Pending plan tasks

- None (P0–P9 complete on `cursor-impl`)

## P8 completion notes

Repository changes on `cursor-impl`:

- `evals/promptfooconfig.yaml`, `evals/promptfooconfig.assertion-selftest.yaml`
- `evals/package.json`, `evals/package-lock.json`, `evals/README.md`
- `evals/fixtures/regression/`, `evals/fixtures/assertions/`
- `scripts/benchmark.sh`
- `tests/smoke/run.sh`, `tests/integration/run.sh`
- `tests/static/run.sh` (prune `evals/node_modules` from Markdown link scan)
- `tests/integration/test-lifecycle.sh` (match actual `agent-lab health` FAIL text)
- `docs/decisions/0010-mvp-qualification.md`

Verified on close-out:

| Command | Result |
| --- | --- |
| `make test-static` | PASS (ShellCheck SKIP) |
| Smoke (LLM CLI, Aider, Open WebUI) | PASS |
| `make test-integration` | PASS (isolated model-lifecycle SKIP while `:11434` busy) |
| `make test-offline` | PASS (`configuration_only`, profile restored to `online-manual`) |
| Promptfoo fast suite | PASS 28/28 |
| `bin/agent-lab benchmark` | PASS; recommend keep-alive `5m`, default chat `qwen-9b` |
| `tests/integration/test-search.sh` | PASS after temporary LuLu Allow; Docker/Ollama Block rules restored |

LuLu Block rules from P6-T03 remain active. They are correct for offline egress
proof and currently prevent Docker-originated DuckDuckGo search. Relax them only
when intentionally re-qualifying online search; do not loosen product security
to force a pass.

## Verified state at handoff

- Ollama 0.32.1 on `127.0.0.1:11434` (managed LaunchAgent, cloud disabled)
- Open WebUI 0.10.2 on `http://127.0.0.1:3000` with durable volume
  `agent-lab-open-webui-data`
- Active profile: `online-manual`
- Qualified models: `qwen3.5:4b`, `qwen3.5:9b`, `gemma4:12b`
- Host tools added for P8: Homebrew Node.js 26.5.0 / npm 11.17.0; Promptfoo
  installed under `evals/node_modules` (gitignored)

## Host-only changes

- Prior: Ollama, LLM CLI, Aider, models, Open WebUI volume, LuLu Block rules
- P8: Homebrew `node` 26.5.0; Promptfoo local install via `evals/npm ci`
- LuLu Docker/Ollama outbound Block rules still active

Secrets, model weights, caches, chats, vectors, logs, results, `.env`,
`evals/node_modules/`, and `.cursor/` remain ignored and must not be committed.
