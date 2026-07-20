# Privacy and network boundaries

Agent Lab is offline-first: after required software and model weights are
downloaded, core chat, coding, vision, and local RAG must work without the
internet. This document states where private data lives, what may leave the
machine, and how to prove offline behavior.

Architecture and non-goals are in [design](design.md). Day-to-day commands are
in [operations](operations.md). Backup contents are in [recovery](recovery.md).

## Local trust boundary

In normal operation these stay on this Mac:

| Category | Store |
| --- | --- |
| Prompts, chats, uploads, vectors, Open WebUI settings | Docker volume `agent-lab-open-webui-data` |
| Approved model weights and manifests | `~/.ollama/models` |
| Optional MLX / HF weights | `~/.cache/huggingface` (or `$HF_HOME`) |
| Active backend + inference env | `~/.agent-lab/state/` |
| Admin password and `WEBUI_SECRET_KEY` | ignored repository `.env` (mode `0600`) |
| LLM CLI history (if enabled) | ignored `.agent-lab/llm/` |
| Aider conversation history | ignored per-repo `.agent-lab/aider/` |
| Inference | Active loopback backend (default Ollama `127.0.0.1:11434`; optional mlx / LM Studio / llama.cpp per [decision 0011](decisions/0011-inference-backends.md)) |

Ollama is loopback-only with cloud integration disabled
(`OLLAMA_NO_CLOUD=1`). Optional backends also bind IPv4 loopback only. Open
WebUI publishes only on `127.0.0.1:3000`. No hosted model provider is configured
in the catalogs or Compose file.

Treat the Mac login session, disk encryption, and backup destinations as part
of the trust boundary. Anyone who can read `.env` or a backup archive can
impersonate the local WebUI admin and read chat history.

## Remote trust boundary

Outbound contact is intentional and limited:

| Activity | When | What can leave |
| --- | --- | --- |
| Homebrew / Docker / Ollama pulls | Explicit online install or maintenance | Package and model bytes from registries |
| Hugging Face Hub (MLX weights) | Explicit online install or weight refresh | Model bytes + Hub metadata for pinned revisions |
| LM Studio registry / catalog | Explicit app install or in-app download | Model bytes via LM Studio (outside Agent Lab) |
| Embedding-cache first populate | Online until the pinned snapshot exists | Hugging Face / container fetch of the pinned revision |
| DuckDuckGo search + page fetch | `online-manual` (user chooses search) or `online-automatic` (model may call search) | Query text, result URLs, fetched page content |
| Version / telemetry | Disabled in every Agent Lab profile | Nothing by design (`ENABLE_VERSION_UPDATE_CHECK=false`, analytics flags off) |

Search queries, result URLs, and fetched page content leave the computer in both
online modes. Hosted model inference remains unconfigured. Treat fetched content
as untrusted and review citations before promoting anything into permanent
knowledge.

Remote tools stay disabled (`AGENT_LAB_ALLOW_REMOTE_TOOLS=false`) in all three
profiles.

## Multi-backend weights and downloads

After P10, operators may keep **duplicate** weight copies (Ollama store + HF/MLX
cache + optional LM Studio / GGUF). That disk cost is expected; Agent Lab does
not share a single weight manager across backends.

| Concern | Guidance |
| --- | --- |
| When HF Hub is contacted | Only during explicit online install or weight download for pinned revisions (decision 0012). |
| Offline MLX serve | Managed wrappers set `HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1`. Missing local snapshots fail closed — no pull mid-chat. |
| LM Studio | Downloads happen inside the LM Studio app/registry, not via Agent Lab. Runtime use is loopback detect-only (`127.0.0.1:1234` typical). |
| llama.cpp | Local GGUF only when present; no Hub pull helper in Agent Lab yet (`config/llama.cpp/README.md`). |
| Switching backends | Changes which local server answers; it does not authorize new outbound model providers. |

P10 does **not** re-run LuLu / `pf` boundary proofs. MVP offline evidence in
decision 0010 remains authoritative for zero-egress claims.

## Profile semantics

| Profile | Networking intent |
| --- | --- |
| `online-manual` (default) | Connected machine; search only after explicit user action |
| `online-automatic` | Connected machine; qualified models may invoke search tools |
| `offline` | Recreate Open WebUI with `OFFLINE_MODE=true`, disable search and update checks, prevent embedding/reranker downloads, block Agent Lab model pulls, disable remote tools and telemetry, present only the three approved local Ollama artifacts |

Apply with `config/open-webui/apply-profile.sh PROFILE`. Details:
[operations](operations.md#configuration-profiles).

## Configuration is not a firewall

A process defect could bypass an application setting. A strict zero-egress claim
additionally requires a user-controlled boundary. Agent Lab never edits `pf`,
LuLu rules, Wi-Fi, or Ethernet state without the operator.

## Strict offline verification

1. Warm and verify every model and embedding cache while online.
2. Turn off Wi-Fi and disconnect Ethernet, or apply reviewed LuLu block rules
   for Docker Desktop and Ollama while retaining loopback/local traffic.
3. Run `bin/agent-lab offline verify --boundary-confirmed --full`.
4. Review `.agent-lab/results/offline-latest.json` (including timestamped
   `outbound_evidence`) and re-enable networking.

`--boundary-confirmed` prints those firewall steps before probing. It checks
that the Open WebUI container cannot reach `https://example.com`, records DNS
lookup evidence, and still restores the prior profile on exit or interrupt.
Agent Lab never applies or rolls back firewall state itself; the operator owns
that temporary boundary. Interrupted verification is covered by an EXIT-trap
cleanup path (the integration test drives a stop-file hold because Bash 3.2 on
macOS does not reliably deliver SIGINT during `sleep`).

## Configuration-only offline checks

For routine regression without a firewall claim, run
`bin/agent-lab offline verify --config-only --quick` (or `--full`). The command
labels its result `configuration_only`, tests local denial paths for search,
model pull, remote model selection, version-update disablement, and remote
tools, and restores the prior profile in its exit and signal traps. `--full`
also runs the Open WebUI, LLM CLI, and Aider smoke suites, local RAG, and an
inline three-model switch check against the managed Ollama. It does not probe
public endpoints and makes no zero-egress claim.

## Operator answers

| Question | Answer |
| --- | --- |
| What runs locally? | Active inference backend (default Ollama) + Open WebUI (+ optional LLM CLI / Aider; optional mlx / LM Studio / llama.cpp) |
| Where does private data go? | WebUI volume, `.env`, optional CLI/Aider trees; weights under `~/.ollama` and optionally `~/.cache/huggingface` / LM Studio / GGUF paths |
| When does networking occur? | Install/maintenance pulls (Ollama, HF, LM Studio app); optional DuckDuckGo in online profiles |
| How do I prove offline behavior? | Warm caches, apply host boundary, run `--boundary-confirmed --full` |
| How do I recover data? | [recovery](recovery.md) backup/restore drill |

## Secret and path review

Before sharing logs or opening issues:

- Redact `.env` values, backup paths that reveal personal directory names, and
  any pasted `WEBUI_ADMIN_PASSWORD` or `WEBUI_SECRET_KEY`.
- Prefer `bin/agent-lab status --json` fields over dumping entire volumes.
- Do not attach `~/.ollama/models` blobs or full WebUI volume tarballs to
  public trackers.
