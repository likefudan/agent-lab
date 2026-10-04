# T09 Offline bundle and migration

- Depends on: T07
- Design sections: 8.3, 8.4
- Size: medium

## Goal

Pack the complete runtime for one profile into a single offline bundle that can be deployed and run on another Apple Silicon Mac without network access.

## Scope

In scope:

1. `alab pack --profile <profile> [--output <path>]` builds `agent-lab-bundle-<version>-<profile>.tar`, laid out as in design section 8.3:
   - `source/`: the current commit via `git archive`;
   - `tools/`: the uv binary, the Python distribution and the cloudflared binary;
   - `wheels/`: macOS arm64 wheels for everything in `uv.lock` (`.venv` is not relocatable, so it is not bundled; the target rebuilds it from these wheels);
   - `models/`: the model files the profile needs;
   - `manifest.json`: version, git commit, profile, minimum macOS version, and every file's sha256 and size;
   - **no secrets**: `var/secrets/` is never included, and after packing the bundle is scanned to confirm it contains no key hashes or tunnel token.
2. An `unpack.sh` inside the bundle (needs no Python on the target): check chip and macOS version → check disk space → verify the manifest → extract to the target directory → install offline from the bundled wheels → run `alab doctor`. Any failure stops the process without leaving a half-installed copy.
3. Refuse to pack with uncommitted changes in the working tree (`--allow-dirty` overrides this and marks it in the manifest).
4. Optionally split the bundle into parts (for example 4GB each) for USB drives or cloud storage; `unpack.sh` joins them automatically.

Out of scope: Linux/NVIDIA targets (design section 8.4 rules them out for v1); automatic updates.

## Acceptance criteria

- [ ] CI: pack a profile that uses the tiny model, then on the same runner with networking blocked (macOS `sandbox-exec` with a no-network policy, or an invalid proxy) unpack it, start the service and complete one request.
- [ ] Tampering with any file in the bundle makes `unpack.sh` fail verification and stop.
- [ ] The bundle contains nothing from `var/secrets/`.
- [ ] Isolation check: unpacking and running create nothing new under `$HOME` (the GPU limit command writes no files).
- [ ] Device test: on the MacBook Air M5, build the full `mac-24gb` bundle, unpack it into another directory (simulating another machine), go offline, start with `--no-tunnel`, create a new key and complete one conversation. Paste the bundle size and the time for each step.
- [ ] CI passes.
