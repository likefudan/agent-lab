# T05 OpenAI 兼容网关

- 依赖：T04
- 对应设计：第 5、6.1、6.3、8 节
- 预计规模：中到大

## 目标

提供唯一对外的 `127.0.0.1:8000` 端点：统一接口契约、防止超长请求把机器推进 swap、统一思考开关和默认参数。

## 范围

做：

1. ASGI 应用（Starlette + uvicorn + httpx），实现：
   - `POST /v1/chat/completions`（含流式 SSE 透传）、`POST /v1/completions`、`GET /v1/models`；
   - `GET /healthz`：网关状态、后端状态、当前档位、`max_context`。
2. token 限额：用模型目录里的 tokenizer 和 chat template 渲染后计算 prompt token 数（使用 mlx-lm 已经依赖的 `transformers` tokenizer，不额外引入依赖；渲染结果必须与后端一致，用测试对比）；`prompt_tokens + max_tokens > max_context` 时返回 400 和清晰的错误信息；未指定 `max_tokens` 时按设计第 6.3 节的规则补上。
3. 参数处理：
   - 对外模型名固定为 `qwen3.8-27b`，转发时替换为后端内部名称；
   - `reasoning_effort`：`none`（默认）/ `low` / `medium` / `high`，转换为 mlx 后端的 `chat_template_kwargs`；具体的 chat template 参数名在本任务中对照模型的 chat template 实测确认；
   - 客户端未指定采样参数时，按思考/非思考两套推荐值补上。
4. 并发：一次只转发一个请求；排队上限取档位 `queue_size`，超出返回 429；客户端断开时取消后端请求。
5. 安全：默认只监听 `127.0.0.1`；监听其他地址时必须配置 API key（从环境变量读取，不写进配置文件），否则拒绝启动；日志只记录 token 数、耗时、状态码。
6. `alab serve` 改为先启动后端、健康后再启动网关；`stop` 和 `status` 同时管理两者。

不做：对话存储、多模型路由、视觉输入（遇到图像内容返回 400 并说明 v1 不支持）。

## 验收标准

- [ ] 单元测试（使用假后端）：限额判断、`max_tokens` 补全、`reasoning_effort` 转换、默认采样参数、队列满返回 429、非本机地址无 API key 时拒绝启动。
- [ ] CI 集成测试：小模型 + 网关，用官方 `openai` Python SDK 完成普通请求和流式请求。
- [ ] 超过 `max_context` 的请求在网关被拒绝，后端没有收到该请求（检查后端日志）。
- [ ] 设备测试：27B 模型下，分别以 `reasoning_effort=none` 和 `low` 发送同一个问题，贴出输出 token 数和耗时，确认 `none` 时没有思考内容。
- [ ] CI 全部通过。
