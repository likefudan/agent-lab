# agent-lab

A self-contained, packable setup for running local LLMs on Apple Silicon: Qwen3.8-27B on a MacBook Air M5 (24GB) with mlx-lm, served as an OpenAI-compatible API at `https://api.llmat.dev/v1` for Cursor and opencode.

## Quick start

```sh
git clone https://github.com/likefudan/agent-lab.git && cd agent-lab
./bootstrap.sh     # installs uv, cloudflared, Python and dependencies inside this directory
./alab doctor      # checks the chip, memory, GPU limit, ports, disk space and toolchain
./alab pull        # downloads and verifies Qwen3.8-27B (about 16GB) into var/models/
```

`alab pull` resumes where it stopped if interrupted (Ctrl-C or a dropped connection); run it again. `alab models` lists the models in [`config/models.toml`](config/models.toml) and whether each is downloaded and verified.

### GPU memory limit

macOS only lets the GPU wire part of unified memory, which is too little for the 27B model. `./alab gpu-limit show` prints the current limit and what the profile needs. `./alab gpu-limit apply` raises it to the profile's `gpu_wired_limit_mb` with `sudo sysctl iogpu.wired_limit_mb=<value>`, after showing the exact command and asking for confirmation; it never goes above physical memory minus 3GB. The change lasts until reboot, and `./alab gpu-limit revert` restores the system default now. This is the only change agent-lab makes outside its directory.

### Running the model

```sh
./alab keys create opencode   # an API key for one client; shown once, only its hash is stored
./alab serve                  # starts mlx-lm on 127.0.0.1:8100, then the gateway on 127.0.0.1:8000
./alab status                 # both processes: pid, port, memory, queue and log paths
./alab stop                   # stops the gateway, then the backend
```

Clients use `http://127.0.0.1:8000/v1` with the model name `qwen3.8-27b` and `Authorization: Bearer <key>`; every request needs a key, including from this machine. `./alab keys list` shows the key names and `./alab keys revoke <name>` disables one at once, without a restart.

`alab serve` refuses to start without an API key, if the model is not downloaded, if port 8100 or 8000 is taken, or if the GPU limit is below what the profile needs (`--force` starts anyway). Running it again while both run starts nothing. The backend runs in the background with thinking off and the profile's sampling defaults; if MLX uses more memory than the profile's `metal_memory_limit`, it stops itself and `alab status` shows why.

The gateway (design section 6.3) is the only endpoint clients talk to. It counts every prompt with the model's own tokenizer and chat template and refuses one that leaves less than `min_output_tokens` of the context (`context_length_exceeded`); otherwise it lowers `max_tokens` to what fits. It forwards one request at a time, keeps up to `queue_size` waiting and answers 429 beyond that. Streaming responses start at once and carry a `: keep-alive` comment every `heartbeat_seconds` while the request waits or the prompt is processed. `reasoning_effort` (`none`, `low`, `medium`, `high`) turns thinking on per request. A client that disconnects stops its request. Logs: `var/logs/gateway.log` (one line per request with the key name, token counts and times) and `var/logs/backend.log`; neither contains request or response bodies.

`./alab bench` measures the running service through the gateway with a temporary key (revoked afterwards): prompt cache reuse, prefill and time to first token from 1K to 32K tokens, decode speed, agent conversations that fill `max_context` (with the design's pass criteria), a 10-minute sustained run and an offline request. It takes about an hour on the 24GB Mac; `--only agent,offline` runs some sections, `--quick` is the short CI version. Reports go to `var/bench/<time>/report.md` and `report.json`; measured results are in [docs/benchmarks/](docs/benchmarks/).

Everything is installed under `.tools/`, `.venv/` and `var/` in this directory; nothing is written to your home directory or shell configuration. To uninstall, delete the directory. Use `./alab` (or `source .tools/env.sh` in a shell) to run commands with the project's own environment.

## Documentation

- Design: [docs/design.md](docs/design.md)
- Task cards: [docs/tasks/README.md](docs/tasks/README.md)

## Development

```sh
. .tools/env.sh
uv run --frozen ruff check . && uv run --frozen ruff format --check .
uv run --frozen mypy
uv run --frozen pytest
tests/acceptance.sh          # fresh-clone, isolation and checksum checks on the current commit
tests/models_acceptance.sh   # downloads the CI model: resume, verification and isolation checks
tests/backend_acceptance.sh  # serves the CI model: serve, status, stop, crash and memory limit
tests/gateway_acceptance.sh  # the CI model behind the gateway, through the openai SDK
tests/bench_acceptance.sh    # a quick alab bench with the CI model (the flow, not the numbers)
.venv/bin/python tests/tool_call_check.py --url http://127.0.0.1:8000 --api-key <key> --model qwen3.8-27b
                             # tool calls, thinking and speed through the gateway
```

Registry entries are generated, not typed: `./alab models lock <id> --repo <owner/name> --write` pins the repository's current commit and records every file's size and sha256.
