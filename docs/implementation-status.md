# Implementation status and continuation handoff

Updated: 2026-07-20 (America/Los_Angeles)

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
- P10-T01: pluggable inference backend design and decision
  (`docs/design.md`, `docs/decisions/0011-inference-backends.md`)
- P10-T02: backend/model catalog schema + validator
  (`config/backends.json`, `config/models.json` per-backend slots,
  `scripts/validate-config.sh`)
- P10-T03: per-backend artifact pins (decision 0012)
  (`docs/decisions/0012-backend-model-pins.md`, `config/models.json`)
- P10-T04: backend lifecycle helpers
  (`scripts/lib/backends.sh`, `scripts/backend.sh`, `config/mlx/`,
  `config/llama.cpp/README.md`; doctor/status/health/start/stop wiring)
- P10-T05: active-backend client wiring
  (`scripts/lib/inference.sh`, `scripts/apply-inference.sh`,
  `config/inference/`, compose + Open WebUI / LLM CLI / Aider apply path)
- P10-T06: multi-backend benchmark harness
  (`scripts/benchmark-backends.sh`, `bin/agent-lab benchmark-backends`,
  `evals/README.md`)
- P10-T07: backend integration tests + install/ops/privacy docs
  (`tests/integration/test-backends.sh`, `docs/installation.md`,
  `docs/operations.md`, `docs/privacy.md`)
- P10-T08: M5 comparative campaign + decision 0013
  (`docs/decisions/0013-backend-benchmark-results.md`; raw results under
  `.agent-lab/results/benchmark-backends-20260720T145905Z.*`)

## Pending plan tasks

None for P10. Post-MVP **P10 is complete** (definition of done met). No custom
gateway was introduced. Shipped default remains `ollama` (decision 0013).

## P10 notes

- **P10-T01 done:** ADR `0011` records first-class backends `ollama`, `mlx_lm`,
  `mlx_vlm`, `lm_studio`, `llama_cpp`; active entry via
  `AGENT_LAB_INFERENCE_BACKEND` + OpenAI `/v1`; no custom gateway;
  single-heavy-server policy; optional vision split; suggested loopback ports.
- **P10-T02 done:** `config/backends.json` catalogs the five backends (ports,
  health probes, OpenAI `/v1` templates, managed vs detect). Role aliases
  `qwen-4b`, `qwen-9b`, `gemma-12b` carry per-backend artifact slots; Ollama
  remains executable (MVP freeze), other backends are `candidate` until
  P10-T03. Validator fails closed on unknown backend ids and missing fields.
- **P10-T03 done:** ADR `0012` pins MLX HF revisions:
  `mlx-community/Qwen3.5-4B-MLX-4bit@32f3e8ec…` (`mlx_lm`),
  `mlx-community/Qwen3.5-9B-MLX-4bit@938d8919…` (`mlx_lm`),
  `mlx-community/gemma-4-12B-it-4bit@73bcf090…` (`mlx_vlm`). Ollama pins
  unchanged. `lm_studio` / `llama_cpp` remain `candidate` (apps/GGUF absent).
  Smoke: Qwen text with thinking off; Gemma text + vision (blue triangle /
  `AGENT 42`). Weights in `~/.cache/huggingface` (not committed). Scratch MLX
  venv under `.agent-lab/venvs/mlx` (`mlx-lm` 0.31.3, `mlx-vlm` 0.6.6).
- **P10-T04 done:** `agent-lab backend <list|status|start|stop|use>` manages
  Ollama (LaunchAgent), `mlx_lm` / `mlx_vlm` (PID + wrappers under
  `config/mlx/`), optional `llama_cpp` when binary+GGUF exist, and detect-only
  `lm_studio`. Single-heavy-server stops managed mlx_*/llama_cpp peers on
  start; warns if Ollama/LM Studio still resident. Doctor/status/health surface
  readiness without starting backends.
- **P10-T05 done:** `backend use` / `apply-inference` persist
  `AGENT_LAB_INFERENCE_BACKEND` + OpenAI `/v1` into
  `~/.agent-lab/state/inference.env`, `.agent-lab/llm/`, `.agent-lab/aider/`,
  and Open WebUI provider APIs. Default remains `ollama` (native WebUI +
  `llm-ollama`). Non-Ollama backends disable Ollama in WebUI and exclude
  `llm-ollama` so clients cannot silently fall through. Optional vision split
  (second WebUI OpenAI connection for `mlx_vlm` while text uses `mlx_lm`) is
  noted in `config/inference/README.md`. Profile apply still blocks
  pulls/search offline and re-applies inference wiring after recreate.
- **P10-T06 done:** `agent-lab benchmark-backends` runs a serialized matrix of
  backends × executable pins × fixed prompts (think/tools off; separate Gemma
  vision cell). Emits comparable JSON + markdown under
  `.agent-lab/results/benchmark-backends-*`. `--dry-run` validates schema;
  `--compare` refuses mismatched digests/revisions. Documented in
  `evals/README.md`. Does not run the full P10-T08 campaign.
- **P10-T07 done:** `tests/integration/test-backends.sh` smokes health + one
  chat completion for running backends, skips absent optionals (mlx venv,
  lm_studio detect, llama_cpp gap), restores active backend to `ollama`, and
  never touches LuLu/`pf`. Wired into `tests/integration/run.sh`. Operator
  docs cover optional install, duplicate disk cost, HF/LM Studio privacy,
  ADR 0011 ports, `backend` / `benchmark-backends` commands, and vision split
  (`docs/installation.md`, `docs/operations.md`, `docs/privacy.md`).
- **P10-T08 done:** Quiet-host campaign on Apple M5 / 24 GiB
  (`--runs 2`, think/tools off, serialized backends). Matrix: `ollama` ×
  qwen-4b/qwen-9b/gemma-12b (text + gemma vision); `mlx_lm` × qwen-4b/qwen-9b;
  `mlx_vlm` × gemma-12b (text + vision). `lm_studio` / `llama_cpp` skipped
  (absent). Zero request failures. ADR `0013` keeps shipped default `ollama`
  (MLX text ≈1.1–1.2× decode, not enough to break client contracts); recommend
  `mlx_lm` / `mlx_vlm` as opt-in. Active backend restored to `ollama`. No custom
  gateway.
- **P10 complete:** T01–T08 done; DoD satisfied; no custom gateway/supervisor.
- **No LuLu / macOS `pf` changes in P10.** Offline boundary re-tests are not
  required for this phase; MVP P6-T03 / decision 0010 proofs remain authoritative.
- Do not revive rejected Ollama `*-mlx` tags.

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
to force a pass. **P10 must not modify those rules.**

## Verified state at handoff

- Ollama 0.32.1 on `127.0.0.1:11434` (managed LaunchAgent, cloud disabled)
- Open WebUI 0.10.2 on `http://127.0.0.1:3000` with durable volume
  `agent-lab-open-webui-data`
- Active profile: `online-manual`
- Qualified models: `qwen3.5:4b`, `qwen3.5:9b`, `gemma4:12b`
- Host tools added for P8: Homebrew Node.js 26.5.0 / npm 11.17.0; Promptfoo
  installed under `evals/node_modules` (gitignored)
- Design authority for multi-backend entry: decision `0011`
- Machine-readable backend catalog: `config/backends.json` (schema_version 1)
- Per-backend model pins: decision `0012`; MLX revisions in `config/models.json`
- Backend lifecycle: `agent-lab backend …` (P10-T04)
- Active client wiring: `agent-lab apply-inference` / `backend use` (P10-T05);
  default active backend `ollama`
- Multi-backend benchmark: `agent-lab benchmark-backends` (P10-T06); full M5
  campaign + ADR `0013` recorded (P10-T08); default remains `ollama`
- Backend regression: `tests/integration/test-backends.sh` (P10-T07); operator
  docs in installation / operations / privacy
- P10 DoD: multi-entry backends, pins, lifecycle, client wiring, harness,
  docs/tests, and ADR `0013` recommendations — complete; no custom gateway

## Host-only changes

- Prior: Ollama, LLM CLI, Aider, models, Open WebUI volume, LuLu Block rules
- P8: Homebrew `node` 26.5.0; Promptfoo local install via `evals/npm ci`
- LuLu Docker/Ollama outbound Block rules still active
- **P10-T01:** none (documentation only; no LuLu/`pf` or process changes)
- **P10-T02:** none (config + validators only; no LuLu/`pf` or process changes)
- **P10-T03:** HF/MLX weights cached under `~/.cache/huggingface` for the three
  pinned repos; disposable MLX smoke venv at `.agent-lab/venvs/mlx` (gitignored).
  No LuLu/`pf` changes. Transient `mlx_lm.server` / `mlx_vlm.server` on
  `:11435`/`:11436` started and torn down during smoke.
- **P10-T04:** runtime state under `~/.agent-lab/{run,logs,state}` for managed
  mlx PID files / active-backend marker; no LuLu/`pf` changes. Smoke may
  briefly start/stop `mlx_lm` on `:11435`.
- **P10-T05:** writes `~/.agent-lab/state/inference.env` and
  `.agent-lab/{llm,aider}/` runtime overlays; Open WebUI provider API updates
  when healthy. Smoke: `backend use mlx_lm` + curl `/v1/chat/completions` on
  `:11435` without Ollama on that path; restore `backend use ollama`. No
  LuLu/`pf` changes.
- **P10-T06:** ignored results under `.agent-lab/results/benchmark-backends-*`
  (JSON + markdown); optional short `--smoke` against running Ollama. No
  LuLu/`pf` changes; no full T08 campaign.
- **P10-T07:** none beyond transient `backend use ollama` during integration
  smoke; no LuLu/`pf` changes; no new weight downloads.
- **P10-T08:** quiet-host inference during
  `.agent-lab/results/benchmark-backends-20260720T145905Z.*` (gitignored);
  transient `mlx_lm` / `mlx_vlm` servers on `:11435`/`:11436`; active backend
  restored to `ollama`. No LuLu/`pf` changes; no new weight downloads.

Secrets, model weights, caches, chats, vectors, logs, results, `.env`,
`evals/node_modules/`, and `.cursor/` remain ignored and must not be committed.
