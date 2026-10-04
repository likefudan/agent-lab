# T02 Model registry and downloads

- Depends on: T01
- Design sections: 3.2, 8.2
- Size: medium

## Goal

Manage model files through a pinned, verifiable registry, so downloads are reproducible and the offline bundle (T09) can reuse them directly.

## Scope

In scope:

1. `config/models.toml`. Each entry has: `id`, Hugging Face repo, **commit revision**, the file list with each file's sha256 and size, disk space needed, and a description. Initial entries:
   - `qwen3.8-27b-mlx-4bit`: `mlx-community/Qwen3.8-27B-4bit`;
   - a tiny MLX model for CI (0.5B-class, 4-bit), used by the T04/T05 integration tests.
2. `alab pull <model-id>`:
   - downloads into `var/models/<model-id>/` (via `huggingface_hub`; T01 already points `HF_HOME` inside the project);
   - checks free disk space first and fails early if it is not enough;
   - resumes interrupted downloads;
   - verifies every file's sha256 afterwards; on a mismatch, deletes that file and fails;
   - skips files that already exist and verify.
3. `alab models`: lists registry entries with their local state (not downloaded / downloaded / failed verification).
4. A maintenance command (for example `alab models lock <id>`) that reads the file list and sha256 for a given revision from Hugging Face and generates the registry entry, so nobody types hashes by hand.

Out of scope: model conversion (such as a self-converted Q3 build; done in T06 only if needed).

## Acceptance criteria

- [ ] `alab pull` downloads and verifies the CI model (runs in CI).
- [ ] After changing one sha256 in the registry, `alab pull` detects the mismatch and fails.
- [ ] After interrupting a download (Ctrl-C), running it again resumes instead of starting over.
- [ ] Nothing new appears under `$HOME/.cache/huggingface`.
- [ ] Device test: download `qwen3.8-27b-mlx-4bit` on the MacBook Air M5 and paste the time taken, disk usage and verification result.
- [ ] CI passes.

## Notes

- The mlx-community 4-bit repo includes the vision tower weights (about 0.9GB). This task still downloads everything so vision can be added later; mlx-lm ignores those weights when loading text-only, which T04 verifies.
