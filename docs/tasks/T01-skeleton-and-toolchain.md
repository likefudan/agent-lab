# T01 项目骨架与隔离工具链

- 依赖：T00
- 对应设计：第 6.1、6.2、8.1、8.2 节
- 预计规模：中

## 目标

建立一个"clone 下来运行一个脚本就能用、并且不在项目目录以外留下任何东西"的 Python 项目骨架，后续所有任务都在它上面加功能。

## 范围

做：

1. `bootstrap.sh`：
   - 下载锁定版本的 uv 和 cloudflared 到 `.tools/bin/`，版本和 sha256 来自 `config/tools.toml`，校验失败立即退出；
   - 用 uv 安装 `.python-version` 指定的 Python 到 `.tools/python`（`UV_PYTHON_INSTALL_DIR`）；
   - `uv sync --frozen` 安装依赖到项目内 `.venv`；
   - 可重复执行：已安装且版本一致时跳过。
2. `.tools/env.sh`（由 bootstrap 生成）：导出 `AGENT_LAB_HOME`、`UV_CACHE_DIR`、`UV_PYTHON_INSTALL_DIR`、`HF_HOME`、`XDG_CACHE_HOME`、`HF_HUB_DISABLE_TELEMETRY=1`，并把 `.tools/bin` 和 `.venv/bin` 加入 `PATH`。
3. 仓库根目录的 `./alab` 包装脚本：自动加载 `env.sh` 后调用 CLI，用户无需修改 shell 配置。
4. `pyproject.toml`、`uv.lock`、`.python-version`；Python 包 `src/agent_lab/`。
5. `agent_lab.paths`：所有路径（`var/models`、`var/logs`、`var/run`、`var/bench`、`var/secrets`、`.tools`）都从 `AGENT_LAB_HOME` 推导，其他模块不得自行拼接路径。创建 `var/secrets` 时权限设为 700。
6. `agent_lab.config`：读取 `config/profiles/*.toml`，做字段校验，给出清晰的错误信息。先放一个 `mac-24gb.toml`，字段按设计第 6.4 节。
7. `alab` CLI 骨架（用 Typer 或 argparse，二选一，在 PR 里说明理由），本任务只实现 `alab version` 和 `alab doctor` 的基础检查：芯片是否 Apple Silicon、物理内存、macOS 版本、`AGENT_LAB_HOME` 所在磁盘的剩余空间、工具链完整性。
8. 更新 `.gitignore`：加入 `.tools/`、`var/`，删除旧设计遗留的 Open WebUI、向量库相关条目。
9. 更新 `README.md`：一句话介绍、快速开始（三条命令）、指向设计文档。
10. GitHub Actions：在 macOS arm64 runner 上运行 lint（ruff）、类型检查（可选）、单元测试和"隔离检查"。

不做：模型下载、启动推理服务、GPU 上限、网关、运行 cloudflared（本任务只负责把它下载并校验好）。

## 验收标准

- [ ] 全新 clone 后执行 `./bootstrap.sh && ./alab doctor` 成功，输出芯片、内存、macOS 版本、磁盘剩余空间。
- [ ] 隔离检查：CI 中把 `HOME` 指向一个新建的空临时目录后运行 bootstrap 和 doctor，结束后该目录仍为空；同时 `git status --porcelain --ignored` 显示所有新文件都位于 `.tools/`、`.venv/` 或 `var/` 之下。
- [ ] 重复执行 `./bootstrap.sh` 不重新下载，耗时明显缩短。
- [ ] 篡改 `config/tools.toml` 中 uv 或 cloudflared 的 sha256 后执行会失败，并给出明确错误。
- [ ] 删除 `.tools/`、`.venv/`、`var/` 后，仓库恢复到 clone 时的状态。
- [ ] 设备测试：在 MacBook Air M5 上运行一次 bootstrap 和 doctor，贴出输出。
- [ ] CI 全部通过。

## 备注

- uv 和 Python 的具体版本号在 PR 中选定，选择时以"当前最新稳定版"为准，写入锁定文件。
- 不依赖系统已有的任何 Python；如果本机已有 Homebrew Python，也不应被使用（doctor 输出解释器路径以便确认）。
