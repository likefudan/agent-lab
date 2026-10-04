# T03 GPU 内存上限管理与环境检查

- 依赖：T01（可与 T02 并行）
- 对应设计：第 4.3、6.5、8.1 节
- 预计规模：小

## 目标

把本方案唯一的系统级改动（临时提高 GPU 可用内存上限）做成显式、可查看、可恢复的命令，并让 `doctor` 能判断当前机器能否运行所选档位。

## 范围

做：

1. `alab gpu-limit show`：显示当前 `iogpu.wired_limit_mb` 的值、Metal 报告的 `recommendedMaxWorkingSetSize`、物理内存，以及当前档位要求的值。
2. `alab gpu-limit apply [--profile]`：
   - 读取档位的 `gpu_wired_limit_mb`；
   - 显示将要执行的命令和风险说明，要求用户输入确认（提供 `--yes` 跳过确认，但默认需要确认）；
   - 调用 `sudo sysctl iogpu.wired_limit_mb=<值>`；
   - 拒绝设置超过"物理内存 − 3GB"的值。
3. `alab gpu-limit revert`：设回 0（系统默认）。
4. `doctor` 增加检查项：GPU 上限是否满足档位要求、当前空闲内存和 swap 使用量、所需端口是否被占用。
5. 读取 `recommendedMaxWorkingSetSize` 的方式：优先通过 MLX（`mx.metal.device_info()` 或同等接口），不可用时说明原因并只显示 sysctl 值。本任务因此引入锁定版本的 `mlx` 依赖；T04 引入 mlx-lm 时保持版本兼容。

不做：开机自动应用（明确不做，设计第 4.3 节）；修改任何其他系统设置。

## 验收标准

- [ ] 不带 `--yes` 时，不输入确认不会执行 sudo。
- [ ] 设置值超过上限时被拒绝。
- [ ] 单元测试覆盖：确认流程、上限计算、sysctl 调用参数（用 mock，不在 CI 中真正执行 sudo）。
- [ ] 设备测试：在 MacBook Air M5 上依次运行 `show` → `apply` → `show` → `revert` → `show`，贴出输出，并贴出默认状态下 `recommendedMaxWorkingSetSize` 的实际数值（用于修正设计第 2 节中的"约 16–18GB"）。
- [ ] CI 全部通过。

## 备注

- 本任务的设备测试中实测到的默认上限，要同步更新到 `docs/design.md` 第 2 节和第 4.3 节。
