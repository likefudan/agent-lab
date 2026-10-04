# T04 mlx-lm 后端与进程管理

- 依赖：T02、T03
- 对应设计：第 3.3、5、6.1、6.4、6.5、7.4 节
- 预计规模：中

## 目标

用一条命令在本机启动、停止和查看 mlx-lm 推理服务；确认 Qwen3.8-27B 能在锁定版本的 mlx-lm 上以纯文本方式运行，并且**工具调用能被正确解析**。

## 范围

做：

1. **第一步，先验证再写代码**，结论写进 PR 描述：
   - Qwen3.8-27B 在 mlx-lm 中的支持情况（`config.json` 中的 `model_type`、最低 mlx-lm 版本），在 `pyproject.toml` 中锁定版本；
   - 工具调用：显式指定 `qwen3_coder` 解析器（CLI 参数，或在本地模型目录的 `tokenizer_config.json` 中设置 `tool_parser_type`）后，分别用非流式和流式请求测试，返回的 `tool_calls` 是否正确（函数名、参数 JSON、多个工具调用、参数中含换行和引号）。
   - 如果模型本身不受支持，停止本任务并在 PR 中说明，按设计第 11 节调整计划。如果只是工具调用解析不可靠，继续本任务，并在 PR 中明确写出"T05 需要实现网关侧解析"。
2. 启动包装 `agent_lab.backend.launch`：先设置 Metal 内存上限（`mx.set_memory_limit()` 或当前 mlx 的同等接口，取档位的 `metal_memory_limit`），再在同一进程内启动 `mlx_lm.server`。参数全部来自档位：
   - 模型路径指向 `var/models/<id>`；
   - 只监听 `127.0.0.1`，端口 8100；
   - `--decode-concurrency 1`、`--prompt-concurrency 1`；
   - `--prefill-step-size`、`--prompt-cache-size`、`--prompt-cache-bytes` 取档位值；
   - `--chat-template-args '{"enable_thinking": false}'` 作为默认；
   - 采样参数默认值使用模型卡的非思考推荐值；
   - 设置 `HF_HUB_OFFLINE=1`。
3. 进程管理：pid 写入 `var/run/`，日志写入 `var/logs/`（按天滚动，不记录请求正文）；启动后轮询健康检查，超时则停止进程并报错；`stop` 先发 SIGTERM，超时再 SIGKILL；`status` 显示 pid、端口、内存占用（RSS）和日志路径。
4. 启动前调用 T03 的检查：GPU 上限不满足档位要求时拒绝启动（可用 `--force` 跳过，并打印警告）。
5. 本任务里 `alab serve` 只启动后端；T05 加入网关后，`serve` 再改为同时启动两者。

不做：网关、鉴权、token 限额（T05）；tunnel（T07）；基准测试（T06）。

## 验收标准

- [ ] CI 集成测试：用 T02 的小模型完成 `serve` → 发送一条对话请求 → `status` → `stop`，并确认进程已退出、端口已释放。
- [ ] 重复 `serve` 时检测到已在运行，不会启动第二个进程。
- [ ] 后端进程意外退出后，`status` 能报告异常并给出日志路径。
- [ ] 超过 Metal 内存上限时，后端进程报错退出或返回错误，而不是让系统 panic（用小模型和很低的上限在 CI 中验证）。
- [ ] 设备测试：在 MacBook Air M5 上应用 GPU 上限后，用 27B 模型完成一次短对话，贴出：mlx-lm 版本、加载耗时、RSS 内存、一次约 200 token 回答的生成速度；确认默认不输出思考内容。
- [ ] 设备测试：确认纯文本加载时视觉塔权重没有被加载（对比 RSS 或日志）。
- [ ] 设备测试：第 1 步工具调用验证的完整请求和响应样例贴在 PR 中。
- [ ] CI 全部通过。
