# T08 离线打包与迁移

- 依赖：T06（T07 合入后包含 Ollama 选项）
- 对应设计：第 7.3、7.4 节
- 预计规模：中

## 目标

把一个档位的完整运行环境打成单个离线包，在另一台 Apple Silicon Mac 上无需联网即可部署运行。

## 范围

做：

1. `alab pack --profile <档位> [--output <路径>]`，生成 `agent-lab-bundle-<版本>-<档位>.tar`，结构按设计第 7.3 节：
   - `source/`：`git archive` 导出的当前提交；
   - `tools/`：uv 二进制、Python 发行版、（档位使用 Ollama 时）Ollama 二进制；
   - `wheels/`：按 `uv.lock` 导出的全部 macOS arm64 wheel（`.venv` 不可迁移，不打包，在目标机器上用这些 wheel 重建）；
   - `models/`：档位所需的模型文件；
   - `manifest.json`：版本、git commit、档位、最低 macOS 版本、每个文件的 sha256 和大小。
2. 包内附带 `unpack.sh`（不依赖目标机器上的任何 Python）：检查芯片和 macOS 版本 → 检查磁盘空间 → 校验 manifest → 释放到目标目录 → 用本地 wheel 离线安装 → 运行 `alab doctor`。任一步失败都停止，不留下半安装状态。
3. 打包前检查：工作区有未提交改动时拒绝打包（可用 `--allow-dirty` 跳过并在 manifest 中标注）。
4. 支持把大包拆分成多个分片（如每片 4GB），方便用 U 盘或网盘传输，`unpack.sh` 自动合并。

不做：Linux/NVIDIA 目标（设计第 7.4 节明确不在 v1 范围内）；自动更新。

## 验收标准

- [ ] CI：用小模型档位打包，在同一 runner 上禁止网络（用 macOS `sandbox-exec` 的禁网策略运行，或设置无效代理）后解包、启动服务并完成一次请求。
- [ ] 篡改包内任一文件后，`unpack.sh` 校验失败并停止。
- [ ] 隔离检查：解包和运行过程中 `$HOME` 下没有新增文件（GPU 上限命令除外，它不写文件）。
- [ ] 设备测试：在 MacBook Air M5 上打出 `mac-24gb` 的完整包，解包到另一个目录（模拟另一台机器），断网后启动并完成一次对话，贴出包大小和各步骤耗时。
- [ ] CI 全部通过。
