# T05 OpenAI-compatible gateway (auth, limits, tool calls, heartbeats)

- Depends on: T04
- Design sections: 5, 6.1, 6.3, 7.3, 7.4, 9
- Size: large (if gateway-side tool-call parsing is needed, this can be split into T05a for the gateway and T05b for tool-call parsing)

## Goal

Provide the single externally reachable endpoint at `127.0.0.1:8000`: every request is authenticated, oversized requests cannot push the machine into swap, requests from Cursor and opencode work, and streaming connections survive Cloudflare's 100-second limit.

## Scope

In scope:

1. An ASGI app (Starlette + uvicorn + httpx) with only:
   - `POST /v1/chat/completions` (streaming and non-streaming, with `tools` / `tool_choice` / `tool_calls`);
   - `GET /v1/models` (returns `qwen3.8-27b`);
   - `GET /healthz` (returns only `ok` or `unavailable`);
   - 404 for every other path.
2. Authentication:
   - `alab keys create <name>` generates a 32-byte random key and shows it once; `var/secrets/keys.toml` stores only hashes. Also `alab keys list` and `alab keys revoke <name>`.
   - Every request, including from 127.0.0.1, needs a valid `Authorization: Bearer` header; compare in constant time; return 401 on failure.
   - Key changes take effect without restarting the gateway (read on every request, or watch the file).
   - `alab serve` refuses to start when no key exists.
3. Token limit: render the prompt with the chat template (including tool definitions) using the `transformers` tokenizer mlx-lm already depends on, and test that the rendering matches the backend's.
   - If the prompt exceeds `max_context - min_output_tokens`, return 400 with `error.code = "context_length_exceeded"` in OpenAI's error format.
   - Otherwise clamp `max_tokens` to `min(requested, max_output_tokens, max_context - prompt_tokens)` before forwarding. Accept `max_completion_tokens` too.
4. Parameters:
   - The external model name is `qwen3.8-27b`, replaced with the backend's internal name when forwarding; any other model name gets an OpenAI-style "model not found" error. The backend's internal name is `default_model` (or leave `model` out): mlx-lm treats any other name as a Hugging Face repository to load [found in T04].
   - `reasoning_effort`: `none` (default) / `low` / `medium` / `high`, converted into mlx-lm `chat_template_kwargs`; confirm the exact argument names against the model's chat template.
   - Fill in the thinking or non-thinking recommended sampling values when the client sets none.
   - Image content returns 400, explaining that v1 does not support it.
5. Tool calls:
   - If T04 found mlx-lm's parsing reliable: pass through as-is and add tests. **T04 found it reliable** (9 of 9 checks on the 27B, see `docs/results/t04-tool-call-check.md`), so this is the path; `tests/tool_call_check.py --url http://127.0.0.1:8000 --api-key ...` reruns the same check through the gateway.
   - If not: call the backend for plain text generation and convert tool-call blocks in the model output into OpenAI format in the gateway (complete `tool_calls` for non-streaming, `delta.tool_calls` increments for streaming, `finish_reason` = `tool_calls`). Unit-test against a fixed set of model outputs covering multiple tool calls, arguments with newlines and quotes, nested JSON arguments, and truncated output.
6. Concurrency and heartbeats:
   - Forward one request at a time; queue up to `queue_size` and return 429 beyond that.
   - For streaming requests, send response headers immediately (`Content-Type: text/event-stream`, `Cache-Control: no-cache`), then a `: keep-alive` comment line every `heartbeat_seconds` while the request is queued or prefilling.
   - When the client disconnects, cancel the backend request and free the queue slot.
7. Logging: time, key name, prompt and output token counts, queue time, duration and status code only; no bodies.
8. `alab serve` now starts the backend, waits for it to be healthy, then starts the gateway; `stop` and `status` cover both; `status` shows the queue length.

Out of scope: the tunnel (T07); conversation storage; multi-model routing; `/v1/completions`, embeddings and the Responses API.

## Acceptance criteria

- [ ] Unit tests (with a fake backend): no key / wrong key / revoked key → 401; requests from 127.0.0.1 also need a key; an oversized prompt → `context_length_exceeded`; `max_tokens=32000` is clamped, not rejected; `reasoning_effort` conversion; default sampling; full queue → 429; heartbeats are sent on schedule while the backend is slow; a client disconnect cancels the backend request.
- [ ] If gateway-side tool-call parsing is implemented: all parsing sample tests pass.
- [ ] CI integration test: tiny model + gateway, using the official `openai` Python SDK for a normal request, a streaming request and a request with `tools`.
- [ ] A request over `max_context` is rejected at the gateway and never reaches the backend (check the backend log).
- [ ] Device test: with the 27B model, send a streaming request with one simple tool (for example `get_weather`) and paste the returned `tool_calls`; send the same question with `reasoning_effort=none` and `low` and paste output token counts and times.
- [ ] CI passes.
