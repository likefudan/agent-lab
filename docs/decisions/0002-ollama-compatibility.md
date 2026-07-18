# 0002 — Ollama compatibility baseline

- **Status:** Accepted
- **Verified:** 2026-07-18
- **Component:** Ollama `0.32.1`
- **Target:** Apple Silicon macOS 26.5.2 (`arm64`)

## Decision

Use Ollama `0.32.1` as Agent Lab's native MVP inference runtime. The selected
artifact is the Homebrew `arm64_tahoe` bottle built from upstream tag
`v0.32.1` at commit `30c390384e20333b67cadab60da5bcb669407f01`. Its package
digest is recorded in `config/components.json`.

Run it only on `http://127.0.0.1:11434`, with `OLLAMA_NO_CLOUD=1` and
`OLLAMA_MAX_LOADED_MODELS=1`. Use `GET /api/version` as the process health
probe. A successful response must contain the pinned version; a TCP listener
alone is not sufficient.

Ollama's native API is the preferred integration for Open WebUI. Terminal
clients may use the OpenAI-compatible base URL
`http://127.0.0.1:11434/v1`. No API key is required by the loopback server;
clients that require a non-empty key may use a non-secret placeholder.

## Release and platform evidence

| Property | Selected or observed value |
| --- | --- |
| Release | `0.32.1` |
| Upstream release | <https://github.com/ollama/ollama/releases/tag/v0.32.1> |
| Source revision | `30c390384e20333b67cadab60da5bcb669407f01` |
| Installed artifact | Homebrew `arm64_tahoe` bottle from `ghcr.io/v2/homebrew/core/ollama` |
| Bottle SHA-256 | `cfcacbdc44740a17b8221a16d90f600f6a88782fc3efd2dc073ebddd9cae180e` |
| Installed executable SHA-256 | `8ac71f1dbc4ef2efb9f15257f016aca199e72a89b278c6af64b1d693dd442b15` |
| License | MIT; the installed package includes upstream `LICENSE` |
| Upstream minimum macOS | macOS 14 Sonoma; Apple M-series supports CPU and GPU |
| Qualified host | macOS 26.5.2 on Apple M5 |

The upstream [macOS documentation](https://docs.ollama.com/macos) states the
minimum OS and hardware support. Homebrew's selected bottle is specific to the
target's Tahoe generation; the upstream macOS 14 minimum does not imply this
particular bottle can be copied to every older macOS release.

## API and runtime contract

| Requirement | Result | Evidence |
| --- | --- | --- |
| Native API | Verified | `GET /api/version`, `GET /api/tags`, and `GET /api/ps` returned valid JSON from the installed server. A missing model sent to `POST /api/chat` returned the documented local `404` error. |
| OpenAI-compatible API | Verified | `GET /v1/models` returned an OpenAI-style empty list. `POST /v1/chat/completions` reached local model lookup and returned `404` for a deliberately absent model. |
| Streaming | Supported contract; model exercise deferred to P0-T03 | The installed endpoint accepted `stream: true` through request validation. The official compatibility reference lists streaming for `/v1/chat/completions`, and the native REST API streams by default. |
| Image input | Supported contract; model exercise deferred to P0-T03 | The installed `/v1/chat/completions` endpoint accepted an image content-part request through model lookup. The official reference supports base64 data and image URLs. Actual interpretation depends on the selected model. |
| Tool calls | Supported contract; model exercise deferred to P0-T03 | The installed endpoint accepted a function-tool request through model lookup. Both native chat and OpenAI compatibility document tools; actual tool-call quality is model-dependent. |
| Keep-alive | Verified configuration contract | `ollama serve --help` exposes `OLLAMA_KEEP_ALIVE`; native chat/generate document per-request `keep_alive`, including `0` for immediate unload. The test server logged `OLLAMA_KEEP_ALIVE:0s`. |
| One-model limit | Verified configuration contract | `ollama serve --help` exposes `OLLAMA_MAX_LOADED_MODELS`; startup logs recorded `OLLAMA_MAX_LOADED_MODELS:1`. Residency behavior is exercised with real models in P2-T03. |
| Local-only mode | Verified | `ollama serve --help` exposes `OLLAMA_NO_CLOUD`; startup logs recorded both `OLLAMA_NO_CLOUD:true` and `Ollama cloud disabled: true`. A nonexistent model failed locally instead of routing to cloud inference. |
| Bind address | Verified | Startup logged `Listening on 127.0.0.1:11434`. `lsof` showed only that IPv4 loopback listener, and a connection to the active LAN address on port `11434` was unavailable. |
| Model metadata | Verified | `ollama list`/`GET /api/tags` and `ollama ps`/`GET /api/ps` returned empty inventories. `ollama show`/`POST /api/show` is the documented source for model license, capabilities, format, family, size, quantization, and model metadata after P0-T03 pulls a model. |

The API evidence is based on the installed `0.32.1` server plus the official
[native chat](https://docs.ollama.com/api/chat),
[OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility),
[streaming](https://docs.ollama.com/capabilities/streaming),
[model details](https://docs.ollama.com/api-reference/show-model-details), and
[FAQ](https://docs.ollama.com/faq) contracts as read on the verification date.
Ollama documents its API as stable and backwards compatible but not strictly
versioned, so later release qualification must repeat these probes rather than
assuming the current hosted documentation still describes a different binary.

## Apple Silicon acceleration observation

The selected executable is a native `arm64` Mach-O binary linked to Apple's
Metal framework. At startup it discovered one inference device as
`library=Metal`, `description="Apple M5"`, `type=iGPU`, with 17.8 GiB available,
and selected a VRAM-based context default. This is direct evidence that the
installed server discovers the intended Apple GPU path; it is more precise
than labeling every Ollama execution an "MLX engine."

The Homebrew package also installed native-arm64 MLX `0.32.0` and MLX-C
`0.6.0_3`. The binary contains the MLX runner and safetensors paths, and upstream
states that MLX is enabled by default on macOS arm64. No model exists yet, so
this task did **not** claim that a model performed inference through MLX or
report a GPU-offload percentage. P0-T03 must load each candidate and record its
actual runner, capabilities, and inference result; `ollama ps` is the supported
check for the loaded processor split.

## Reproduction

Start the selected binary without enabling a persistent login service:

```sh
OLLAMA_HOST=127.0.0.1:11434 \
OLLAMA_NO_CLOUD=1 \
OLLAMA_MAX_LOADED_MODELS=1 \
OLLAMA_KEEP_ALIVE=0 \
/opt/homebrew/opt/ollama/bin/ollama serve
```

From a second terminal, run the non-mutating probes:

```sh
ollama --version
curl --fail http://127.0.0.1:11434/api/version
curl --fail http://127.0.0.1:11434/api/tags
curl --fail http://127.0.0.1:11434/api/ps
curl --fail http://127.0.0.1:11434/v1/models
lsof -nP -iTCP:11434 -sTCP:LISTEN
ollama list
ollama ps
```

Also probe the host's active non-loopback address and require the connection to
fail. Do not publish that address in test artifacts.

## Consequences

- P0-T03 may evaluate models against this exact runtime, but must not infer
  model-level vision, tools, streaming quality, or MLX execution from the
  server-level contract recorded here.
- P2-T01 must preserve the loopback bind, cloud disablement, and one-model
  limit. It must not use `brew services` defaults without an environment-aware
  launch configuration.
- `OLLAMA_KEEP_ALIVE` remains a measured tuning value. The `0` used here made
  this capability test deterministic; it is not yet the production default.
- Upgrading Ollama, its Homebrew bottle, MLX, or MLX-C requires rerunning this
  decision's probes and recording new immutable identifiers.
