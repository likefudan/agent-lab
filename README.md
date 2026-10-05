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
./alab serve       # starts mlx-lm on 127.0.0.1:8100 and waits until the model is loaded
./alab status      # pid, port, memory (RSS), load time and log path
./alab stop        # SIGTERM, then SIGKILL if it does not exit
```

`alab serve` refuses to start if the model is not downloaded, port 8100 is taken, or the GPU limit is below what the profile needs (`--force` starts anyway). Running it again while the backend runs starts nothing. The backend runs in the background with thinking off and the profile's sampling defaults; it logs to `var/logs/backend.log` (rotated daily, no request bodies). If MLX uses more memory than the profile's `metal_memory_limit`, the backend stops itself and `alab status` shows why. In this version nothing checks API keys: the backend only listens on 127.0.0.1, and the authenticated gateway comes next (T05).

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
.venv/bin/python tests/tool_call_check.py   # tool calls, thinking and speed against a running backend
```

Registry entries are generated, not typed: `./alab models lock <id> --repo <owner/name> --write` pins the repository's current commit and records every file's size and sha256.
