# 0013 — Multi-backend benchmark results and default recommendation

- **Status:** Accepted
- **Recorded:** 2026-07-20
- **Host:** Apple M5 MacBook Air, 24 GiB unified memory, macOS 26.5.2, arm64
- **Branch:** `cursor-impl`
- **Tested commit:** `9cc1e33426cb9aa98843c14acb82597e363f12af`
- **Depends on:** decision 0011 (backends); decision 0012 (pins); harness P10-T06
- **Scope:** P10-T08 quiet-host comparative campaign and shipped-default decision.
  No custom gateway. No LuLu / `pf` changes.

## Decision

Keep the shipped Agent Lab default inference backend as **`ollama`**
(`config/backends.json` `default_backend`, `AGENT_LAB_INFERENCE_BACKEND`).

| Role | Recommended backend | Rationale |
| --- | --- | --- |
| Default text / coding day-to-day | `ollama` | Client contracts (Open WebUI native path, `llm-ollama`, tools/RAG) already work; MLX text wins are modest (~1.1–1.2× decode), not enough to justify breaking the MVP client path |
| Optional faster text (operator opt-in) | `mlx_lm` | Highest decode tok/s on `qwen-4b` / `qwen-9b` in this campaign |
| Default vision day-to-day | `ollama` (`gemma-12b`) | Higher vision decode tok/s than `mlx_vlm` here; WebUI vision already qualified on Ollama |
| Optional MLX vision / multimodal | `mlx_vlm` | Competitive text on Gemma; vision completes correctly; use via `backend use mlx_vlm` or vision-split docs |

Do **not** change `default_backend` from `ollama` on this evidence. Operators who want
MLX throughput may `agent-lab backend use mlx_lm` (text) or `mlx_vlm` (vision)
without a custom multiplexed gateway.

## Campaign method

| Item | Value |
| --- | --- |
| Command | `bin/agent-lab benchmark-backends --backends ollama,mlx_lm,mlx_vlm --aliases qwen-4b,qwen-9b,gemma-12b --runs 2` |
| Runs | **2** timed samples per cell after warm-up (default harness is 3; 2 documented for wall-clock on this host) |
| Thinking / tools | Off (`think:false` on Ollama; `enable_thinking:false` on `mlx_lm` server) |
| Serialization | One heavy backend at a time; MLX servers restarted per alias; Ollama models unloaded between cells |
| Quiet host | Campaign window ~3.7 minutes wall clock; min system memory free **48%**; peak measured MLX RSS ≈ **6.3 GiB** |
| Schema | `schema_version` 1 validated on the result JSON |

### Gaps (skipped)

| Backend | Status |
| --- | --- |
| `lm_studio` | Not installed (`/Applications/LM Studio.app` missing); detect-only; skipped |
| `llama_cpp` | Homebrew `llama-server` / GGUF absent; skipped |

### Raw artifacts (gitignored)

| Artifact | Path |
| --- | --- |
| Result JSON | `.agent-lab/results/benchmark-backends-20260720T145905Z.json` |
| Markdown summary | `.agent-lab/results/benchmark-backends-20260720T145905Z.md` |
| Console log | `.agent-lab/results/benchmark-backends-20260720T145905Z.log` |
| Dry-run schema stub | `.agent-lab/results/benchmark-backends-20260720T145851Z.json` |

Run window: `2026-07-20T14:59:05Z` → `2026-07-20T15:02:49Z`. Requests **36**,
failures **0**.

## Digests and revisions (pins under test)

Unchanged from decision 0012 / `config/models.json`:

| Alias | Backend | Artifact | Digest / revision |
| --- | --- | --- | --- |
| `qwen-4b` | `ollama` | `qwen3.5:4b` | `sha256:2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd` |
| `qwen-9b` | `ollama` | `qwen3.5:9b` | `sha256:6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7` |
| `gemma-12b` | `ollama` | `gemma4:12b` | `sha256:4eb23ef187e2c5462566d6a1d3bbbc2f1346d0b4327cbb66d58fffbcc9b2b05c` |
| `qwen-4b` | `mlx_lm` | `mlx-community/Qwen3.5-4B-MLX-4bit` | `32f3e8ecf65426fc3306969496342d504bfa13f3` |
| `qwen-9b` | `mlx_lm` | `mlx-community/Qwen3.5-9B-MLX-4bit` | `938d8919941c6e7efd3c7150eff7fe9d12afa631` |
| `gemma-12b` | `mlx_vlm` | `mlx-community/gemma-4-12B-it-4bit` | `73bcf09092aa277861d5a191b989b666f7f32e8f` |

### Toolchain at campaign time

| Component | Version |
| --- | --- |
| Ollama | `0.32.1` |
| MLX venv | `.agent-lab/venvs/mlx` |
| `mlx-lm` | `0.31.3` |
| `mlx-vlm` | `0.6.6` |

## Key metrics (median of timed samples)

Cold TTFT is first successful load/warm request; decode / prompt tok/s and total
latency are medians over `--runs 2`. Peak RSS is harness-reported process RSS
(see caveats).

| Backend | Alias | Case | Cold TTFT ms | Decode tok/s | Prompt tok/s | Total ms | Fail rate | Peak RSS MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `mlx_lm` | `qwen-4b` | text | 1101 | **41.6** | 6.7 | 5243 | 0 | 2763 |
| `ollama` | `qwen-4b` | text | 319 | 34.3 | 5.4 | 6415 | 0 | ~75† |
| `mlx_lm` | `qwen-9b` | text | 1323 | **22.7** | 3.7 | 9469 | 0 | 5314 |
| `ollama` | `qwen-9b` | text | 348 | 20.7 | 2.8 | 12395 | 0 | ~75† |
| `mlx_vlm` | `gemma-12b` | text | 370 | **15.9** | 2.7 | 13643 | 0 | 6311 |
| `ollama` | `gemma-12b` | text | 539 | 14.8 | 2.2 | 16702 | 0 | ~84† |
| `mlx_vlm` | `gemma-12b` | vision | 2507 | 11.1 | 116.1‡ | 2516‡ | 0 | 6237 |
| `ollama` | `gemma-12b` | vision | (null)§ | **14.7** | (null)§ | 17456‡ | 0 | ~87† |

**Relative decode (MLX ÷ Ollama):** `qwen-4b` text **1.21×**; `qwen-9b` text
**1.10×**; `gemma-12b` text **1.08×**; `gemma-12b` vision **0.76×** (Ollama
faster on decode).

### Caveats

- † Ollama process RSS in this harness undercounts GPU-resident weights (runner /
  Metal footprint not fully reflected). Treat MLX RSS as the more trustworthy
  process footprint; rely on `min_system_memory_free_percent` (48) for host
  pressure. Prior Ollama-only benchmarks (decision 0010) measured peak Ollama
  resident ≈ 7.5 GiB for `gemma4:12b`.
- ‡ Vision total latency is not directly comparable across backends: `mlx_vlm`
  answered briefly (~28 completion tokens); Ollama hit `max_tokens=256`. Prefer
  decode tok/s for vision throughput.
- § Ollama vision OpenAI stream path did not yield a reliable TTFT in this run
  (`ttft_ms` null) but requests succeeded with token counts.
- Backend switch timings in the raw JSON double-count cells after a backend
  change (harness quirk); not used for the default recommendation.
- LaunchAgent Ollama remained installed/running while MLX servers ran (single-
  heavy-server warning). No Ollama model was left loaded between cells; free
  memory stayed ≥ 48%.

## Failures

None in the measured matrix (`failures_total=0`). `lm_studio` and `llama_cpp`
were absent and skipped as gaps (decision 0012).

## Why the default stays `ollama`

1. **Evidence bar:** Decision 0011 / P10-T08 require a clear win *and* no break
   of tools/RAG client contracts. Decode gains of ~8–21% on text do not clear
   that bar for a shipped default flip.
2. **Client contracts:** Default `ollama` preserves Open WebUI’s Ollama-native
   connection, `llm-ollama`, and the MVP-qualified RAG/tools path. Non-Ollama
   backends already work via `backend use` + OpenAI `/v1` when operators opt in.
3. **Vision:** Ollama won decode tok/s on the Gemma vision cell; MLX vision is
   usable but not a throughput winner here.
4. **Ops cost:** MLX needs the managed venv and duplicate HF weights; keeping
   Ollama as default minimizes first-run friction.

## Consequences

- `config/backends.json` `default_backend` remains `ollama`.
- Active backend restored to `ollama` after the campaign.
- P10 definition of done is met: multi-backend results + this ADR exist; no
  custom gateway was introduced.
- Future campaigns may revisit the default if MLX (or another backend) shows a
  clear multi-metric win *and* Open WebUI / LLM CLI / Aider contracts are
  re-qualified on that backend as the day-to-day entry.
