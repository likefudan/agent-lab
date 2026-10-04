# T05 OpenAI 兼容网关（鉴权、限额、工具调用、心跳）

- 依赖：T04
- 对应设计：第 5、6.1、6.3、7.3、7.4、9 节
- 预计规模：大（如果需要网关侧工具调用解析，可拆成 T05a 网关主体和 T05b 工具调用解析两个 PR）

## 目标

提供唯一对外的 `127.0.0.1:8000` 端点：所有请求都要鉴权；防止超长请求把机器推进 swap；兼容 Cursor 和 opencode 的请求方式；在 Cloudflare 的 100 秒限制下保持流式连接。

## 范围

做：

1. ASGI 应用（Starlette + uvicorn + httpx），只实现：
   - `POST /v1/chat/completions`（流式和非流式，含 `tools` / `tool_choice` / `tool_calls`）；
   - `GET /v1/models`（返回 `qwen3.8-27b`）；
   - `GET /healthz`（只返回 `ok` 或 `unavailable`）；
   - 其他路径返回 404。
2. 鉴权：
   - `alab keys create <名称>`：生成 32 字节随机 key，只显示一次，`var/secrets/keys.toml` 只保存哈希；`alab keys list`、`alab keys revoke <名称>`；
   - 所有请求（包括来自 127.0.0.1 的）都必须带有效的 `Authorization: Bearer`，常量时间比较，失败返回 401；
   - key 变更后网关无需重启即可生效（每次请求读取，或监听文件变化）；
   - 没有任何 key 时 `alab serve` 拒绝启动。
3. token 限额：用 mlx-lm 已依赖的 `transformers` tokenizer 按 chat template（含 tools 定义）渲染后计算 prompt token 数，用测试确认与后端渲染一致；
   - prompt 超过 `max_context - min_output_tokens` 时返回 400，`error.code = "context_length_exceeded"`，格式与 OpenAI 一致；
   - 否则把 `max_tokens` 收紧为 `min(请求值, max_output_tokens, max_context - prompt_tokens)` 后转发；同时支持 `max_completion_tokens` 字段。
4. 参数处理：
   - 对外模型名 `qwen3.8-27b`，转发时替换为后端内部名称；请求其他模型名返回 404 风格的 OpenAI 错误；
   - `reasoning_effort`：`none`（默认）/ `low` / `medium` / `high`，转换为 mlx-lm 的 `chat_template_kwargs`，具体参数名对照模型的 chat template 实测确认；
   - 客户端未指定采样参数时，按思考/非思考两套推荐值补上；
   - 图像内容返回 400，说明 v1 不支持。
5. 工具调用：
   - 如果 T04 结论是 mlx-lm 解析可靠：原样透传，只加测试；
   - 如果不可靠：网关以"纯文本生成"方式调用后端，自己把模型输出中的工具调用块转换为 OpenAI 格式（非流式为完整 `tool_calls`，流式为 `delta.tool_calls` 增量，`finish_reason` 为 `tool_calls`）。用一组固定的模型输出样例做单元测试，覆盖多个工具调用、参数含换行和引号、参数为嵌套 JSON、输出被截断等情况。
6. 并发与心跳：
   - 一次只转发一个请求；排队上限取 `queue_size`，超出返回 429；
   - 流式请求立即返回响应头（`Content-Type: text/event-stream`、`Cache-Control: no-cache`），排队和 prefill 期间每 `heartbeat_seconds` 秒发送一次 `: keep-alive` 注释行；
   - 客户端断开时取消后端请求、释放队列位置。
7. 日志：只记录时间、key 名称、prompt/输出 token 数、排队时间、耗时、状态码，不记录正文。
8. `alab serve` 改为先启动后端、健康后再启动网关；`stop`、`status` 同时管理两者；`status` 显示队列长度。

不做：tunnel（T07）；对话存储；多模型路由；`/v1/completions`、embeddings、Responses API。

## 验收标准

- [ ] 单元测试（使用假后端）：无 key / 错误 key / 已吊销 key 返回 401；来自 127.0.0.1 的请求同样需要 key；超长 prompt 返回 `context_length_exceeded`；`max_tokens=32000` 被收紧而不是拒绝；`reasoning_effort` 转换；默认采样参数；队列满返回 429；流式心跳在后端迟迟不响应时按间隔发出；客户端断开后后端请求被取消。
- [ ] 如实现了网关侧工具调用解析：解析样例测试全部通过。
- [ ] CI 集成测试：小模型 + 网关，用官方 `openai` Python SDK 完成普通请求、流式请求和一次带 `tools` 的请求。
- [ ] 超过 `max_context` 的请求在网关被拒绝，后端没有收到该请求（检查后端日志）。
- [ ] 设备测试：27B 模型下，带一个简单工具（如 `get_weather`）发起流式请求，贴出返回的 `tool_calls`；分别以 `reasoning_effort=none` 和 `low` 发送同一个问题，贴出输出 token 数和耗时。
- [ ] CI 全部通过。
