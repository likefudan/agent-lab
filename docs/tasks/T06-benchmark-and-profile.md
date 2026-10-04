# T06 基准测试与档位定稿

- 依赖：T05
- 对应设计：第 2、4、5、9、10 节
- 预计规模：中（代码量不大，主要工作是在设备上测量）

## 目标

用目标机器上的实测数据替换设计文档中所有标注为 [估算] 和 [待验证] 的关键数字，并确定 `mac-24gb` 档位的最终参数。

## 范围

做：

1. `alab bench`，通过网关测量并输出 JSON 和 Markdown 报告到 `var/bench/<时间戳>/`：
   - prefill 速度（tok/s）和首 token 延迟，提示长度阶梯：1K、8K、16K、24K、32K；
   - 解码速度（tok/s），生成 256 和 1024 token；
   - 推理进程峰值 RSS、Metal 峰值内存（如可获取）、系统 swap 增量；
   - 多轮对话时 prompt cache 命中对首 token 延迟的影响；
   - 10 分钟持续生成的速度曲线（用于观察无风扇降频）；
   - 断网状态下的完整请求（确认不访问外网）。
2. 报告中附带环境信息：芯片、内存、macOS 版本、mlx-lm 版本、模型 revision、档位、GPU 上限。
3. 根据结果定稿 `config/profiles/mac-24gb.toml`：`max_context`、`gpu_wired_limit_mb`、`prompt_cache_bytes`、`prefill_step_size`。
4. 更新 `docs/design.md`：把第 2、4、5 节中对应的数字替换为实测值并标注 [实测]，更新第 10 节的风险状态。
5. 把本次报告的 Markdown 版本提交到 `docs/benchmarks/`（只提交报告，不提交原始数据）。
6. 如果 32K 档不达标，按设计第 10 节处理：先降档（24K / 16K），并评估 Q3 自转换版本，把对比数据写进报告。
7. 顺带评估：`Qwen3.8-27B-MTP-4bit` 在当前 mlx-lm 上能否运行、提速多少；结论写进报告，不改默认配置。

不做：Ollama 对比（T07）；其他模型（T09）。

## 验收标准

- [ ] 达标标准（设计第 9 节）：在定稿档位下，用满 `max_context` 的请求连续运行 3 次，推理进程峰值内存不超过 GPU 上限，系统 swap 增量小于 1GB，无报错。
- [ ] `docs/benchmarks/` 中有完整报告，`docs/design.md` 中不再有关于 `mac-24gb` 档位的 [待验证] 数字。
- [ ] `alab bench` 在 CI 中能用小模型跑通一个缩短版本（只验证流程，不看数值）。
- [ ] CI 全部通过。
