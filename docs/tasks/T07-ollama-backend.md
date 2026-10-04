# T07 Ollama 备选后端与后端对比

- 依赖：T06
- 对应设计：第 3.3、4.2、7.1 节
- 预计规模：中

## 目标

提供与 mlx-lm 并列、可通过档位切换的 Ollama 后端，它不能影响本机可能已经安装的 Ollama；并用 T06 的基准工具对比两个后端，决定默认后端。

## 范围

做：

1. 在 `config` 中锁定 Ollama 版本（不低于 v0.32.12）及其官方 macOS 发布包的下载地址和 sha256；bootstrap 增加可选步骤 `./bootstrap.sh --with-ollama`，把二进制下载到 `.tools/ollama/`，不安装 Ollama.app、不注册后台服务。先确认官方发布包中有可以独立运行的命令行二进制，没有的话在 PR 中说明替代方案。
2. `OllamaBackend`：实现 T04 定义的 `Backend` 接口，以子进程运行 `ollama serve`：
   - `OLLAMA_HOST=127.0.0.1:8200`、`OLLAMA_MODELS=var/ollama/models`；
   - 关闭自动更新和遥测相关选项（如有）；
   - 使用项目内的 Modelfile 生成带 `num_ctx`、采样参数、关闭思考的本地模型别名，因为 Ollama 的 OpenAI 兼容接口会忽略请求里的 context 长度。
3. 模型：在 `config/models.toml` 中加入 `qwen3.8:27b-mlx` 和 `qwen3.8:27b`（q4_K_M），通过项目内的 Ollama 拉取，记录 digest 用于校验。
4. 档位 `config/profiles/mac-24gb-ollama.toml`，初始 `max_context = 16384`。
5. 网关的 `reasoning_effort` 转换增加 Ollama 分支。
6. 用 `alab bench` 对比：mlx-lm（`mac-24gb`）、Ollama MLX 引擎、Ollama GGUF 三者在相同 context 下的速度和内存；测试 `OLLAMA_KV_CACHE_TYPE=q8_0` 在两种引擎下是否生效、能否在不超预算的前提下开到 32K。
7. 根据对比结果，在 `docs/design.md` 第 3.3 节写明默认后端的最终结论；如需切换默认后端，在本 PR 中修改档位。

不做：视觉输入（另开设计）。

## 验收标准

- [ ] 本机已安装的 Ollama（如果有）在本任务全过程中不受影响：它的端口、模型目录、配置文件都没有变化。
- [ ] 隔离检查：`$HOME/.ollama` 没有被创建或修改。
- [ ] CI 集成测试：用一个很小的 Ollama 模型完成 serve → 请求 → stop（如 CI 环境限制无法运行，在 PR 中说明并改为设备测试）。
- [ ] 设备测试：对比报告提交到 `docs/benchmarks/`。
- [ ] CI 全部通过。
