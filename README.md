# agent-lab

A self-contained, packable setup for running local LLMs on Apple Silicon: Qwen3.8-27B on a MacBook Air M5 (24GB) with mlx-lm, served as an OpenAI-compatible API at `https://api.llmat.dev/v1` for Cursor and opencode.

## Quick start

```sh
git clone https://github.com/likefudan/agent-lab.git && cd agent-lab
./bootstrap.sh     # installs uv, cloudflared, Python and dependencies inside this directory
./alab doctor      # checks the chip, memory, macOS version, disk space and toolchain
```

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
tests/acceptance.sh   # fresh-clone, isolation and checksum checks on the current commit
```
