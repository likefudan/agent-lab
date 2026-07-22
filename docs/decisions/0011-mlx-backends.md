# 0011 — Direct MLX text and multimodal backends

- **Status:** Accepted
- **Qualified:** 2026-07-22
- **Host:** Apple M5 MacBook Air, 24 GB unified memory, macOS 26.5.2

## Decision

Add two native, loopback-only OpenAI-compatible inference services alongside
the retained Ollama fallback:

- MLX-LM `0.31.3` on `127.0.0.1:8081` for Qwen 3.5 9B text chat and coding;
- MLX-VLM `0.6.6` on `127.0.0.1:8082` for Gemma 4 12B multimodal chat.

Install both packages in one isolated Python `3.12.13` environment under the
ignored `.agent-lab/mlx/` runtime directory. Pin the top-level packages and
their upstream source revisions in `config/components.json`.

Use `agent-lab mlx start chat|vision` as a narrow lifecycle switch. Starting
one backend stops the other before loading its model. The switch does not proxy,
route, transform, or generate requests; those remain direct client-to-upstream
server calls. This preserves the project's no-custom-gateway decision while
protecting the 24 GB memory budget.

## Model artifacts

| Alias | Repository | Revision | Bytes | Runtime |
| --- | --- | --- | ---: | --- |
| `qwen-9b-mlx` | `mlx-community/Qwen3.5-9B-MLX-4bit` | `938d8919941c6e7efd3c7150eff7fe9d12afa631` | 5,977,074,591 | MLX-LM |
| `gemma-12b-mlx` | `mlx-community/gemma-4-12B-it-4bit` | `73bcf09092aa277861d5a191b989b666f7f32e8f` | 6,773,372,848 | MLX-VLM |

`config/mlx/models.json` records every expected file's byte count and SHA-256.
The downloader requests the exact 40-hex revision and rejects any resolved
snapshot path that differs. Both launch environments set `HF_HUB_OFFLINE=1`
and load the immutable snapshot directory, preventing inference-time pulls.
Ollama and Hugging Face weights are intentionally separate copies.

## Qualification evidence

MLX-LM loaded the pinned Qwen snapshot on the Apple GPU and returned the exact
deterministic response `MLX-LM-OK` through `/v1/chat/completions`. The same
backend returned `OPEN-WEBUI-MLX-OK` through Open WebUI's provider and friendly
model preset. A required OpenAI-format function request returned
`get_weather` with the parsed argument `{"city":"Paris"}` and finish reason
`tool_calls`. Given a broken Python addition function, Qwen also returned the
corrected implementation containing `return a + b`.

MLX-VLM reported a loaded model context of 262,144 tokens with an Agent Lab
effective KV limit of 32,768. Given the repository-owned image fixture and the
instruction to return only its large code, Gemma returned exactly
`PIXEL-6158`. The measured request processed 282 prompt tokens, produced the
first token in approximately 2.2 seconds, and completed eight output tokens at
approximately 17.6 tokens/second.

The managed switch test verified that starting MLX-VLM stopped MLX-LM before
the Gemma request. Open WebUI's container reached the active host service through
`host.docker.internal`, and both friendly model presets remained registered
while only one native service was active.

## Operational consequences

- Normal output is capped at 16,384 tokens for both MLX servers.
- MLX-VLM's KV context is capped at 32,768 tokens; MLX-LM uses the model's
  native context management and bounded output.
- Switching roles unloads and reloads weights, so a cold request has a load
  penalty. This is preferred to memory pressure or swapping from simultaneous
  Qwen and Gemma residency.
- MLX-LM documents its HTTP server as development-oriented and with basic
  security checks. Agent Lab therefore binds it only to loopback and does not
  expose either MLX port to the LAN.
- Ollama remains available as a stable fallback and for existing LLM CLI/Aider
  integrations until those clients are explicitly pointed at MLX-LM.

## Sources

- [MLX-LM server documentation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md)
- [MLX-LM v0.31.3](https://github.com/ml-explore/mlx-lm/releases/tag/v0.31.3)
- [MLX-VLM](https://github.com/Blaizzy/mlx-vlm)
- [MLX-VLM v0.6.6](https://github.com/Blaizzy/mlx-vlm/releases/tag/v0.6.6)
- [Qwen 3.5 9B MLX snapshot](https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit)
- [Gemma 4 12B MLX snapshot](https://huggingface.co/mlx-community/gemma-4-12B-it-4bit)
