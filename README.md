# Agent Lab

Agent Lab is an offline-first AI workspace for an Apple Silicon Mac. It combines
native [MLX-LM](https://github.com/ml-explore/mlx-lm),
[MLX-VLM](https://github.com/Blaizzy/mlx-vlm),
[Ollama](https://github.com/ollama/ollama), the upstream
[Open WebUI](https://github.com/open-webui/open-webui),
[LLM CLI](https://llm.datasette.io/), and
[Aider](https://github.com/Aider-AI/aider) behind pinned, tested local
configuration. It supports browser and terminal chat, coding assistance, image
understanding, retrieval over local documents, and optional web search.

The MVP is qualified on an M5 MacBook Air with 24 GB unified memory. Model
inference stays on the Mac and no hosted-model fallback is configured. Optional
web search is the one intentional path that sends queries to third parties.

## What is included

| Role | Local component |
| --- | --- |
| Web chat, history, RAG, citations, and optional search | Open WebUI `0.10.2` |
| Primary native text inference | MLX-LM `0.31.3` with Qwen 3.5 9B 4-bit |
| Primary native multimodal inference | MLX-VLM `0.6.6` with Gemma 4 12B IT 4-bit |
| Stable fallback and Ollama model storage | Ollama `0.32.1` |
| Default chat | `qwen3.5:9b` (`qwen-9b`) |
| Fast chat | `qwen3.5:4b` (`qwen-4b`) |
| Coding and image understanding | `gemma4:12b` (`gemma-12b`) |
| General terminal chat | LLM CLI with `llm-ollama` |
| Repository-aware coding | Aider |

Only one chat model is kept resident at a time to protect the 24 GB memory
budget. Qwen is not advertised for vision because the approved artifacts did
not pass the fixed OCR acceptance case; Gemma did.

## Quick start

This snapshot requires Apple Silicon macOS, Docker Desktop, and the exact
pinned Ollama executable. Read the [installation guide](docs/installation.md)
before installing or changing host software.

```sh
bin/agent-lab doctor
bin/agent-lab setup
bin/agent-lab start --install-launch-agent

# Online, one download at a time; each artifact is verified after download.
bin/agent-lab models pull qwen-4b
bin/agent-lab models pull qwen-9b
bin/agent-lab models pull gemma-12b

# Native MLX backends and revision-pinned Hugging Face snapshots.
bin/agent-lab mlx setup
bin/agent-lab mlx models download qwen-9b-mlx
bin/agent-lab mlx models download gemma-12b-mlx
bin/agent-lab mlx models verify
bin/agent-lab mlx start chat

config/open-webui/apply-rag-config.sh
config/open-webui/apply-chat-config.sh
config/open-webui/apply-task-config.sh
config/open-webui/apply-mlx-config.sh
config/open-webui/apply-profile.sh online-manual
bin/agent-lab health
```

Open <http://127.0.0.1:3000> and sign in with the local administrator values in
the ignored `.env` file. `setup` creates that file with a random password and
secret and preserves it on later runs. For terminal clients, follow the pinned
[LLM CLI and Aider setup](docs/installation.md#terminal-clients).

Routine commands are deliberately small:

```sh
bin/agent-lab start
bin/agent-lab status
bin/agent-lab health
bin/agent-lab stop

# Switch between the mutually exclusive MLX text and vision services.
bin/agent-lab mlx start chat
bin/agent-lab mlx start vision
bin/agent-lab mlx status
```

## Online and offline modes

- `online-manual` is the default. DuckDuckGo search runs only after the user
  explicitly chooses search.
- `online-automatic` lets the local model decide when to invoke search.
- `offline` disables search, update checks, downloads, and remote tools. Core
  workflows use only cached local artifacts.

Apply a mode with `config/open-webui/apply-profile.sh PROFILE`. Changing a mode
recreates only the Open WebUI container and preserves its named data volume.

The offline configuration, full local workflow matrix, and strict
operator-confirmed boundary run pass on the qualified host. The strict result
combines the operator's physical/LuLu boundary attestation with an in-container
local preflight and failed external probe; Agent Lab does not independently
inspect firewall rules. See [privacy and network boundaries](docs/privacy.md)
for the verification protocol and the precise scope of this claim.

## Data and safety

Open WebUI chats, uploads, vectors, accounts, and settings live in the Docker
volume `agent-lab-open-webui-data`. Ollama weights live in `~/.ollama/models`.
Pinned MLX weights live in `~/.cache/huggingface/hub`.
Private configuration, client state, results, and logs live in the ignored
`.env`, `.agent-lab/`, and `~/.agent-lab/` paths described in the
[privacy guide](docs/privacy.md#local-data-locations).

Never use `docker compose down --volumes` for routine operation. Backups contain
private conversations, documents, password hashes, and secrets; protect them
like credentials. See [backup and recovery](docs/recovery.md).

## Documentation

- [Installation and first run](docs/installation.md)
- [Operations and troubleshooting](docs/operations.md)
- [Privacy, profiles, and the offline boundary](docs/privacy.md)
- [Backup and recovery](docs/recovery.md)
- [Architecture and component ownership](docs/design.md)
- [Evaluation and benchmarks](evals/README.md)
- [Implementation status](docs/implementation-status.md)

## Known limitations

- Strict zero-egress acceptance remains operator-controlled. The qualified run
  passed, but its boundary is attested by the operator rather than independently
  inspected by Agent Lab.
- The MVP supports Apple Silicon macOS only and is qualified specifically on a
  24 GB M5 host with the pinned component versions.
- Only Gemma is approved for image input. Scanned-PDF OCR is not included.
- Web search sends the query and fetched public content to third parties and is
  unavailable offline.
- Open WebUI, LLM CLI, and Aider have separate histories; CLI clients do not
  share Open WebUI knowledge collections.
- MLX-LM and MLX-VLM are limited to the two revision-pinned, file-verified
  snapshots. Only one MLX backend is active at a time; arbitrary Hugging Face
  models are not exposed.

Agent Lab is integration and policy code, not a new UI, inference engine, RAG
engine, or coding agent. The exact third-party/original boundary and license
notes are documented in [the design](docs/design.md#component-ownership).
