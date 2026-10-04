# T10 Fast profile evaluation (Gemma 4 26B-A4B)

- Depends on: T08
- Design section: 3.4
- Size: small to medium
- Priority: optional. Only do this if the 27B speed measured in T06 and T08 is not good enough for daily use

## Goal

Decide whether Gemma 4 26B-A4B, a MoE model that trades capability for speed, is worth offering as a "fast" profile.

## Scope

In scope:

1. Confirm an MLX 4-bit build of Gemma 4 26B-A4B and its mlx-lm support, and add it to `config/models.toml`.
2. Add a `config/profiles/mac-24gb-fast.toml` profile.
3. Let the gateway take its external model name from the profile (for example `gemma-4-26b-a4b`), with `/v1/models` returning the loaded model. Still only one model runs at a time. Check this model's tool-call parsing in mlx-lm and reuse the T05 approach.
4. Compare speed and memory against the 27B with `alab bench` (including the agent simulation), then compare task completion and total time with T08's end-to-end tasks in opencode. Write the results into a report.
5. Based on the results, state in `docs/design.md` section 3.4 whether it is recommended and for what.

Out of scope: loading two models at once; switching models automatically per request.

## Acceptance criteria

- [ ] Comparison report committed to `docs/benchmarks/`.
- [ ] `alab serve --profile mac-24gb-fast` starts and serves chat through the gateway.
- [ ] CI passes.
