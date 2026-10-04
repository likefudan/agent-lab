# T06 基准测试与档位定稿

- 依赖：T05
- 对应设计：第 2、4、5、10、11 节
- 预计规模：中（代码量不大，主要工作是在设备上测量）

## 目标

用目标机器上的实测数据替换设计文档中关键的 [估算] 和 [待验证] 数字，确定 `mac-24gb` 档位的最终参数，特别是 agent 场景下的 context 上限。

## 范围

做：

1. **第一项测量：prompt cache 复用时是否复制 KV。** 用一个约 16K token 的多轮对话，记录"首轮"和"第二轮命中缓存"时推理进程的峰值内存。如果第二轮峰值比首轮多出约一份 KV 的大小，说明会复制，默认档按设计第 4.2 节降为 24K。
2. `alab bench`，通过网关（带 key）测量，输出 JSON 和 Markdown 报告到 `var/bench/<时间戳>/`：
   - prefill 速度（tok/s）和首 token 延迟，提示长度阶梯：1K、8K、16K、24K、32K；
   - 解码速度（tok/s），生成 256 和 1024 token；
   - **agent 模拟**：一段固定的约 10K token 系统提示加工具定义，然后进行 15 轮"工具调用 → 工具结果"的循环，每轮新增约 1K token，记录每轮的首 token 延迟、缓存命中情况和峰值内存；
   - 推理进程峰值 RSS、Metal 峰值内存（如可获取）、系统 swap 增量（`sysctl vm.swapusage`）；
   - 10 分钟持续生成的速度曲线（观察无风扇降频）；
   - 关闭 tunnel 并断网时完成一次完整请求（确认推理不访问外网）。
3. 报告中附带环境信息：芯片、内存、macOS 版本、mlx-lm 版本、模型 revision、档位、GPU 上限、Metal 内存上限。
4. 根据结果定稿 `config/profiles/mac-24gb.toml`：`max_context`、`gpu_wired_limit_mb`、`metal_memory_limit`、`prompt_cache_bytes`、`prefill_step_size`。
5. 更新 `docs/design.md`：第 2、4、5 节中对应的数字替换为实测值并标注 [实测]，更新第 11 节的风险状态；第 7.4 节 opencode 示例中的 `limit.context` 与定稿值保持一致。
6. 把报告的 Markdown 版本提交到 `docs/benchmarks/`（只提交报告，不提交原始数据）。
7. 如果 24K 仍不达标，评估 Q3 自转换版本，把对比数据写进报告。
8. 顺带评估：`Qwen3.8-27B-MTP-4bit` 在当前 mlx-lm 上能否运行、提速多少；结论写进报告，不改默认配置。

不做：其他模型（T10）。

## 验收标准

- [ ] 达标标准（设计第 10 节）：在定稿档位下，用满 `max_context` 的 agent 模拟连续运行 3 次，推理进程峰值内存不超过 GPU 上限，系统 swap 增量小于 1GB，无报错。
- [ ] `docs/benchmarks/` 中有完整报告，`docs/design.md` 中不再有关于 `mac-24gb` 档位的 [待验证] 数字。
- [ ] `alab bench` 在 CI 中能用小模型跑通一个缩短版本（只验证流程，不看数值）。
- [ ] CI 全部通过。
