# T02 模型注册表与下载

- 依赖：T01
- 对应设计：第 3.2、7.2 节
- 预计规模：中

## 目标

用一个锁定版本、可校验的注册表来管理模型文件，下载结果可复现，离线包（T08）可以直接复用。

## 范围

做：

1. `config/models.toml`，每个条目包含：`id`、`backend`（mlx / ollama）、Hugging Face 仓库名、**commit revision**、文件列表及每个文件的 sha256 和大小、下载所需磁盘空间、说明。首批条目：
   - `qwen3.8-27b-mlx-4bit`：`mlx-community/Qwen3.8-27B-4bit`；
   - 一个用于 CI 的极小 MLX 模型（0.5B 级 4-bit），供 T04/T05 的集成测试使用。
2. `alab pull <model-id>`：
   - 下载到 `var/models/<model-id>/`（通过 `huggingface_hub`，`HF_HOME` 已在 T01 中指向项目内）；
   - 下载前检查磁盘剩余空间，不足时直接报错；
   - 支持断点续传；
   - 下载后逐个校验 sha256，校验失败删除对应文件并报错；
   - 已存在且校验通过时跳过。
3. `alab models`：列出注册表条目及本地状态（未下载 / 已下载 / 校验失败）。
4. 一个维护脚本或子命令（如 `alab models lock <id>`），从 Hugging Face 读取指定 revision 的文件清单和 sha256，生成注册表条目，避免手工填写。

不做：Ollama 模型的下载（T07）；模型转换（如 Q3 自转换，留到 T06 需要时再做）。

## 验收标准

- [ ] `alab pull` 下载 CI 小模型成功并通过校验（CI 中运行）。
- [ ] 修改注册表中某个 sha256 后再次 `alab pull`，能检测出不一致并报错。
- [ ] 下载过程中中断（Ctrl-C），再次执行能继续而不是从头开始。
- [ ] 下载后 `$HOME/.cache/huggingface` 不存在新增内容。
- [ ] 设备测试：在 MacBook Air M5 上下载 `qwen3.8-27b-mlx-4bit`，贴出耗时、占用空间和校验结果。
- [ ] CI 全部通过。

## 备注

- mlx-community 的 4-bit 仓库包含视觉塔权重（约 0.9GB）。本任务仍然完整下载，以便将来支持视觉；纯文本加载时 mlx-lm 会忽略这部分权重，这一点在 T04 中验证。
