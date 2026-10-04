# agent-lab

在 Apple Silicon Mac 上自包含、可打包地部署本地大模型：在 MacBook Air M5 24GB 上用 mlx-lm 运行 Qwen3.8-27B，并通过 `https://api.llmat.dev/v1` 提供 OpenAI 兼容接口，供 Cursor 和 opencode 接入。

- 技术设计：[docs/design.md](docs/design.md)
- 任务卡：[docs/tasks/README.md](docs/tasks/README.md)

当前阶段只有设计文档，代码按任务卡逐个 PR 实现。
