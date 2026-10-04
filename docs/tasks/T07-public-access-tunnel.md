# T07 公网访问：api.llmat.dev（Cloudflare Tunnel）

- 依赖：T05（建议在 T06 之后，确认档位稳定再对外）
- 对应设计：第 6.5、7.1、7.2、7.3、7.5、8.1、9 节
- 预计规模：中

## 目标

让 `https://api.llmat.dev/v1` 可以从公网访问到本机网关，不开放任何入站端口，不在项目目录以外留下文件，不注册系统服务。

## 范围

做：

1. 一次性人工步骤的说明文档 `docs/setup-cloudflare.md`（需要你本人在 Cloudflare 后台操作）：
   - 在 Zero Trust 后台创建 tunnel `agent-lab`；
   - 添加 Public Hostname：`api.llmat.dev` → `http://127.0.0.1:8000`；
   - 对 `api.llmat.dev` 添加 Cache Rule（bypass cache）；
   - 添加一条 WAF 限流规则（阈值在本任务中根据 T06 的实际吞吐确定，明显高于正常用量）；
   - 确认该子域名没有启用会弹出验证页面的 Bot 防护功能；
   - 复制 tunnel token。
2. `alab tunnel set-token`：从标准输入读取 token（不回显），保存到 `var/secrets/tunnel-token`（权限 600）。
3. `alab serve` 在网关健康后启动 `cloudflared tunnel run`：
   - 使用 T01 下载到 `.tools/bin/` 的锁定版本；
   - token 通过环境变量 `TUNNEL_TOKEN` 传入，不出现在命令行参数中；
   - 设置 cloudflared 的日志和配置路径到 `var/` 下，确保不读写 `~/.cloudflared`；
   - 关闭 cloudflared 的自动更新；
   - 支持 `--no-tunnel` 只在本机提供服务。
4. 阻止睡眠：`alab serve` 运行期间以子进程运行 `caffeinate -i`，`stop` 时一起结束。
5. `alab status` 显示 tunnel 连接状态；`alab tunnel check` 从公网（经 Cloudflare）请求 `https://api.llmat.dev/healthz` 和一次带 key 的 `/v1/models`，报告结果。
6. `doctor` 增加检查：cloudflared 二进制完整性、token 是否已设置、`api.llmat.dev` 能否解析。
7. 心跳验证：用一个人为延迟 150 秒才开始输出的请求（测试模式下的假后端或长 prompt），确认经过 Cloudflare 后流式连接不断开。

不做：客户端配置（T08）；自动创建 tunnel 或 DNS 记录（需要额外的 Cloudflare API 凭据，收益不大）。

## 验收标准

- [ ] 隔离检查：整个过程 `~/.cloudflared` 没有被创建或修改；`launchctl list` 中没有新增服务；`ps` 输出中看不到 tunnel token。
- [ ] 设备测试：`alab serve` 后，从另一台设备（例如手机网络下的电脑）用 curl 访问 `https://api.llmat.dev/v1/models`：不带 key 返回 401，带 key 返回 `qwen3.8-27b`。
- [ ] 设备测试：经 `api.llmat.dev` 发送一次流式请求，首 token 前等待超过 100 秒也不断开（贴出时间戳）。
- [ ] 设备测试：`alab stop` 后，公网请求得到 Cloudflare 的错误页，本机 8000/8100 端口已释放，cloudflared 和 caffeinate 进程已退出。
- [ ] 单元测试：token 读写权限、命令行参数中不含 token、`--no-tunnel` 行为。
- [ ] CI 全部通过（CI 中不连接真实 tunnel）。
