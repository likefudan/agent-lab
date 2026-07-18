# 0003 — Capability-qualified Ollama model selection

- **Status:** Accepted
- **Qualified:** 2026-07-18
- **Runtime:** Ollama `0.32.1` on the target Apple M5 host

## Decision

Approve the standard local artifacts with capability-specific roles:

- `qwen3.5:9b` as `qwen-9b` for text chat, code, and tools;
- `qwen3.5:4b` as `qwen-4b` for fast text chat, lightweight code, and tools;
- `gemma4:12b` as `gemma-12b` for text, code, tools, and vision.

Set the defaults to `qwen-9b` for chat, `qwen-4b` for fast requests, and
`gemma-12b` for coding and vision. The fixed image test is a capability gate,
not a general quality ranking: both Qwen artifacts processed the image and
identified its shape and color but failed exact text recognition, so their
catalog entries explicitly set vision to false. Gemma passed the complete case.

Keep the earlier `qwen3.5:4b-mlx`, `qwen3.5:9b-mlx`, and
`gemma4:12b-mlx` artifacts as rejected, non-executable evidence. All three pass
text, code repair, and function calling through Ollama's MLX GPU runner, but
all ignore image input on the pinned runtime.

## Approved artifact metadata

| Alias | Exact tag | Manifest SHA-256 | Bytes | Parameters | Quantization | Context | Minimum Ollama | Advertised by Agent Lab |
| --- | --- | --- | ---: | ---: | --- | ---: | --- | --- |
| `qwen-4b` | `qwen3.5:4b` | `2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd` | 3,389,983,735 | 4,659,865,088 | `Q4_K_M` | 262,144 | 0.17.1 | text, code, tools |
| `qwen-9b` | `qwen3.5:9b` | `6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7` | 6,594,474,711 | 9,653,104,368 | `Q4_K_M` | 262,144 | 0.17.1 | text, code, tools |
| `gemma-12b` | `gemma4:12b` | `4eb23ef187e2c5462566d6a1d3bbbc2f1346d0b4327cbb66d58fffbcc9b2b05c` | 7,556,508,396 | 11,907,350,576 | `Q4_K_M` | 262,144 | 0.30.5 | text, code, tools, vision |

`config/models.json` records every standard artifact blob digest, size, and
type, including Gemma's separate 175,115,584-byte vision projector. All three
license blobs identify Apache License 2.0. The primary sources are the official
Ollama entries for [Qwen 3.5](https://ollama.com/library/qwen3.5) and
[Gemma 4](https://ollama.com/library/gemma4).

## Rejected MLX artifact metadata

The official Ollama library listed all three exact tags at qualification time.
The Qwen family page advertised vision and tools, and both local Qwen artifacts
reported `completion`, `vision`, `thinking`, and `tools`. The Gemma 4 library
page advertised text and image input plus native function calling, but the
pulled `gemma4:12b-mlx` artifact reported only `completion`, `tools`, and
`thinking`. Its renderer log likewise omitted vision.

| Candidate | Exact tag | Manifest SHA-256 | Bytes | Parameters | Quantization | Context | Minimum Ollama | Local capabilities |
| --- | --- | --- | ---: | ---: | --- | ---: | --- | --- |
| Qwen 4B MLX | `qwen3.5:4b-mlx` | `61aa3858e9d3022e8fca725550089addd9289c4446f33bd09dfd12f95f2a6792` | 3,973,305,013 | 4,538,986,496 | `nvfp4` | 262,144 | 0.19.0 | completion, vision, thinking, tools |
| Qwen 9B MLX | `qwen3.5:9b-mlx` | `203e30078279db51132b9e026ceb7bb21330e5b1af67ef190671b375c9770404` | 8,903,014,758 | 9,409,468,800 | `nvfp4` | 262,144 | 0.19.0 | completion, vision, thinking, tools |
| Gemma 12B MLX | `gemma4:12b-mlx` | `117d0d84cf2ab865feb59afc2cd30ff5d55f0035e05eb8d1b814f9688e3f3671` | 7,651,251,181 | 12,382,568,756 | `nvfp4` | 262,144 | 0.31.0 | completion, thinking, tools |

The full machine-readable catalog records the config, license, and parameter
blob digests plus a deterministic SHA-256 over every sorted layer digest. This
compact blob-set digest commits all
731, 768, and 737 layer digests respectively without duplicating thousands of
tensor records into Git. The OCI manifest digest independently commits their
ordered digests, names, media types, and sizes.

## Qualification cases

Tests used temperature `0`, seed `42`, a 4,096-token runtime context, and the
versioned cases under `evals/fixtures/model-qualification/`. The image is a
self-authored 640×640 PNG containing one blue triangle and the text
`AGENT 42`; it was visually inspected before testing.

| Test | Expected |
| --- | --- |
| Native text | Exact response `AGENT-LAB-OK` |
| OpenAI-compatible code repair | Returned function contains `return a + b` |
| Native tool call | `get_weather` with JSON argument `{"city":"Paris"}` |
| Native image | Identify blue triangle and transcribe `AGENT 42` |

All six artifacts passed text, code repair, and tool calling. The standard Qwen
artifacts processed 440-token image-bearing prompts and correctly identified a
blue triangle, but transcribed `A4E2` and `A123456` rather than `AGENT 42`.
Their executable catalog entries therefore declare only the capabilities they
passed. Standard Gemma processed a 209-token image-bearing prompt and returned
the exact expected shape, color, and code.

The three rejected MLX artifacts instead kept prompt counts at the text-only
scale and hallucinated unrelated shapes and codes. Native chat and generate
routes were cross-checked for Qwen 4B MLX, and the OpenAI-compatible image route
also failed to inject image tokens. Gemma MLX did not report vision in local
metadata at all.

The Qwen reasoning models need a sufficient completion budget on the
OpenAI-compatible API. Qwen 4B consumed a 512-token cap in reasoning and
returned no answer, then passed the same repair with a 1,024-token cap (646
completion tokens). The catalog records 1,024 as the qualification minimum;
client integrations must not assume a small output cap is enough.

## Host measurements

| Tag | Load | Text generation | Resident size | Processor | Approved capabilities |
| --- | ---: | ---: | ---: | --- | --- |
| `qwen3.5:4b` | 2.01 s | 36.64 tok/s | 3.2 GiB | 100% GPU | text, code, tools |
| `qwen3.5:9b` | 2.74 s | 19.40 tok/s | 5.6 GiB | 100% GPU | text, code, tools |
| `gemma4:12b` | 2.08 s | 15.34 tok/s | 8.0 GiB | 100% GPU | text, code, tools, vision |
| `qwen3.5:4b-mlx` | 1.44 s | 19.29 tok/s | 3.4 GiB | 100% GPU | rejected |
| `qwen3.5:9b-mlx` | 3.69 s | 7.05 tok/s | 8.1 GiB | 100% GPU | rejected |
| `gemma4:12b-mlx` | 2.63 s | 8.99 tok/s | 7.6 GiB | 100% GPU | rejected |

Free space in KiB was captured immediately before and after every serial pull
and is recorded in `config/models.json`. Those point-in-time values are not
treated as model sizes because APFS, swap, and other concurrently running host
work can change them. Manifest byte totals are the authoritative artifact sizes.

`ollama ps` supplied the resident-size measurement above and showed only the
requested model, `100% GPU`, and the 4,096-token runtime context after each
load. It is not a process-wide peak-memory profiler; P8-T02 owns instrumented
peak-memory benchmarking. A final request used `keep_alive: 0`, and the runner
stopped. Full switching stress tests remain P2-T03's responsibility.

## Consequences

- Three aliases resolve to immutable approved standard manifests. Only Gemma is
  advertised for vision; Qwen image input remains explicitly unsupported.
- All six downloaded candidates remain in the user's standard Ollama store as
  preserved qualification evidence; no existing Hugging Face cache or unrelated
  model state was moved or removed.
- P2-T02 may automate only the three executable standard tags and must verify
  their manifest digests after pull.
- Broader model-quality and memory ranking is deferred to P8. The defaults here
  route only by demonstrated capability and intended size role.
