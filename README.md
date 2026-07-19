# Agent Lab

Offline-first local AI assistant for Apple Silicon. Agent Lab integrates
maintained third-party components behind pinned configuration: native
[Ollama](https://github.com/ollama/ollama) for inference,
[Open WebUI](https://github.com/open-webui/open-webui) for browser chat and
RAG, [LLM CLI](https://github.com/simonw/llm) for terminal chat, and
[Aider](https://aider.chat/) for repository-aware coding.

It is an integration project, not a new inference platform, web UI, gateway, or
coding agent.

## Quick start

1. Read [installation](docs/installation.md) for hardware, disk budget,
   prerequisites, and the first-run path.
2. From the repository root:

   ```sh
   bin/agent-lab doctor
   bin/agent-lab setup
   bin/agent-lab start --install-launch-agent   # first time only
   bin/agent-lab models pull qwen-9b
   bin/agent-lab health
   ```

3. Open `http://127.0.0.1:3000`, sign in with the credentials in the private
   `.env` file, and send a local chat message.

Full browser, CLI, Aider, RAG, and profile steps are in
[installation](docs/installation.md).

## Documentation

| Document | Contents |
| --- | --- |
| [Installation](docs/installation.md) | Hardware, prerequisites, pinned sources, setup, first chat, CLI clients, RAG, profiles |
| [Operations](docs/operations.md) | Data locations, profiles, model switching, updates, logs, incident procedures |
| [Privacy](docs/privacy.md) | Local/remote trust boundaries, offline proof, search egress |
| [Recovery](docs/recovery.md) | Backup boundaries, restore drills, model and volume recovery |
| [Design](docs/design.md) | Architecture, component ownership, non-goals |
| [MVP qualification](docs/decisions/0010-mvp-qualification.md) | Accepted versions, digests, and acceptance matrix |
| [Implementation status](docs/implementation-status.md) | Continuation handoff for this workstation |

The native Cursor implementation plan lives at
`.cursor/plans/agent-lab-implementation.plan.md` on contributor machines (that
path is local editor metadata and is not required to operate the stack).

## Defaults after qualification

| Role | Alias | Ollama tag |
| --- | --- | --- |
| Chat | `qwen-9b` | `qwen3.5:9b` |
| Fast | `qwen-4b` | `qwen3.5:4b` |
| Coding / vision | `gemma-12b` | `gemma4:12b` |

Ollama listens only on `127.0.0.1:11434` with cloud disabled and at most one
large model loaded. Open WebUI listens on `http://127.0.0.1:3000`. Exact pins
and digests are in `config/components.json` and `config/models.json`.

## Operator commands

```sh
bin/agent-lab doctor             # read-only prerequisites
bin/agent-lab setup              # validate config; create .env and volume
bin/agent-lab start|stop|status|health
bin/agent-lab models list|verify|pull
bin/agent-lab backup|restore
bin/agent-lab offline verify
bin/agent-lab benchmark
```

## License note

Agent Lab's original scripts and configuration are project-owned. Third-party
components and model weights keep their own licenses; see the component and
model catalogs before redistribution.
