# 0011 — Pluggable OpenAI-compatible inference backends

- **Status:** Accepted
- **Recorded:** 2026-07-20
- **Host class:** Apple M5 / 24 GiB unified memory (same as MVP qualification)
- **Branch:** `cursor-impl`
- **Depends on:** MVP freeze `v0.1.0-rc.1` (decision 0010); Ollama baseline
  (decision 0002)
- **Scope:** Design and decision gate only (P10-T01). No executable config,
  lifecycle scripts, or model pins in this record.

## Context

MVP phases P0–P9 and release candidate `v0.1.0-rc.1` used native Ollama as the
sole inference entry. That freeze remains historically correct: Open WebUI, LLM
CLI, Aider, Promptfoo, and offline profiles all talked to loopback Ollama on
`127.0.0.1:11434`.

Post-MVP work needs to compare and optionally prefer other local servers on the
same Apple Silicon host—especially MLX text and vision servers, LM Studio, and
llama.cpp—without abandoning the integration-only boundary. Operators must be
able to choose one active day-to-day entry while still forbidding a custom
gateway that pretends to be a single multiplexed Ollama.

## Decision

After P10, **Ollama is not the sole inference entry.** Agent Lab treats the
following as first-class loopback backends:

| Backend id | Server | Typical role |
| --- | --- | --- |
| `ollama` | Native Ollama | Text, coding, tools, and vision via qualified Ollama artifacts (MVP path) |
| `mlx_lm` | `mlx_lm.server` (Apple MLX) | Text / coding via MLX weights |
| `mlx_vlm` | MLX-VLM OpenAI-compatible server | Vision / multimodal via MLX weights |
| `lm_studio` | LM Studio local server | Optional detect-or-manage peer with OpenAI-compatible `/v1` |
| `llama_cpp` | llama.cpp server | GGUF / Metal benchmark and fallback path |

### Active entry

Day-to-day clients use the **active backend**:

- `AGENT_LAB_INFERENCE_BACKEND` names one of the ids above.
- An OpenAI-compatible base URL (for example
  `http://127.0.0.1:11435/v1`) is the common client contract for Open WebUI
  (OpenAI connection), LLM CLI, and Aider.
- Prefer OpenAI `/v1` across backends. The Ollama-native API remains allowed
  **only** when the active backend is `ollama`.
- Initial shipped default remains `ollama` until a later comparative campaign
  (P10-T08 / decision 0013) may change it. Default preference is not monopoly.

### Forbidden pattern

Do **not** introduce a custom gateway, proxy, or supervisor that silently
multiplexes backends behind one fake Ollama endpoint. Clients select the active
server explicitly. Lifecycle helpers may start/stop/detect backends; they must
not invent a second API surface.

### Rejected Ollama `*-mlx` tags

Do not revive the rejected Ollama tags `qwen3.5:4b-mlx`, `qwen3.5:9b-mlx`, or
`gemma4:12b-mlx` (decision 0003). MLX paths use Hugging Face / MLX-community
weights through `mlx_lm` / `mlx_vlm`, not Ollama `-mlx` artifacts.

## Backend matrix

| Backend | Weight source | Text | Vision | Tools (contract) | Managed vs optional | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `ollama` | Ollama library blobs / GGUF-style store | Yes | Yes (`gemma-12b`) | Yes where model qualified | Managed (LaunchAgent) | Historical MVP entry; native API optional when active |
| `mlx_lm` | Hugging Face / MLX cache | Yes | No (text server) | Model-dependent; verify in P10-T03 | Managed (venv / launch) | Pair with `mlx_vlm` for vision split if needed |
| `mlx_vlm` | Hugging Face / MLX cache | Limited / multimodal | Yes | Model-dependent; verify in P10-T03 | Managed (venv / launch) | Vision and multimodal primary MLX path |
| `lm_studio` | LM Studio model library | Yes | Model-dependent | Model-dependent | Detect-first; manage only if a safe documented start exists | Default app port may differ; document detection |
| `llama_cpp` | GGUF files | Yes | Model-dependent | Model-dependent | Managed where Agent Lab owns the process | Separate artifact lifecycle from Ollama store |

Role aliases remain `qwen-4b`, `qwen-9b`, and `gemma-12b`. Each alias maps to
**per-backend** artifact ids (digest, Hugging Face revision, or LM Studio id)
in later tasks. Placeholders may stay `candidate` until P10-T03 pins them.
Capability advertising stays evidence-based: do not enable vision or tools for a
backend×alias pair that failed its smoke gate.

Ollama blobs, Hugging Face / MLX caches, llama.cpp GGUF files, and LM Studio
libraries are separate copies. Do not assume shared storage or identical
quantization across backends.

## Suggested loopback ports

Bind every inference server to IPv4 loopback unless a later decision explicitly
authorizes LAN access. Suggested ports (adjust only if a conflict is documented
in status or ops docs):

| Backend | Port | OpenAI-compatible base URL |
| --- | --- | --- |
| `ollama` | `11434` | `http://127.0.0.1:11434/v1` |
| `mlx_lm` | `11435` | `http://127.0.0.1:11435/v1` |
| `mlx_vlm` | `11436` | `http://127.0.0.1:11436/v1` |
| `llama_cpp` | `11437` | `http://127.0.0.1:11437/v1` |
| `lm_studio` | `1234` (LM Studio default) or detected | `http://127.0.0.1:<detected>/v1` |

Health probes are backend-specific (for example Ollama `GET /api/version` when
active; otherwise OpenAI `GET /v1/models` or the server’s documented health
path). A TCP listener alone is never sufficient.

## Offline and pull rules

Offline guarantees from the MVP still apply to whichever backend is active:

- After required packages and weights are present, chat, coding, vision (when
  advertised), RAG, and persistence must work without internet access.
- Offline profiles disable web search, remote tools, automatic downloads, update
  checks, telemetry, and cloud/hosted inference fallthrough.
- Model / weight pulls are prohibited while offline. A missing local artifact
  must fail closed locally.
- Hugging Face Hub, LM Studio registry, and Ollama library access are
  installation- or explicit-update-time only. Force HF offline flags for MLX
  paths when the offline profile is active (implementation in later P10 tasks).
- Duplicate disk cost across backends is expected and must be documented for
  operators; it is not a reason to invent a shared weight manager.

### Network-boundary re-tests (explicit non-requirement)

**P10 does not require LuLu or macOS `pf` offline-boundary re-tests.** The MVP
boundary proof in decision 0010 / P6-T03 remains authoritative for egress
control. P10 must not modify LuLu or `pf` rules. Later backend work may run
configuration-only offline checks; physical firewall re-qualification is out of
scope for this phase unless a separate decision reopens it.

## Single-heavy-server policy (24 GB)

On the target 24 GiB unified-memory host:

- Run **at most one heavy inference server** with a large chat/vision model
  loaded for day-to-day use and for comparative benchmarks.
- Switching backends implies stopping or fully unloading the previous heavy
  server before loading the next.
- Do not keep Ollama, mlx-lm, mlx-vlm, llama.cpp, and LM Studio simultaneously
  resident with large models.
- Optional vision split (below) is the only intentional dual-connection case,
  and even then operators should avoid loading two large models at once on
  24 GB; prefer sequential use or measured keep-alive that stays under pressure
  thresholds established in P8/P10 benchmarks.
- Retain Ollama’s `OLLAMA_MAX_LOADED_MODELS=1` when that backend is active;
  apply analogous one-model discipline on other servers where the software
  exposes it.

## Vision split (optional second Open WebUI connection)

Open WebUI may expose a **second** model connection when text and vision are
served by different backends—for example `mlx_lm` for text/coding and
`mlx_vlm` for vision—without introducing a gateway. LLM CLI and Aider continue
to target the single active OpenAI-compatible base URL unless the operator
explicitly selects another endpoint.

Rules:

- The second connection is optional and documented, not the default MVP-shaped
  path.
- Clients must still know which connection is active for a given request; Agent
  Lab does not silently route image parts to a different process.
- Vision capability remains advertised only for aliases/backends that passed
  image gates (historically `gemma-12b` on Ollama; MLX vision pins in P10-T03).

## Relationship to MVP

| Topic | MVP (`v0.1.0-rc.1`) | Post-MVP (P10+) |
| --- | --- | --- |
| Inference entry | Ollama only | Active backend among the five ids |
| Client contract | Ollama native + `/v1` | Prefer `/v1`; native only for active `ollama` |
| Gateway | Forbidden | Still forbidden |
| Default backend | Ollama | Ollama until decision 0013 may change it |
| Offline LuLu/`pf` proof | Required and recorded | Not re-required for P10 |

## Consequences

- `docs/design.md` must describe multi-entry backends; “Ollama-only” language
  is limited to historical MVP statements.
- P10-T02 adds machine-readable backend/model catalog fields and validators.
- P10-T03 pins per-backend artifacts; P10-T04–T05 implement lifecycle and
  active-backend wiring; P10-T06–T08 measure and recommend.
- No LuLu/`pf` rule changes and no offline boundary re-tests are in P10 scope.
- Custom gateway/supervisor remains a last-resort deferred item, not a P10
  deliverable.
