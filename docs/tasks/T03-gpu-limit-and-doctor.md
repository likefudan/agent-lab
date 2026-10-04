# T03 GPU memory limit and environment checks

- Depends on: T01 (can run in parallel with T02)
- Design sections: 4.3, 6.5, 8.1
- Size: small

## Goal

Turn the design's only system-level change (temporarily raising the GPU wired memory limit) into explicit commands that can be inspected and reverted, and let `doctor` tell whether this machine can run the chosen profile.

## Scope

In scope:

1. `alab gpu-limit show`: shows the current `iogpu.wired_limit_mb`, Metal's `recommendedMaxWorkingSetSize`, physical memory, and the value the current profile needs.
2. `alab gpu-limit apply [--profile]`:
   - reads the profile's `gpu_wired_limit_mb`;
   - shows the exact command and the risks, then asks for confirmation (`--yes` skips it, but confirmation is the default);
   - runs `sudo sysctl iogpu.wired_limit_mb=<value>`;
   - refuses any value above "physical memory minus 3GB".
3. `alab gpu-limit revert`: sets it back to 0 (the system default).
4. New `doctor` checks: whether the GPU limit meets the profile, current free memory and swap usage, and whether the needed ports are free.
5. Read `recommendedMaxWorkingSetSize` through MLX (`mx.metal.device_info()` or its current equivalent); if that is unavailable, explain why and show only the sysctl value. This task therefore adds a pinned `mlx` dependency; T04 keeps mlx-lm compatible with it.

Out of scope: applying the limit at boot (explicitly ruled out in design section 4.3); changing any other system setting.

## Acceptance criteria

- [ ] Without `--yes`, nothing runs with sudo unless the user confirms.
- [ ] Values above the ceiling are refused.
- [ ] Unit tests cover the confirmation flow, the ceiling calculation and the sysctl arguments (mocked; CI never runs sudo).
- [ ] Device test: on the MacBook Air M5, run `show` → `apply` → `show` → `revert` → `show`, paste the output, and record the default `recommendedMaxWorkingSetSize` (to correct the "about 16–18GB" in design section 2).
- [ ] CI passes.

## Notes

- Update `docs/design.md` sections 2 and 4.3 with the default limit measured in this task's device test.
