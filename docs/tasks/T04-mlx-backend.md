# T04 mlx-lm backend and process management

- Depends on: T02, T03
- Design sections: 3.3, 5, 6.1, 6.4, 6.5, 7.4
- Size: medium

## Goal

Start, stop and inspect the mlx-lm inference server with one command; confirm that Qwen3.8-27B runs text-only on a pinned mlx-lm version and that **tool calls are parsed correctly**.

## Scope

In scope:

1. **Verify before writing code**, and put the findings in the PR description:
   - Qwen3.8-27B support in mlx-lm (`model_type` in `config.json`, minimum mlx-lm version); pin that version in `pyproject.toml`.
   - Tool calls: force the `qwen3_coder` parser (CLI argument, or `tool_parser_type` in the local model's `tokenizer_config.json`), then test non-streaming and streaming requests. Check that `tool_calls` come back correctly: function name, argument JSON, multiple tool calls, and arguments containing newlines and quotes.
   - If the model itself is not supported, stop this task, explain in the PR, and adjust the plan per design section 11. If only tool-call parsing is unreliable, finish this task and state clearly in the PR that "T05 must implement parsing in the gateway".
2. A launch wrapper, `agent_lab.backend.launch`, that first sets the Metal memory limit (`mx.set_memory_limit()` or the current equivalent, using the profile's `metal_memory_limit`) and then starts `mlx_lm.server` in the same process. All arguments come from the profile:
   - model path `var/models/<id>`;
   - listen on `127.0.0.1` only, port 8100;
   - `--decode-concurrency 1` and `--prompt-concurrency 1`;
   - `--prefill-step-size`, `--prompt-cache-size` and `--prompt-cache-bytes` from the profile;
   - `--chat-template-args '{"enable_thinking": false}'` by default;
   - default sampling parameters from the model card's non-thinking recommendations;
   - `HF_HUB_OFFLINE=1`.
3. Process management: pid in `var/run/`, logs in `var/logs/` (rotated daily, no request bodies). After start, poll the health check; on timeout, stop the process and fail. `stop` sends SIGTERM, then SIGKILL after a timeout. `status` shows pid, port, memory (RSS) and log path.
4. Before starting, run T03's checks: refuse to start if the GPU limit is below what the profile needs (`--force` overrides this with a warning).
5. In this task `alab serve` only starts the backend; T05 changes it to start the gateway as well.

Out of scope: the gateway, authentication and the token limit (T05); the tunnel (T07); benchmarks (T06).

## Acceptance criteria

- [ ] CI integration test: with T02's tiny model, run `serve` → one chat request → `status` → `stop`, and confirm the process has exited and the port is free.
- [ ] Running `serve` twice detects the running instance and does not start a second process.
- [ ] If the backend exits unexpectedly, `status` reports it and shows the log path.
- [ ] Exceeding the Metal memory limit makes the backend raise or return an error rather than panicking the system (verified in CI with the tiny model and a very low limit).
- [ ] Device test: on the MacBook Air M5 with the GPU limit applied, hold a short conversation with the 27B model and paste the mlx-lm version, load time, RSS, and generation speed for a roughly 200-token answer; confirm no thinking content is produced by default.
- [ ] Device test: confirm the vision tower weights are not loaded in text-only mode (compare RSS or logs).
- [ ] Device test: paste the full requests and responses from the tool-call check in step 1 into the PR.
- [ ] CI passes.
