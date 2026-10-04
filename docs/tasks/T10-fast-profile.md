# T10 快速档模型评估（Gemma 4 26B-A4B）

- 依赖：T06
- 对应设计：第 3.4 节
- 预计规模：小到中
- 优先级：可选。只有在 T06 实测的 27B 速度无法满足日常使用时才做

## 目标

评估用能力换速度的 MoE 模型 Gemma 4 26B-A4B 作为"快速档"是否值得提供。

## 范围

做：

1. 确认 Gemma 4 26B-A4B 的 MLX 4-bit 版本及 mlx-lm 支持情况，加入 `config/models.toml`。
2. 新增档位 `config/profiles/mac-24gb-fast.toml`。
3. 网关支持按档位切换对外模型名（如 `gemma-4-26b-a4b`），`/v1/models` 返回当前加载的模型。仍然坚持同一时间只运行一个模型。确认该模型在 mlx-lm 中的工具调用解析，复用 T05 的处理方式。
4. 用 `alab bench`（含 agent 模拟）与 27B 对比速度和内存；再用 T08 的端到端任务在 opencode 中对比完成率和总耗时，结果写进报告。
5. 根据结果在 `docs/design.md` 第 3.4 节写明是否推荐，以及适用场景。

不做：同时加载两个模型；自动按请求切换模型。

## 验收标准

- [ ] 对比报告提交到 `docs/benchmarks/`。
- [ ] `alab serve --profile mac-24gb-fast` 能正常启动并通过网关对话。
- [ ] CI 全部通过。
