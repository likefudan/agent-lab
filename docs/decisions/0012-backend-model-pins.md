# 0012 — Per-backend artifact pins for role aliases

- **Status:** Accepted
- **Recorded:** 2026-07-20
- **Host class:** Apple M5 / 24 GiB unified memory
- **Branch:** `cursor-impl`
- **Depends on:** decision 0011 (backends); decision 0003 (Ollama role aliases)
- **Scope:** P10-T03 qualification and pins only. Lifecycle helpers remain
  P10-T04. Do not revive rejected Ollama `*-mlx` tags (decision 0003).

## Context

Decision 0011 established five first-class backends. Role aliases `qwen-4b`,
`qwen-9b`, and `gemma-12b` already have executable Ollama pins from the MVP
freeze. Post-MVP comparative work needs at least one MLX path per alias where
modality allows, with immutable Hugging Face revisions—not floating tags and
not invented digests.

## Decision

Pin the following MLX artifacts as **executable** after local smoke tests on
this host. Leave `llama_cpp` and `lm_studio` as **candidate** with explicit
gaps (no verified GGUF digest or LM Studio id on this host). Mark cross-role
MLX slots that are not the intended modality path as **unsupported**.

### Toolchain used for MLX smokes

| Component | Version / note |
| --- | --- |
| Python venv | `.agent-lab/venvs/mlx` (Homebrew Python 3.14.6; gitignored) |
| `mlx-lm` | `0.31.3` |
| `mlx-vlm` | `0.6.6` (git main at pin time; PyPI lagged at `0.3.3` without `gemma4_unified`) |
| Weight cache | `~/.cache/huggingface` (not committed) |

### Executable MLX pins

| Alias | Backend | HF repo (`artifact_id`) | Immutable revision | Quant | Approx size | Smoke |
| --- | --- | --- | --- | ---: | ---: | --- |
| `qwen-4b` | `mlx_lm` | `mlx-community/Qwen3.5-4B-MLX-4bit` | `32f3e8ecf65426fc3306969496342d504bfa13f3` | 4-bit affine | ~2.85 GiB | Text `AGENT-LAB-OK` via `mlx_lm.generate` and `mlx_lm.server` on `127.0.0.1:11435` (`enable_thinking=false`) |
| `qwen-9b` | `mlx_lm` | `mlx-community/Qwen3.5-9B-MLX-4bit` | `938d8919941c6e7efd3c7150eff7fe9d12afa631` | 4-bit affine | ~5.57 GiB | Text `AGENT-LAB-OK` via `mlx_lm.generate` (`enable_thinking=false`); peak mem ≈ 5.2 GiB. OpenAI server path not re-probed for 9B after 4B server proof |
| `gemma-12b` | `mlx_vlm` | `mlx-community/gemma-4-12B-it-4bit` | `73bcf09092aa277861d5a191b989b666f7f32e8f` | 4-bit affine | ~6.31 GiB | Text `AGENT-LAB-OK` and vision (blue triangle + `AGENT 42`) via `mlx_vlm.generate` and `mlx_vlm.server` on `127.0.0.1:11436` using the qualification PNG |

Revision re-read: `HfApi.model_info(...).sha` matched each pinned revision; local
`snapshot_download(..., local_files_only=True)` resolved under
`~/.cache/huggingface/hub/models--…/snapshots/<revision>`.

### Ollama pins (unchanged)

| Alias | Backend | Artifact | Digest |
| --- | --- | --- | --- |
| `qwen-4b` | `ollama` | `qwen3.5:4b` | `sha256:2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd` |
| `qwen-9b` | `ollama` | `qwen3.5:9b` | `sha256:6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7` |
| `gemma-12b` | `ollama` | `gemma4:12b` | `sha256:4eb23ef187e2c5462566d6a1d3bbbc2f1346d0b4327cbb66d58fffbcc9b2b05c` |

### Unsupported MLX cross-slots

| Alias | Backend | Status | Reason |
| --- | --- | --- | --- |
| `qwen-4b` / `qwen-9b` | `mlx_vlm` | `unsupported` | Text/coding role uses `mlx_lm`. Qwen3.5 MLX weights are multimodal-capable, but Agent Lab does not advertise vision for these aliases (decision 0003). |
| `gemma-12b` | `mlx_lm` | `unsupported` | Vision/multimodal primary is `mlx_vlm` with `gemma4_unified`. Text-only `mlx_lm` Gemma4 loaders strip vision towers and are not this pin. |

### Explicit gaps (`candidate`)

| Alias | Backend | Gap |
| --- | --- | --- |
| all three | `lm_studio` | LM Studio app absent on this host (`/Applications/LM Studio.app` missing). No LM Studio model id verified. |
| all three | `llama_cpp` | Homebrew `llama.cpp` not installed; no local GGUF file verified. Digests not invented. |

## Smoke evidence summary

| Probe | Result |
| --- | --- |
| `qwen-4b` `mlx_lm.generate` text (thinking off) | pass → `AGENT-LAB-OK`; peak ≈ 2.52 GiB |
| `qwen-4b` `mlx_lm.server` `/v1/chat/completions` | pass → `AGENT-LAB-OK`; server torn down |
| `qwen-9b` `mlx_lm.generate` text (thinking off) | pass → `AGENT-LAB-OK`; peak ≈ 5.20 GiB |
| `gemma-12b` `mlx_vlm.generate` text | pass → `AGENT-LAB-OK`; peak ≈ 6.87 GiB |
| `gemma-12b` `mlx_vlm.generate` vision | pass → blue triangle + `AGENT 42`; peak ≈ 7.36 GiB |
| `gemma-12b` `mlx_vlm.server` text + vision | pass (must request the pinned snapshot path as `model`; `/v1/models` also lists unrelated cached HF repos) |
| `lm_studio` / `llama_cpp` install + smoke | not attempted beyond detection; remain `candidate` |

Thinking and tools were disabled for fair text comparison where the stack
exposes a switch (`chat-template-config` / `chat-template-args`
`{"enable_thinking":false}`). No tool-calling smoke was required for P10-T03
MLX pins.

## Consequences

- `config/models.json` records executable MLX revisions for the three aliases.
- Operators need `mlx-lm` ≥ 0.31 and `mlx-vlm` ≥ 0.6.6 (with `gemma4_unified`)
  for these pins; P10-T04 should document the managed venv path.
- Duplicate disk cost across Ollama blobs and HF/MLX caches is expected
  (~15 GiB additional for the three MLX pins).
- P10-T06 benchmarks must refuse compare across mismatched revisions.
- Filling `llama_cpp` / `lm_studio` slots requires obtaining and smoke-testing
  artifacts on-host; do not promote candidates without evidence.
