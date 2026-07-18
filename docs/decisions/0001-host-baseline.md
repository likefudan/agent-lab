# 0001 — Target host baseline

- **Status:** Recorded
- **Captured:** 2026-07-18T11:28:03Z
- **Scope:** Read-only inventory of the initial Agent Lab host

## Decision

Use this machine as the initial qualification host. It matches the design's
Apple Silicon and unified-memory targets, but it is not ready to run the MVP:
Ollama is not installed, and Docker Desktop's engine is not running. Later
tasks must install or qualify their own tools rather than infer availability
from the design.

This record intentionally omits the hostname, username, serial number, hardware
UUIDs, tokens, and unrelated process details. `${HOME}` denotes the current
user's home directory.

## Hardware and operating system

| Property | Observed value | Evidence |
| --- | --- | --- |
| Computer | MacBook Air with Apple M5 | `system_profiler SPHardwareDataType` |
| Architecture | `arm64` | `uname -m` |
| CPU cores | 10 physical, 10 logical; 4 performance and 6 efficiency cores | `sysctl` and `system_profiler` |
| GPU cores | 10; Metal supported | `system_profiler SPDisplaysDataType` |
| Unified memory | 24 GiB (`25,769,803,776` bytes) | `sysctl -n hw.memsize` |
| macOS | 26.5.2, build `25F84` | `sw_vers` |
| Darwin kernel | 25.5.0 | `uname -a` (hostname omitted) |
| Login shell | `/bin/zsh`; zsh 5.9 arm64 | `$SHELL`, `/bin/zsh --version` |
| Data-volume disk space | 926 GiB total, 272 GiB used, 629 GiB available | `df -h /System/Volumes/Data` |

The available disk figure is a point-in-time value, not a reserved model
budget. Model qualification must measure space before and after each pull.

## Installed software

| Tool | Version | Resolved location | State / owner |
| --- | --- | --- | --- |
| Git | 2.55.0 | `/opt/homebrew/bin/git` | Installed, arm64 |
| Homebrew | 6.0.11 | `/opt/homebrew/bin/brew` | Installed |
| Docker CLI | 29.6.1 (`8900f1d330`) | `/opt/homebrew/bin/docker` | Installed, arm64 |
| Docker Compose | 5.3.0 | Docker CLI plug-in | Installed |
| Docker Desktop | 4.80.0 (build `232116`) | `/Applications/Docker.app` | Application UI/helper processes running; engine unavailable |
| Ollama | missing | — | Must be installed and qualified by P0-T02 |
| `jq` | 1.7.1-apple | `/usr/bin/jq` | Installed, universal binary |
| `curl` | 8.7.1 | `/usr/bin/curl` | Installed, universal binary |
| Node.js | missing | — | Later evaluation prerequisite |
| npm | missing | — | Later evaluation prerequisite |
| LLM CLI | missing | — | Installed/configured by P4-T01 |
| Aider | missing | — | Installed/configured by P4-T02 |
| Promptfoo | missing | — | Installed/configured by P8-T01 |
| Colima | missing | — | Not required while Docker Desktop is selected |
| Podman | missing | — | Not required while Docker Desktop is selected |

`docker info` and `docker ps` both reported that they could not connect to the
Docker Desktop socket. Docker Desktop frontend/helper processes and its socket
exist, but those do not constitute a running container engine. No containers
were inspected because the engine was unavailable.

## Services and ports

| Check | Result |
| --- | --- |
| Ollama process/API | Not running; no Ollama executable is installed and `http://127.0.0.1:11434/api/version` refused the connection |
| TCP `11434` listener | None |
| Container engine | Stopped or otherwise unavailable through the selected `desktop-linux` Docker context |
| Provisional Open WebUI TCP port `3000` | No listener; loopback HTTP probe refused the connection |

Port `3000` is only a provisional collision check. P0-T04 owns selection of the
actual loopback host port and must check that selected port again immediately
before starting Open WebUI.

## Existing local model artifacts

### Ollama

`ollama list` could not run because `ollama` is missing. `${HOME}/.ollama` and
the default Ollama manifest tree do not exist. `OLLAMA_MODELS` is unset. There
are therefore no discoverable default-store Ollama tags on this host; this does
not rule out an unreferenced store at an unknown custom location.

### Hugging Face Hub

The default `${HOME}/.cache/huggingface` cache exists and uses approximately
13 GiB. Three MLX-community repositories have a cached `main` revision:

| Repository | Cached revision | Approximate cache size |
| --- | --- | --- |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | `c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed` | 4.0 GiB |
| `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | `019cc73c45c770444708a6dd8690c66243cc5c80` | 4.0 GiB |
| `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` | `fdcc572e8b05ba9daeaf71be8c9e4267c826ff9b` | 5.3 GiB |

Each revision also has a matching snapshot directory. `HF_HOME`,
`HUGGINGFACE_HUB_CACHE`, and `TRANSFORMERS_CACHE` are unset, and no cache was
found at `${HOME}/Library/Caches/huggingface`. These files belong to the user:
Agent Lab must not move, delete, or assume it can reuse them for Ollama.

## Prerequisite classification

### Required before the MVP can run

- Apple Silicon macOS, sufficient unified memory, and free disk: present.
- Ollama native runtime: **missing**; P0-T02 must install/select and verify the
  exact release before any model automation.
- Compatible container runtime for Open WebUI: Docker Desktop and its CLI are
  present, but the engine is **not running**. P0-T04/P3 work must start it and
  verify `docker info` succeeds.
- `curl` and `jq` for API and configuration checks: present.

### Bootstrap and development tools

- Git and Homebrew are present. They support setup and development but are not
  runtime services.

### Intentionally deferred tool installation

- LLM CLI and Aider remain absent until their P4 integration tasks.
- Node.js/npm and Promptfoo remain absent until evaluation work requires them.
- Colima and Podman are not prerequisites for the selected Docker Desktop path.

## Reproduction procedure

Run these read-only checks from a normal macOS terminal. Record command
failures as results; do not install, start, download, move, or delete anything
while refreshing this baseline.

```sh
sw_vers
uname -m
sysctl -n machdep.cpu.brand_string hw.physicalcpu hw.logicalcpu hw.memsize
system_profiler SPHardwareDataType SPDisplaysDataType
/bin/zsh --version
df -h /System/Volumes/Data

command -v git brew docker ollama jq curl node npm llm aider promptfoo
git --version
brew --version
docker --version
docker compose version
docker info
docker ps
ollama --version
ollama list
jq --version
curl --version
node --version
npm --version
llm --version
aider --version
promptfoo --version

lsof -nP -iTCP:11434 -sTCP:LISTEN
lsof -nP -iTCP:3000 -sTCP:LISTEN
curl --silent --show-error --max-time 2 http://127.0.0.1:11434/api/version
curl --silent --show-error --max-time 2 http://127.0.0.1:3000/

du -sh "${HOME}/.ollama" "${HOME}/.cache/huggingface"
find "${HOME}/.ollama/models/manifests" -type f
find "${HOME}/.cache/huggingface/hub" -maxdepth 1 -type d -name 'models--*'
```

Before publishing refreshed output, replace home-directory prefixes with
`${HOME}` and remove hostnames, usernames, serial numbers, UUIDs, tokens, and
unrelated process command lines.

## Consequences and follow-up gates

- P0-T02 cannot assume Ollama exists or that an advertised acceleration path
  works; it must establish both from an installed, pinned release.
- P0-T03 starts with no Ollama tags. Existing Hugging Face MLX snapshots are
  separate artifacts and are outside the MVP inference path.
- P0-T04 cannot assume Docker is healthy merely because Docker Desktop is open.
- Tasks using LLM CLI, Aider, Node/npm, or Promptfoo must install and pin them
  before running their acceptance tests.
- Any later task that needs a port other than `11434` must select and recheck it;
  only provisional port `3000` was inspected here.
