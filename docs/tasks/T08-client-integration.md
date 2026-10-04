# T08 Cursor and opencode integration

- Depends on: T07
- Design sections: 6.3, 7.4
- Size: medium (mostly end-to-end verification; code changes depend on what turns up)

## Goal

Both Cursor and opencode can use Qwen3.8-27B through `https://api.llmat.dev/v1`, including their agent (tool-calling) features, with what works and what doesn't written down clearly.

## Scope

In scope:

1. Configuration templates:
   - `examples/opencode/opencode.json`: as in design section 7.4, with `limit.context` and `limit.output` matching the profile and the key read from an environment variable;
   - `docs/clients/cursor.md`: Cursor setup steps (Pro plan required), what works, known limitations.
2. End-to-end checks with a small dedicated test repository (`tests/e2e/sample-repo/`, for example a Python project with a few functions and one failing test). Run the same tasks in each client and record success, number of turns, total time and errors:
   - Q&A: explain what a function does (no tools);
   - read and answer: find why the failing test fails;
   - edit code: fix the failing test and run the tests;
   - multi-file edit: add a parameter to a function and update every call site.
3. Cursor-specific:
   - check that both Chat and Agent modes work;
   - check what Cursor does on a `context_length_exceeded` error: whether it compacts and retries, and whether it shows a readable error;
   - based on that, write the recommended usage into `docs/clients/cursor.md` (for example "one new chat per task").
4. opencode-specific: check that it compacts the conversation when approaching `limit.context`, and keeps working afterwards.
5. Fix gateway compatibility problems found along the way (unsupported request fields, streaming format differences, tool-call format differences). Problems outside the gateway go into design section 11.
6. Write the results up as `docs/benchmarks/clients-<date>.md`.

Out of scope: Cursor Tab completion (does not support custom models); other clients such as Aider or Continue (T11 gives generic instructions).

## Acceptance criteria

- [ ] opencode: at least three of the four tasks succeed, including "edit code".
- [ ] Cursor: Q&A works in Chat mode; Agent mode completes at least "read and answer" and "edit code".
- [ ] Neither client hits connection failures caused by heartbeats or authentication during the checks.
- [ ] The results document and both client guides are committed.
- [ ] Any gateway changes have unit tests, and CI passes.

## Notes

- If Cursor's Agent mode keeps stalling in practice because of its 1M-context assumption, recommend opencode for long tasks in the docs rather than truncating in the gateway (truncating tool-call history makes agent behaviour unpredictable).
