# Installation

This guide reproduces the Agent Lab MVP on Apple Silicon macOS. The qualified
host is an M5 MacBook Air with 24 GB unified memory, macOS 26.5.2, Docker
Desktop 4.80.0 (engine 29.6.1), native Ollama `0.32.1`, Open WebUI `0.10.2`,
LLM CLI `0.31.1`, `llm-ollama` `0.16.1`, and Aider `0.86.2`. Other Apple
Silicon systems may work, but are not the release-qualified host.

## Prerequisites

Install and start Docker Desktop, and make sure these commands are available:

```sh
git --version
curl --version
jq --version
docker info
docker compose version
```

The runtime minimums checked by `doctor` are Git 2.30, curl 7.70, jq 1.6, and
Docker 24. The Open WebUI image is pinned by OCI digest, so no local source
build is required. Approximately 20 GB is needed for the three approved model
artifacts in addition to Docker data, caches, and safe working space.

Clone the repository and remain on the intended release branch or tag:

```sh
git clone https://github.com/likefudan/agent-lab.git
cd agent-lab
bin/agent-lab doctor
```

`doctor` is read-only. Resolve every `FAIL` before setup; missing optional
terminal and evaluation clients appear as warnings. Agent Lab does not install
or upgrade Homebrew, Docker Desktop, Ollama, Python, Node, or `uv` on the
operator's behalf.

## Reproducible first run

First complete the pinned Ollama installation below and start Docker Desktop.
Then create the private environment and durable WebUI volume:

```sh
bin/agent-lab setup
bin/agent-lab start --install-launch-agent
```

The first `start` asks before installing the per-user launch agent. It also
starts the digest-pinned Open WebUI container at <http://127.0.0.1:3000>.
The local administrator email and generated password are stored only in the
ignored `.env`; protect that file and do not paste it into logs or commits.

While connected, download and verify the approved artifacts serially:

```sh
bin/agent-lab models pull qwen-4b
bin/agent-lab models pull qwen-9b
bin/agent-lab models pull gemma-12b
bin/agent-lab models verify
```

Each pull displays its approximate size and asks for confirmation. The command
rejects an artifact whose manifest or blob digests differ from
`config/models.json`; it never substitutes a hosted model. Next cache and pin
the local RAG embedding files, apply the default profile, and verify health:

```sh
config/open-webui/apply-rag-config.sh
config/open-webui/verify-embedding-cache.sh
config/open-webui/apply-profile.sh online-manual
bin/agent-lab health
```

Open <http://127.0.0.1:3000>, sign in with the `.env` administrator values,
select a model, and send a short message. Upload a small text document and ask
a question whose answer appears only in that document; verify the answer cites
the uploaded source. Use `gemma-12b` for an image check. These actions confirm
the browser, local inference, persistent RAG path, and vision route.

Before relying on disconnected operation, read the [privacy and offline
boundary guide](privacy.md). The full configuration-only regression is safe to
run while connected, but it is not zero-egress proof:

```sh
bin/agent-lab offline verify --config-only --full
```

## Updating a pinned installation

Do not independently update Ollama, the Open WebUI image, model tags, embedding
revision, LLM CLI, or Aider. Their versions and immutable identifiers form one
tested compatibility set in `config/components.json`, `config/models.json`, and
the client requirement files. Move to a newer reviewed Agent Lab release, read
its migration notes, make a verified backup, then run its validation and
acceptance tests before replacing the current set.

Agent Lab uses the pinned Homebrew Ollama `0.32.1` executable and an
Agent Lab-owned per-user `launchd` job. It deliberately does not use plain
`brew services`: the generated job durably sets the local-only runtime contract
that was qualified in [decision 0002](decisions/0002-ollama-compatibility.md).

## Ollama launch agent

The repository template is
`config/ollama/ai.agent-lab.ollama.plist.template`. It binds Ollama only to
`127.0.0.1:11434`, disables Ollama cloud behavior, and limits residency to one
loaded model. Keep-alive is intentionally left at Ollama's default until the
benchmark phase measures it.

First verify that the pinned Homebrew installation is present:

```sh
/opt/homebrew/opt/ollama/bin/ollama --version
shasum -a 256 /opt/homebrew/opt/ollama/bin/ollama
```

The version must be `0.32.1`. The expected executable digest is stored in
`config/components.json`. Installing or downgrading Homebrew packages is a
separate, explicit administrator action; `agent-lab start` never changes a
Homebrew installation.

Install and start the per-user job from an interactive terminal:

```sh
bin/agent-lab start --install-launch-agent
```

The command shows the destination and asks for confirmation before creating
`~/Library/LaunchAgents/ai.agent-lab.ollama.plist` and
`~/.agent-lab/logs/`. It refuses to overwrite a different file. After the first
installation, normal lifecycle commands are idempotent:

```sh
bin/agent-lab start
bin/agent-lab start
bin/agent-lab stop
bin/agent-lab stop
```

`start` refuses an occupied port, a server with the wrong version, or a
compatible Ollama that is not owned by this launch agent. Stop the other service
yourself (for example, an Ollama app or Homebrew service), then retry; Agent Lab
never kills it. `stop` verifies that the installed plist exactly matches the
repository-generated configuration before asking `launchd` to stop that job.
It leaves the plist installed, so login/reboot startup remains enabled. Remove
the plist only as a deliberate uninstall operation after stopping it.

Inspect the durable environment and listener with:

```sh
launchctl print "gui/$(id -u)/ai.agent-lab.ollama"
lsof -nP -iTCP:11434 -sTCP:LISTEN
curl --fail http://127.0.0.1:11434/api/version
```

The `launchctl` output must contain `OLLAMA_HOST => 127.0.0.1:11434`,
`OLLAMA_NO_CLOUD => 1`, and `OLLAMA_MAX_LOADED_MODELS => 1`. `lsof` must show
only the IPv4 loopback listener. The job's `RunAtLoad` and `KeepAlive` settings
provide persistence across login and reboot; verify persistence on the real host
by logging out or rebooting, then repeating the three read-only checks above.

## Terminal clients

Both terminal clients connect directly to the loopback Ollama API. They do not
route through Open WebUI and therefore do not share its conversations or RAG
collections.

### LLM CLI

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

With Agent Lab's Ollama service running and approved models installed, the
qualified commands are:

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
models. For offline use, select the project's offline profile when it is
available; the CLI itself needs only the existing loopback Ollama service and
locally installed model files.

Run the host smoke test after setup:

```sh
tests/smoke/test-llm-cli.sh
```

The test uses a disposable LLM user directory, verifies one-shot and multi-turn
chat, aliases, streaming cancellation, Gemma image input, missing-model errors,
and proxy-blocked offline operation. It confirms all history and cancellation
bookkeeping stay inside the disposable runtime and that no credentials file is
created; the directory is removed after the test.

### Aider

Agent Lab qualifies [Aider](https://aider.chat/) `0.86.2` as the
repository-aware coding client. Install the pinned package in an isolated uv
tool environment using Python 3.12:

```sh
uv tool install --python 3.12 'aider-chat==0.86.2'
export PATH="$HOME/.local/bin:$PATH"
aider --version
```

Python 3.12 is explicit because Aider 0.86.2 pins SciPy 1.15.3. On this host,
uv's default Python 3.14 has no matching SciPy wheel and attempts a source build
that requires a Fortran compiler. The expected Aider version is also recorded
in `config/aider/requirements.txt`.

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
budget, and no repository map. Aider's measured local repair succeeded at that
budget; smaller completion limits can end Gemma's response before it returns an
answer.

Start Agent Lab, confirm the approved `gemma4:12b` artifact is installed, then
launch Aider inside the target repository:

```sh
aider calculator.py

# Repeatable noninteractive form for automation or a scoped repair
aider --message 'Fix only calculator.py so its existing tests pass.' calculator.py
```

The safe defaults disable hosted analytics and update checks, URL detection,
shell suggestions, repository-map expansion, automatic lint/test commands, and
automatic Git commits. Aider still owns application of model-generated edits
to the worktree. Inspect `git diff`, run the repository's own tests, and commit
only after review. The seed does not configure a cloud fallback, model pull, or
hosted API credential. Its conversation history is separate from Open WebUI and
LLM CLI history, and it does not share Open WebUI RAG collections.

An unavailable model produces a local `NotFoundError` and leaves the worktree
unchanged. In Aider 0.86.2, noninteractive `--message` mode can still exit with
status zero after printing that provider error, so automation must check the
captured output as well as the resulting Git diff and tests.

Run the host smoke test after setup:

```sh
tests/smoke/test-aider.sh
```

The smoke test runs only in disposable Git repositories outside the Agent Lab
worktree. It checks a minimal repair and passing unit tests, preservation of
out-of-scope files, absence of auto-commits, deterministic recovery from an
unapplicable edit, a clear unavailable-model failure, and proxy-blocked local
execution. It removes all disposable repositories when finished.
