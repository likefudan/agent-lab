# T06 Benchmarks and final profile

- Depends on: T05
- Design sections: 2, 4, 5, 10, 11
- Size: medium (little code; most of the work is measuring on the device)

## Goal

Replace the key [estimate] and [to verify] numbers in the design with measurements from the target machine, and settle the `mac-24gb` profile, especially the context limit for agent use.

## Scope

In scope:

1. **First measurement: does reusing the prompt cache copy the KV cache?** Using a multi-turn conversation of about 16K tokens, record the inference process's peak memory on the first turn and on the second turn (cache hit). If the second turn peaks about one KV cache higher, the cache is copied, and the default drops to 24K as described in design section 4.2.
2. `alab bench`, measured through the gateway (with a key), writing JSON and Markdown reports to `var/bench/<timestamp>/`:
   - prefill speed (tok/s) and time to first token at prompt lengths 1K, 8K, 16K, 24K and 32K;
   - decode speed (tok/s) for 256 and 1024 generated tokens;
   - **agent simulation**: a fixed system prompt plus tool definitions of about 10K tokens, then 15 rounds of "tool call → tool result", each adding about 1K tokens; record each round's time to first token, cache hits and peak memory;
   - peak RSS of the inference process, Metal peak memory (if available), and system swap growth (`sysctl vm.swapusage`);
   - a 10-minute sustained generation speed curve (to observe fanless throttling);
   - one complete request with the tunnel off and the network disconnected (to confirm inference makes no outbound connections).
3. Each report records the environment: chip, memory, macOS version, mlx-lm version, model revision, profile, GPU limit and Metal memory limit.
4. Finalize `config/profiles/mac-24gb.toml` from the results: `max_context`, `gpu_wired_limit_mb`, `metal_memory_limit`, `prompt_cache_bytes`, `prefill_step_size`.
5. Update `docs/design.md`: replace the corresponding numbers in sections 2, 4 and 5 with measured values labelled [measured], update the risk status in section 11, and keep `limit.context` in the section 7.4 opencode example in line with the final value.
6. Commit the Markdown report to `docs/benchmarks/` (reports only, no raw data).
7. If 24K still does not pass, evaluate a self-converted Q3 build and add the comparison to the report.
8. Also check whether `Qwen3.8-27B-MTP-4bit` runs on the current mlx-lm and how much faster it is; record the finding in the report without changing the default configuration.

Out of scope: other models (T10).

## Acceptance criteria

- [ ] Pass criteria (design section 10): with the final profile, run the agent simulation filling `max_context` three times in a row; peak memory of the inference process stays under the GPU limit, system swap grows by less than 1GB, and there are no errors.
- [ ] A complete report is in `docs/benchmarks/`, and `docs/design.md` has no [to verify] numbers left for the `mac-24gb` profile.
- [ ] A shortened `alab bench` runs in CI with the tiny model (checks the flow, not the numbers).
- [ ] CI passes.
