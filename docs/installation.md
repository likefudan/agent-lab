# Installation

This guide takes a new operator from a clean Apple Silicon Mac to a healthy
Agent Lab stack and a first local chat. Follow it from the repository root.
Do not rely on undocumented global shell config or conversation history.

Exact pins live in `config/components.json` and `config/models.json`. Treat
those files as authoritative when a version in this document disagrees with a
newer catalog entry.

## Supported hardware

| Requirement | MVP target |
| --- | --- |
| Architecture | Apple Silicon (`arm64`) |
| Memory | 24 GB unified memory (qualified host) |
| OS | macOS 14 or newer; qualified on macOS 26.5.2 |
| Disk | See [Disk budget](#disk-budget) |
| Network | Required for first-time downloads; not required for core offline use afterward |

Agent Lab was qualified on an Apple M5 MacBook Air with 24 GiB unified memory.
Smaller memory may run the 4B model but is outside the MVP acceptance matrix.

## Disk budget

Status checks require at least **10 GiB** free on the data volume
(`AGENT_LAB_MIN_FREE_BYTES`, default `10737418240`). Plan more headroom for the
initial download wave:

| Artifact | Approx. size | License |
| --- | --- | --- |
| `qwen-4b` (`qwen3.5:4b`) | ~3.2 GiB | Apache-2.0 |
| `qwen-9b` (`qwen3.5:9b`) | ~6.1 GiB | Apache-2.0 |
| `gemma-12b` (`gemma4:12b`) | ~7.0 GiB | Apache-2.0 |
| Embedding snapshot (`all-MiniLM-L6-v2`) | ~87 MiB | Apache-2.0 |
| Open WebUI container image | several GiB (pinned OCI digest) | Open WebUI License |
| Open WebUI data volume growth | chats, uploads, vectors | local data |

**Practical recommendation:** keep **30–40 GiB free** before the first install
so model pulls, the container image, embedding cache, and the 10 GiB operating
reserve all fit. Model pulls also refuse to start when free space would drop
below a 2 GiB safety margin.

Pull only the aliases you need at first (`qwen-9b` is enough for text chat).
Pull `gemma-12b` before vision or Aider coding work.

## Prerequisites

Install these before `bin/agent-lab setup`:

| Tool | Role | Notes |
| --- | --- | --- |
| Homebrew | Package manager | Apple Silicon prefix `/opt/homebrew` |
| Git ≥ 2.30 | Repository checkout | Required by doctor |
| curl ≥ 7.70, jq ≥ 1.6 | HTTP and JSON helpers | Usually present on macOS |
| openssl | Secret generation | Used when creating `.env` |
| Docker Desktop ≥ 24 (engine) | Open WebUI containers | Engine must be running (`docker info`) |
| Ollama `0.32.1` | Native inference | Homebrew bottle; see below |
| [uv](https://github.com/astral-sh/uv) | Optional client installs | LLM CLI and Aider |

Optional evaluation tools (Promptfoo / Node) are documented under `evals/` and
are not required for day-to-day chat.

Verify prerequisites without changing the host:

```sh
bin/agent-lab doctor
```

Doctor must report zero `FAIL` lines before continuing. Optional clients may
show as `WARN` until you install them.

## Pinned installation sources

| Component | Pin | Source of truth |
| --- | --- | --- |
| Ollama | `0.32.1` | `config/components.json` → executable SHA-256 |
| Open WebUI | `0.10.2` @ OCI index digest | `config/components.json` / `compose.yaml` |
| LLM CLI | `0.31.1` + `llm-ollama` `0.16.1` | `config/llm/requirements.txt` |
| Aider | `0.86.2` (Python 3.12) | `config/aider/requirements.txt` |
| Chat models | aliases in catalog | `config/models.json` (manifest digests) |
| Embedding model | `sentence-transformers/all-MiniLM-L6-v2` @ fixed revision | `config/models.json` → `rag.embedding` |

Never substitute an unpinned `latest` tag, an unlisted Ollama artifact, or a
different Open WebUI image digest without a new qualification decision.

### Install pinned Ollama

Installing or downgrading Homebrew packages is an explicit administrator
action. Agent Lab never changes a Homebrew installation.

1. Install Ollama `0.32.1` from Homebrew so the executable is
   `/opt/homebrew/opt/ollama/bin/ollama`.
2. Verify version and digest against the catalog:

   ```sh
   /opt/homebrew/opt/ollama/bin/ollama --version
   shasum -a 256 /opt/homebrew/opt/ollama/bin/ollama
   jq -r '.components[] | select(.id=="ollama") | .version, .artifact.executable_sha256' \
     config/components.json
   ```

3. Do **not** enable `brew services` for Ollama. Agent Lab owns a per-user
   LaunchAgent that sets the local-only runtime contract.

If the version or executable SHA-256 differs from `config/components.json`,
stop and reinstall the qualified bottle before starting Agent Lab.

### Container runtime

Start Docker Desktop and confirm the engine:

```sh
docker info
docker compose version
```

The first `bin/agent-lab start` pulls the digest-pinned Open WebUI image
referenced in `compose.yaml`. That pull requires network access.

## Online installation vs offline operation

| Phase | Network | What happens |
| --- | --- | --- |
| Installation / maintenance | Online | Homebrew, Docker image pull, Ollama model pulls, first embedding-cache populate |
| Day-to-day core use | Offline-capable | Chat, coding, vision, local RAG, conversation storage among already-downloaded artifacts |
| Online profiles | Online optional | DuckDuckGo search only when the selected profile allows it |

Complete every download listed in this guide while online. After models,
container image, and embedding cache are present, switch to the `offline`
profile and prove the boundary with
[privacy](privacy.md#strict-offline-verification) before claiming zero egress.

## First-run checklist

Run these steps in order from the repository root.

### 1. Clone and inspect

```sh
cd /path/to/agent-lab
bin/agent-lab doctor
scripts/validate-config.sh
```

### 2. Prepare local configuration

```sh
bin/agent-lab setup
```

Setup validates catalogs, creates the ignored `.env` (mode `0600`) with a
generated admin password when missing, and creates the external Docker volume
`agent-lab-open-webui-data`. It never overwrites an existing `.env` or volume.

Optional: pull one model during setup (still asks for confirmation):

```sh
bin/agent-lab setup --model qwen-9b
```

### 3. Install the Ollama LaunchAgent and start the stack

First time only:

```sh
bin/agent-lab start --install-launch-agent
```

Confirm the destination
`~/Library/LaunchAgents/ai.agent-lab.ollama.plist`. The job binds Ollama to
`127.0.0.1:11434`, sets `OLLAMA_NO_CLOUD=1`, and
`OLLAMA_MAX_LOADED_MODELS=1`.

Later starts:

```sh
bin/agent-lab start
bin/agent-lab health
```

`start` also brings up Open WebUI on `http://127.0.0.1:3000` when Docker and
`.env` are ready. It refuses an occupied port or an unmanaged Ollama on
`11434`; stop the other service yourself and retry.

### 4. Download approved models

```sh
bin/agent-lab models list
bin/agent-lab models pull qwen-9b
bin/agent-lab models pull qwen-4b      # optional fast model
bin/agent-lab models pull gemma-12b   # required for vision / Aider defaults
bin/agent-lab models verify
```

Each pull shows the catalog tag and approximate size and verifies blob digests
before the alias is considered healthy. Pulls are refused in the `offline`
profile.

### 5. First browser chat

1. Open `http://127.0.0.1:3000`.
2. Sign in with `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` from `.env`
   (`admin@localhost` by default). Public signup is disabled.
3. Confirm the model selector shows only `qwen3.5:4b`, `qwen3.5:9b`, and
   `gemma4:12b` (after those tags are installed).
4. Select `qwen3.5:9b` and send a short local message.

Smoke automation for the same path:

```sh
tests/smoke/test-webui.sh
```

UI branding checklist details are in
[decision 0007](decisions/0007-open-webui-bootstrap.md).

### 6. Apply RAG defaults (after first healthy WebUI)

```sh
config/open-webui/apply-rag-config.sh
config/open-webui/verify-embedding-cache.sh
```

The first embedding-cache populate needs network unless a verified backup
already contains the pinned snapshot. After the cache verifies, RAG works
offline. Upload Markdown, code, or text PDFs through Open WebUI; do not write
into the volume or Chroma directories by hand. See
[operations](operations.md#local-document-rag).

### 7. Select a configuration profile

Default after setup is **online-manual** (search available only when you
explicitly request it).

```sh
config/open-webui/apply-profile.sh online-manual
# or: online-automatic | offline
bin/agent-lab status
```

Profile semantics are summarized below and detailed in
[operations](operations.md#configuration-profiles) and
[privacy](privacy.md).

### 8. Confirm health

```sh
bin/agent-lab status
bin/agent-lab health
```

Both must succeed before treating the install as complete.

---

## Ollama LaunchAgent details

Agent Lab uses the pinned Homebrew Ollama `0.32.1` executable and an
Agent Lab-owned per-user `launchd` job. It deliberately does not use plain
`brew services`: the generated job durably sets the local-only runtime contract
qualified in [decision 0002](decisions/0002-ollama-compatibility.md).

The repository template is
`config/ollama/ai.agent-lab.ollama.plist.template`.

After installation, lifecycle commands are idempotent:

```sh
bin/agent-lab start
bin/agent-lab start
bin/agent-lab stop
bin/agent-lab stop
```

`stop` leaves the plist installed so login/reboot startup remains enabled.
Remove the plist only as a deliberate uninstall after stopping the job.

Inspect the durable environment and listener:

```sh
launchctl print "gui/$(id -u)/ai.agent-lab.ollama"
lsof -nP -iTCP:11434 -sTCP:LISTEN
curl --fail http://127.0.0.1:11434/api/version
```

The `launchctl` output must contain `OLLAMA_HOST => 127.0.0.1:11434`,
`OLLAMA_NO_CLOUD => 1`, and `OLLAMA_MAX_LOADED_MODELS => 1`. `lsof` must show
only the IPv4 loopback listener. Verify persistence across logout or reboot by
repeating those checks.

Hardware benchmarks recommend `OLLAMA_KEEP_ALIVE=5m` on the qualified 24 GB
host. The LaunchAgent leaves keep-alive at Ollama's default until you choose to
add that environment variable deliberately and re-test memory behavior. See
[operations](operations.md#resource-limits-and-model-switching).

## LLM CLI

Agent Lab qualifies [LLM CLI](https://llm.datasette.io/) `0.31.1` with the
native [llm-ollama](https://github.com/taketwo/llm-ollama) plugin `0.16.1`.
Install both pinned packages into one isolated user-level uv tool environment:

```sh
uv tool install --from 'llm==0.31.1' llm --with 'llm-ollama==0.16.1'
export PATH="$HOME/.local/bin:$PATH"
llm --version
llm plugins --all
```

The expected versions are also recorded in `config/llm/requirements.txt`. Do
not use an unpinned `llm install llm-ollama`, because it can change the tested
plugin independently of the CLI.

Seed a private runtime directory from the repository-owned configuration:

```sh
mkdir -p .agent-lab/llm
cp config/llm/aliases.json config/llm/default_model.txt \
  config/llm/logs-off .agent-lab/llm/
export LLM_USER_PATH="$PWD/.agent-lab/llm"
export OLLAMA_HOST=http://127.0.0.1:11434
export LLM_LOAD_PLUGINS=llm-ollama
```

This selects `qwen-9b` by default and configures the approved `qwen-4b`,
`qwen-9b`, and `gemma-12b` aliases. Keep `OLLAMA_HOST` on the loopback URL. No
API key is needed, and `LLM_LOAD_PLUGINS` limits third-party plugin loading to
the local Ollama integration. The seed's `logs-off` marker requests disabled
SQLite prompt/response logging by default; the pinned CLI's interactive chat
can still create private conversation records. Keep the entire ignored runtime
directory private. LLM CLI history is separate from Open WebUI history and does
not synchronize conversations or Open WebUI RAG collections.

With Agent Lab's Ollama service running and approved models installed:

```sh
# One-shot prompt (streaming is the default)
llm -m qwen-9b 'Explain why this shell command failed'

# Wait for a complete response instead of streaming tokens
llm -m qwen-4b --no-stream 'Return a three-item checklist'

# Interactive multi-turn terminal conversation; type exit or quit to finish
llm chat -m qwen-9b

# Coding-oriented or vision-capable model selection
llm -m gemma-12b 'Write a Python context manager'

# Local image attachment through the qualified multimodal model
llm -m gemma-12b -a ./screenshot.png 'Describe the image and read visible text'
```

Press `Control-C` to cancel a streamed response; this interrupts the client
request without stopping Ollama. An unknown or unavailable model must fail
locally: Agent Lab does not configure a cloud fallback and LLM CLI does not pull
models.

```sh
tests/smoke/test-llm-cli.sh
```

## Aider

Agent Lab qualifies [Aider](https://aider.chat/) `0.86.2` as the
repository-aware coding client. Install the pinned package in an isolated uv
tool environment using Python 3.12:

```sh
uv tool install --python 3.12 'aider-chat==0.86.2'
export PATH="$HOME/.local/bin:$PATH"
aider --version
```

Python 3.12 is explicit because Aider 0.86.2 pins SciPy 1.15.3. On hosts where
uv's default Python lacks a matching SciPy wheel, a source build can require a
Fortran compiler. The expected Aider version is also recorded in
`config/aider/requirements.txt`.

From the root of each Git repository where Aider may edit code, copy the
versioned seed and create its ignored private history directory:

```sh
cp /path/to/agent-lab/config/aider/aider.conf.yml .aider.conf.yml
cp /path/to/agent-lab/config/aider/aider.model.settings.yml \
  .aider.model.settings.yml
cp /path/to/agent-lab/config/aider/aider.model.metadata.json \
  .aider.model.metadata.json
mkdir -p .agent-lab/aider
```

The seed uses `openai/gemma4:12b` through
`http://127.0.0.1:11434/v1`. The `ollama` API-key value is a compatibility
placeholder for the OpenAI client, not a credential. The qualified settings use
the `whole` edit format, a 4,096-token input context, a 1,024-token completion
budget, and no repository map.

Start Agent Lab, confirm `gemma4:12b` is installed, then launch Aider inside
the target repository:

```sh
aider calculator.py

# Repeatable noninteractive form for automation or a scoped repair
aider --message 'Fix only calculator.py so its existing tests pass.' calculator.py
```

The safe defaults disable hosted analytics and update checks, URL detection,
shell suggestions, repository-map expansion, automatic lint/test commands, and
automatic Git commits. Inspect `git diff`, run the repository's own tests, and
commit only after review. Conversation history is separate from Open WebUI and
LLM CLI and does not share RAG collections.

An unavailable model produces a local `NotFoundError` and leaves the worktree
unchanged. In Aider 0.86.2, noninteractive `--message` mode can still exit with
status zero after printing that provider error, so automation must check the
captured output as well as the resulting Git diff and tests.

```sh
tests/smoke/test-aider.sh
```

## Configuration profiles (install-time summary)

| Profile | Search | Model pulls | Typical use |
| --- | --- | --- | --- |
| `online-manual` | Explicit user action only | Allowed | Default connected operation |
| `online-automatic` | Model may call search | Allowed | Explicit opt-in |
| `offline` | Disabled | Prohibited | Local-only core workflows |

Apply with `config/open-webui/apply-profile.sh PROFILE`. Changing profiles
recreates the Open WebUI container while preserving the named data volume.

## Clean-room validation

To validate this guide without relying on a prior operator session:

1. Use a fresh macOS user account, or a disposable clone of this repository plus
   a disposable Docker volume name only if you are prepared to lose that
   volume's data.
2. Install only the prerequisites listed above.
3. Execute every command in [First-run checklist](#first-run-checklist) and the
   client sections you care about.
4. Confirm `bin/agent-lab health` passes and a browser message round-trips
   against `qwen3.5:9b`.
5. Run `make test-static` from the repository to catch broken relative Markdown
   links introduced while editing docs.

Do not commit `.env`, model weights, caches, chats, vectors, logs, or
`.agent-lab/results/`.
