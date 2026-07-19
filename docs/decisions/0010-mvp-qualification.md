# 0010 — MVP acceptance matrix and qualification

- **Status:** Accepted
- **Qualified:** 2026-07-19
- **Host:** Apple M5 MacBook Air, 24 GiB unified memory, macOS 26.5.2
- **Branch:** `cursor-impl`
- **Release candidate:** `v0.1.0-rc.1`
- **Tested commit:** `cb61eda11f457d06f822fcab15a373a01c6d96e1`
- **Frozen manifests:** `config/components.json`, `config/models.json`
- **Raw results:** ignored `.agent-lab/results/`

## Decision

Qualify the Agent Lab MVP integration stack for local use on the target
24 GB Apple Silicon host with these defaults:

| Role | Alias | Tag | Manifest digest |
| --- | --- | --- | --- |
| Default chat | `qwen-9b` | `qwen3.5:9b` | `sha256:6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7` |
| Fast | `qwen-4b` | `qwen3.5:4b` | `sha256:2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd` |
| Coding / vision | `gemma-12b` | `gemma4:12b` | `sha256:4eb23ef187e2c5462566d6a1d3bbbc2f1346d0b4327cbb66d58fffbcc9b2b05c` |

Keep `OLLAMA_MAX_LOADED_MODELS=1` and recommend `OLLAMA_KEEP_ALIVE=5m` (Ollama
default duration semantics) for production. Native benchmark sampling on this
host showed no critical memory pressure (`min_system_memory_free_percent=26`,
peak Ollama resident ≈ 7.5 GiB for `gemma4:12b`).

Conditional acceptance originally waived live DuckDuckGo while LuLu Block rules
remained active from P6-T03. On 2026-07-19 those Block rules were temporarily
relaxed, `tests/integration/test-search.sh` was re-run successfully (both cases
PASS), and the Docker/Ollama Block rules were restored afterward. Search
provider qualification remains accepted under decision 0009; this matrix now
also has a same-day live egress re-check.

## Exact component versions and digests

| Component | Version | Digest / pin |
| --- | --- | --- |
| Ollama | `0.32.1` | executable SHA-256 `8ac71f1dbc4ef2efb9f15257f016aca199e72a89b278c6af64b1d693dd442b15` |
| Open WebUI | `0.10.2` | OCI index `sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4`; linux/arm64 `sha256:0d58a66704d69e52da83f72bcd43869ad4fd0c761313778bc95ef6940a0b81e3` |
| Promptfoo | `0.121.19` | pinned in `evals/package.json` + `evals/package-lock.json` |
| Node.js / npm | `v26.5.0` / `11.17.0` | Homebrew `node` (host tool for evals) |
| LLM CLI | `0.31.1` | with `llm-ollama` `0.16.1` |
| Aider | `0.86.2` | uv-managed Python 3.12.13 tool env |
| Active profile at close | `online-manual` | restored after offline suites |

Embedding cache remains the pinned Open WebUI snapshot recorded in
`config/models.json` (`sentence-transformers/all-MiniLM-L6-v2` revision
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41`).

## Prerequisites used

- Existing durable Docker volume `agent-lab-open-webui-data` (not a wiped fresh
  volume). Fresh-volume bootstrap was already qualified in P3/P7; wiping the
  operator volume for this matrix was impractical and would destroy local
  chats/RAG state.
- Managed Ollama LaunchAgent on `127.0.0.1:11434` with `OLLAMA_NO_CLOUD=1` and
  `OLLAMA_MAX_LOADED_MODELS=1`.
- LuLu 4.3.2 Block rules for Docker Desktop components and the Homebrew Ollama
  binary still active after P6-T03 (loopback preserved via `allowLocalHost=true`).

## Acceptance matrix

| Suite | Command | Result | Raw artifact |
| --- | --- | --- | --- |
| Static | `make test-static` | **PASS** (ShellCheck SKIP — not installed) | `.agent-lab/results/test-static.log` |
| Smoke | `make test-smoke` / individual smoke scripts | **PASS** (doctor, LLM CLI, Aider, Open WebUI) | `.agent-lab/results/test-smoke.log` |
| Integration | `make test-integration` | **PASS** | `.agent-lab/results/test-integration.log` |
| Isolated model lifecycle | `tests/integration/test-model-lifecycle.sh` | **SKIP** during matrix (port `11434` occupied by managed Ollama); prior **PASS** retained | `.agent-lab/results/model-lifecycle.json` |
| RAG | `tests/integration/test-rag.sh` (via integration runner) | **PASS** | `.agent-lab/results/rag-latest.jsonl` |
| Backup / restore | `tests/integration/test-backup-restore.sh` | **PASS** | `.agent-lab/results/test-integration.log` |
| Diagnostics | `tests/integration/test-diagnostics.sh` | **PASS** | `.agent-lab/results/test-integration.log` |
| Promptfoo fast | `cd evals && npm run eval:fast` | **PASS** 28/28 | `.agent-lab/results/promptfoo-fast.json` |
| Promptfoo assertion self-test | `cd evals && npm run eval:selftest` | **PASS** (assertions fail as required) | `.agent-lab/results/promptfoo-assertion-selftest.json` |
| Hardware benchmark | `bin/agent-lab benchmark --runs 1 --concurrency` | **PASS**; keep-alive `5m`; no critical pressure | `.agent-lab/results/benchmark-latest.json` |
| Offline config | `make test-offline` | **PASS** (`boundary=configuration_only`) | `.agent-lab/results/test-offline.log`, `offline-latest.json` |
| Offline LuLu boundary | `bin/agent-lab offline verify --boundary-confirmed --full` | **PASS** (earlier same-day P6-T03) | `.agent-lab/results/offline-boundary-full.log` |
| Online search | `tests/integration/test-search.sh` | **PASS** (re-run 2026-07-19 after temporary LuLu Allow; Block rules restored) | `.agent-lab/results/test-search.log`, `search-latest.jsonl` |

Online search was run separately from offline proof so the offline result remains
unambiguous.

## Benchmark summary (hardware)

From `.agent-lab/results/benchmark-latest.json`:

- Recommendations: default chat `qwen-9b`, keep-alive `5m`
- `critical_memory_pressure`: false
- `min_system_memory_free_percent`: 26
- `peak_ollama_resident_bytes`: ≈ 7.49 GiB
- Per-model timed samples (1 run after warm-up; concurrency case also PASS with
  `loaded_model_count=1`)

Dry-run schema validation, digest-matched comparison, and mismatched-digest
rejection were exercised earlier the same day
(`.agent-lab/results/benchmark-dry*.json`, `benchmark-consist-*.json`,
`benchmark-bad-digest.json`).

## Promptfoo summary

Pinned Promptfoo talks only to `OLLAMA_BASE_URL=http://127.0.0.1:11434`.
`sharing: false`. No hosted grading provider is configured. Cases cover chat,
instruction following, refusal, structured JSON, code repair, tools, vision
(`gemma-12b` only), RAG/citation grounding via injected fixtures, and
search-grounded answers without live egress. Live DuckDuckGo remains owned by
`tests/integration/test-search.sh`.

## Waivers and follow-ups

| Item | Impact | Owner / follow-up |
| --- | --- | --- |
| Live DuckDuckGo search | Re-qualified PASS after temporary LuLu Allow; Docker/Ollama Block rules restored | None — keep Block rules for offline egress posture; relax only when intentionally testing online search |
| ShellCheck not installed | Static suite skips ShellCheck | Install ShellCheck before contributor release checks |
| Isolated `test-model-lifecycle.sh` skipped while managed Ollama held `:11434` | Matrix did not re-prove isolated server drill | Stop LaunchAgent, free the port, re-run; prior P2-T03 result remains authoritative |
| Fresh Open WebUI volume not wiped | Matrix used the existing durable volume | Acceptable for operator qualification; clean-volume path already covered in P3/P7 |
| Promptfoo TTFT/latency on small local models can be multi-second for longer prompts | UX expectation only; not a release blocker | P9 docs should set expectations |

## Release blockers reviewed

No crash, data-loss, remote-inference, or unreproducible-artifact blockers were
observed in the mandatory local suites. Unapproved outbound traffic during the
LuLu-confirmed offline boundary run was previously verified absent
(`user_controlled_egress_block_verified`). The live search failure is attributed
to the intentional host egress Block, not to remote inference falling through.

## P9 documentation operator walkthrough

Recorded 2026-07-19 on branch `cursor-impl` (commit `cbda8ef` at start of the
run) as the clean-room equivalent for **P9-T01** and **P9-T02**: followed
`docs/installation.md`, `docs/operations.md`, `docs/privacy.md`, and
`docs/recovery.md` from the repository root without undocumented global Agent
Lab configuration. Raw log:
`.agent-lab/results/p9-operator-walkthrough.log`.

| Check | Command / method | Result |
| --- | --- | --- |
| Relative links + secret/path static review | `make test-static` | **PASS** (ShellCheck SKIP) |
| Prerequisites (doctor) | `bin/agent-lab doctor` | **PASS** (9/3/0; optional llm/aider/promptfoo WARN) |
| Health | `bin/agent-lab health` | **PASS** (`healthy=true`) |
| First local chat | `tests/smoke/test-webui.sh` (browser/API path in installation) | **PASS** |
| Offline mode proof | `bin/agent-lab offline verify --config-only --quick` | **PASS** (`configuration_only`; profile restored to `online-manual`) |
| Backup | `bin/agent-lab backup --destination /tmp/agent-lab-p9-walkthrough` | **PASS** (archive + `.sha256` sidecar) |
| Restore drill | `bin/agent-lab restore` into disposable volume `agent-lab-p9-walkthrough-restore` + empty config dir | **PASS**; disposable volume removed afterward |
| Post-walkthrough health | `bin/agent-lab health` | **PASS**; profile `online-manual` |

Secret/path review of the P9 docs themselves found no embedded credentials or
personal home-directory paths (only documented references to ignored `.env`).

## Manifest freeze and release candidate

P9-T03 freezes the MVP catalogs and tags release candidate `v0.1.0-rc.1`.

| Item | Value |
| --- | --- |
| Release candidate tag | `v0.1.0-rc.1` |
| Tested commit | `cb61eda11f457d06f822fcab15a373a01c6d96e1` |
| Component catalog | `config/components.json` (`mvp_freeze.status=frozen`) |
| Model catalog | `config/models.json` (`mvp_freeze.status=frozen`) |
| Ollama | `0.32.1` / executable SHA-256 `8ac71f1dbc4ef2efb9f15257f016aca199e72a89b278c6af64b1d693dd442b15` |
| Open WebUI | `0.10.2` / OCI index `sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4` |
| Embedding snapshot | `sentence-transformers/all-MiniLM-L6-v2` revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41` |
| Companion pins | LLM CLI / Aider requirements files; Promptfoo lockfile under `evals/` |

Freeze gate checks for this release candidate (re-run 2026-07-19 on the
qualified host):

| Check | Result |
| --- | --- |
| Config validation (`make validate`) | **PASS** |
| Full fast suite (`make test-static`; Promptfoo `npm run eval:fast`) | **PASS** (ShellCheck SKIP; Promptfoo 28/28) |
| Catalog verification (`agent-lab models verify`) | **PASS** (qwen-4b, qwen-9b, gemma-12b) |
| Tracked-file secret scan / ignored-data check | **PASS** (via `make test-static`) |
| Manifest-to-live-host drift (`agent-lab health`, embedding cache, OCI digest) | **PASS** (`healthy=true`; image digest verified) |

### License review (frozen pins)

| Artifact | License recorded |
| --- | --- |
| Ollama `0.32.1` | MIT |
| Open WebUI `0.10.2` | Open WebUI License with prior MIT and BSD-3-Clause contributions |
| `qwen3.5:4b` / `qwen3.5:9b` | Apache-2.0 |
| `gemma4:12b` | Apache-2.0 |
| Embedding `all-MiniLM-L6-v2` | Apache-2.0 |
| LLM CLI / llm-ollama / Aider / Promptfoo | Apache-2.0 / Apache-2.0 / Apache-2.0 / MIT (companion pins) |

No secrets, model weights, caches, chat data, vector data, logs, or benchmark
scratch data are tracked. Mutable runtime paths remain gitignored.

`tested_commit` is the freeze content commit whose tree passed the gate checks.
Annotated tag `v0.1.0-rc.1` points at the follow-up commit that records that
SHA in the catalogs and this decision. A clean checkout of `v0.1.0-rc.1` plus
the documented external downloads in `docs/installation.md` reproduces the
qualified MVP. Mutable runtime artifacts (`.env`, model weights, Open WebUI
volume data, logs, `.agent-lab/results/`, `evals/node_modules/`) remain outside
Git.

## Consequences

- Manifests are frozen for `v0.1.0-rc.1`. Change pins only with a new
  qualification decision and a new release candidate.
- Keep LuLu Block rules documented: they prove offline egress control but block
  Docker-originated online search until relaxed.
- Do not change keep-alive or default aliases without a new benchmark sample on
  the target hardware class.
