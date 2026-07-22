# Operations

Day-to-day operation of a qualified Agent Lab host: what runs, where data
lives, how profiles and models behave, how to update safely, and how to
triage failures. Run commands from the repository root unless noted.

For first install, see [installation](installation.md). For trust boundaries
and offline proof, see [privacy](privacy.md). For backup and restore drills,
see [recovery](recovery.md).

## What runs

| Process | Bind | Owner |
| --- | --- | --- |
| Ollama `0.32.1` (default active backend) | `127.0.0.1:11434` | Agent Lab LaunchAgent `ai.agent-lab.ollama` |
| Optional `mlx_lm` / `mlx_vlm` / `llama_cpp` | `11435` / `11436` / `11437` | `agent-lab backend start` when installed |
| Optional LM Studio local server | `127.0.0.1:1234` (typical) | LM Studio app (detect-only) |
| Open WebUI `0.10.2` | `127.0.0.1:3000` → container `:8080` | Docker Compose project `agent-lab` |
| LLM CLI / Aider | client only | Optional host tools talking to the **active** `/v1` |

Inference stays on the host loopback. Open WebUI reaches the active backend
through Compose / provider wiring (`apply-inference`). No custom gateway
multiplexes backends. Ports and contract:
[decision 0011](decisions/0011-inference-backends.md).

## Data locations

| Data | Location | In Git? | In Agent Lab backup? |
| --- | --- | --- | --- |
| Versioned config, catalogs, profiles | repository `config/` | Yes | Yes (runtime copy / reviewed tree) |
| Private Compose secrets and admin password | repository `.env` (mode `0600`) | No | Yes |
| Selected profile name | `.agent-lab/profile` | No | With config extract |
| Ollama weights and manifests | `~/.ollama/models` | No | No (reproducible from catalog) |
| Hugging Face / MLX weight cache | `~/.cache/huggingface` (or `$HF_HOME`) | No | No |
| Active backend marker + inference env | `~/.agent-lab/state/active-backend`, `inference.env` | No | No |
| Managed mlx / llama.cpp PID + logs | `~/.agent-lab/run/`, `~/.agent-lab/logs/` | No | No |
| MLX Python venv | `.agent-lab/venvs/mlx` | No | No |
| Ollama LaunchAgent logs | `~/.agent-lab/logs/` | No | No |
| Open WebUI chats, settings, uploads, Chroma | Docker volume `agent-lab-open-webui-data` | No | Yes |
| Embedding model cache | inside that volume under `/app/backend/data/cache/...` | No | Yes (with volume) |
| LLM CLI runtime | `.agent-lab/llm/` (when seeded) | No | No |
| Aider history | per-repo `.agent-lab/aider/` (when seeded) | No | No |
| Test and benchmark artifacts | `.agent-lab/results/` | No | No |

Never commit secrets, weights, caches, chats, vectors, logs, or results.

## Retention

Agent Lab does not auto-expire chats, uploads, or vectors. Retention is an
operator choice:

- Delete conversations and files through Open WebUI when you no longer need
  them.
- Rotate backups deliberately; treat archives like credentials because they
  can contain password hashes and chat history.
- Ollama keep-alive controls **model residency in RAM**, not disk retention.
  Disk weights remain until you explicitly remove a tag.
- LLM CLI and Aider histories are separate ignored trees; prune them locally
  if desired.

## Configuration profiles

| Profile | `AGENT_LAB_SEARCH_MODE` | Pulls | Remote tools | Intent |
| --- | --- | --- | --- | --- |
| `online-manual` (default) | `manual` | allowed | false | Connected; search only after explicit user action |
| `online-automatic` | `automatic` | allowed | false | Connected; model may invoke DuckDuckGo |
| `offline` | `disabled` | prohibited | false | Local core workflows; no search; no pulls |

Apply and persist:

```sh
config/open-webui/apply-profile.sh online-manual
# or: online-automatic | offline
bin/agent-lab status --json | jq '.profile'
```

Applying a profile recreates the Open WebUI container from Compose while
keeping the named volume. Do not hand-edit `.agent-lab/profile` or Open
WebUI's SQLite database to change modes.

A valid offline **profile file** is not proof of zero egress. See
[privacy](privacy.md#strict-offline-verification).

## Inference backends

Ollama is no longer the sole inference entry. One **active backend** is the
day-to-day client target for Open WebUI, LLM CLI, and Aider.

| Backend | Port | OpenAI `/v1` | Lifecycle |
| --- | ---: | --- | --- |
| `ollama` | `11434` | `http://127.0.0.1:11434/v1` | Managed LaunchAgent |
| `mlx_lm` | `11435` | `http://127.0.0.1:11435/v1` | Managed venv + wrappers under `config/mlx/` |
| `mlx_vlm` | `11436` | `http://127.0.0.1:11436/v1` | Managed (vision / multimodal) |
| `llama_cpp` | `11437` | `http://127.0.0.1:11437/v1` | Optional when binary + GGUF exist |
| `lm_studio` | `1234` (typical) | `http://127.0.0.1:1234/v1` | Detect-only |

```sh
bin/agent-lab backend list
bin/agent-lab backend status
bin/agent-lab backend status --json
bin/agent-lab backend start mlx_lm --model-alias qwen-4b
bin/agent-lab backend stop mlx_lm
bin/agent-lab backend use ollama          # record + apply-inference
bin/agent-lab apply-inference             # rewire clients without changing id
bin/agent-lab apply-webui-params          # thinking off, max_tokens, num_ctx, keep_alive
bin/agent-lab benchmark-backends --dry-run
bin/agent-lab benchmark-backends --smoke --backends ollama --aliases qwen-4b
```

`backend use` writes `~/.agent-lab/state/active-backend` and runs
`apply-inference` (Compose env, `.agent-lab/llm/`, `.agent-lab/aider/`, Open
WebUI providers when healthy). Non-Ollama actives use OpenAI `/v1` only — no
silent Ollama fallthrough. Starting a managed mlx_*/llama_cpp peer stops other
managed heavy peers by default (24 GiB single-heavy-server guidance); pass
`--keep-others` only when you accept the memory risk.

**Open WebUI chat defaults:** `apply-inference` (and
`bin/agent-lab apply-webui-params`) write
`config/open-webui/model-params.json` into Admin
`DEFAULT_MODEL_PARAMS` (`think:false`, `max_tokens:512`, `num_ctx:4096`,
`keep_alive:5m`) into Admin defaults **and** the admin user's Chat Controls
`ui.params` (otherwise the browser may omit Max Tokens and generation runs
unbounded). Title/tags/follow-up/autocomplete and Memory stay on. Leave
Controls → Think **Off**; raise Max Tokens only if you accept longer waits.

**Vision split:** text on `mlx_lm` (`:11435`) and vision on `mlx_vlm`
(`:11436`) without a custom gateway. `backend use` wires one active connection;
add a second OpenAI connection in the Open WebUI admin UI to the other loopback
`/v1` if you need both. Details: `config/inference/README.md`.

**Recovery:** if clients misbehave after a switch, `bin/agent-lab backend use
ollama` restores the shipped default, then `bin/agent-lab health`. Regression:
`tests/integration/test-backends.sh` (skips absent optionals; does not touch
firewalls).

Install notes and duplicate disk cost:
[installation — optional inference backends](installation.md#optional-inference-backends-post-mvp).
Privacy for HF / LM Studio downloads:
[privacy — multi-backend weights](privacy.md#multi-backend-weights-and-downloads).

## LLM CLI (terminal chat)

Pinned `llm` + `llm-ollama` talk to the **active** backend via
`.agent-lab/llm/`. Prefer the wrapper so env/aliases stay correct:

```sh
uv tool install --from 'llm==0.31.1' llm --with 'llm-ollama==0.16.1'   # once
bin/agent-lab apply-inference
bin/agent-lab llm -m qwen-4b -o think false -o num_predict 256 '世界杯是什么？'
bin/agent-lab llm -m qwen-9b chat -o think false
```

Details: `config/llm/README.md`. Smoke: `tests/smoke/test-llm-cli.sh`.

## Resource limits and model switching

- `OLLAMA_MAX_LOADED_MODELS=1` is mandatory when Ollama is the active path. Only
  one large model may reside at a time on 24 GiB hosts across backends as well:
  do not run Ollama + mlx + LM Studio heavy loads together.
- Prefer serial requests. Concurrent chat, Aider, and WebUI traffic against
  different models forces unload/load cycles.
- Defaults: chat `qwen-9b`, fast `qwen-4b`, coding/vision `gemma-12b`.
- Only `gemma-12b` is advertised for image input (Ollama or `mlx_vlm`).
- Hardware qualification recommends `OLLAMA_KEEP_ALIVE=5m` on the 24 GB host.
  Changing keep-alive is a deliberate LaunchAgent edit followed by memory
  re-checks (`bin/agent-lab benchmark` or `memory_pressure`).
- Under memory pressure, finish or cancel active generation, stop unrelated
  apps or optional backends (`bin/agent-lab backend stop …`), or
  `bin/agent-lab stop` / `start` and continue on `qwen-4b`. Do not raise the
  loaded-model limit or invent a multiplexed gateway.

Inspect residency:

```sh
curl --fail --silent http://127.0.0.1:11434/api/ps | jq .
bin/agent-lab status --json | jq '.ollama.active_models'
bin/agent-lab backend status
```

## Updates and digest drift

Pins are immutable identifiers, not floating tags.

| Check | Command / signal |
| --- | --- |
| Catalogs and Compose | `scripts/validate-config.sh` |
| Live Ollama binary and WebUI image | `bin/agent-lab status` (`digest=DRIFT` is a failure) |
| Model manifests and blobs | `bin/agent-lab models verify` |
| Embedding cache tree | `config/open-webui/verify-embedding-cache.sh` |

When drift appears:

1. Do not silently approve new bytes or edit expected digests in Git.
2. Stop using the drifted artifact for production chat until requalified.
3. Reinstall the pinned Ollama bottle, recreate from the pinned OCI digest, or
   re-pull the catalog alias during an explicit online maintenance window.
4. Record a new decision if upstream no longer serves the qualified artifact.

Version update checks stay disabled in every profile
(`ENABLE_VERSION_UPDATE_CHECK=false`). Upgrades are operator-driven and must
repeat the relevant qualification probes.

## Logs

| Source | Path / command |
| --- | --- |
| Ollama stdout/stderr | `~/.agent-lab/logs/ollama.stdout.log`, `ollama.stderr.log` |
| Managed mlx / llama.cpp | `~/.agent-lab/logs/mlx_lm.*.log`, `mlx_vlm.*.log`, `llama_cpp.*.log` |
| Open WebUI container | `docker compose --env-file .env -f compose.yaml logs --tail 100 open-webui` |
| Status / health JSON | `bin/agent-lab status --json` |
| Backend status JSON | `bin/agent-lab backend status --json` |
| Offline verification | `.agent-lab/results/offline-latest.json` |
| Multi-backend benchmarks | `.agent-lab/results/benchmark-backends-*.json` |
| Benchmarks / suites | `.agent-lab/results/` |

Container logging is capped (`max-size` 10m, `max-file` 3) in `compose.yaml`.

## Local document RAG

Agent Lab uses Open WebUI's built-in file ingestion, Chroma vector storage, and
hybrid retrieval. Embeddings run inside the pinned Open WebUI container with
`sentence-transformers/all-MiniLM-L6-v2`; automatic model updates and remote
code are disabled, and no reranker is enabled.

After first start, apply and verify the durable settings:

```sh
config/open-webui/apply-rag-config.sh
config/open-webui/verify-embedding-cache.sh
```

Upload documents through Open WebUI or its supported API. Do not write into the
SQLite database, Chroma directory, or Docker volume directly. The WebUI data
volume owns uploaded files, vectors, knowledge collections, conversations, and
application configuration.

The qualified defaults are 500-character chunks with 50-character overlap,
hybrid vector/BM25 retrieval weighted 0.5, and top-k 5. Re-run
`tests/integration/test-rag.sh` after changing any of them. Test results are
written under ignored `.agent-lab/results/`.

Built-in extraction covers the MVP's Markdown, code, and text PDFs. Scanned-PDF
OCR is not included; see [Decision 0008](decisions/0008-document-extraction.md).

## Known limitations

- Single-user laptop scope; no multi-user or clustered deployment.
- One loaded large model at a time on 24 GB unified memory.
- Qwen aliases are not vision-qualified; use `gemma-12b` for images.
- Promptfoo and small local models can show multi-second first-token latency on
  longer prompts; that is expected UX, not a crash.
- Online search uses DuckDuckGo only when an online profile enables it; LuLu or
  other host firewall rules can block Docker egress even when the profile
  allows search.
- SearXNG and Docling are deferred; do not add them during incident response.
- Optional backends (`mlx_lm`, `mlx_vlm`, `lm_studio`, `llama_cpp`) require
  separate install/detect steps; `llama_cpp` / LM Studio model slots may still
  be `candidate` until digests exist (decision 0012).
- Comparative default changes wait on P10-T08 / decision 0013.
- Configuration alone is not a physical firewall.

## Incident triage and command safety

Start with read-only diagnostics; they do not start a service, load or pull a
model, or change configuration:

```sh
bin/agent-lab status
bin/agent-lab health
bin/agent-lab status --json | jq .
```

`health` exits nonzero when any required check fails. Its final `action` text is
the first supported correction to try. Preserve that output and the relevant
logs before restarting anything when the same failure recurs.

Safety labels used below:

- **Read-only** inspects state and is safe to repeat.
- **Service action** starts, stops, or recreates a process or container while
  preserving the model store and named WebUI data volume.
- **Network action** may contact a registry or search provider and must be used
  only in an online profile.
- **Destructive** can remove data. No destructive command is a first response;
  make and verify a backup before using one.

Never use `docker compose down --volumes`, delete
`agent-lab-open-webui-data`, edit `webui.db` or Chroma files directly, or remove
Ollama blobs while diagnosing an incident.

## Runtime failure procedures

### Ollama is stopped or unreachable

1. **Read-only:** confirm the failure and whether port `11434` has a listener.

   ```sh
   bin/agent-lab status
   launchctl print "gui/$(id -u)/ai.agent-lab.ollama"
   lsof -nP -iTCP@127.0.0.1:11434 -sTCP:LISTEN
   ```

2. If no unrelated listener owns the port, use the supported **service
   action**:

   ```sh
   bin/agent-lab start
   ```

3. If it does not recover, inspect the read-only launchd log and diagnostics.

   ```sh
   tail -n 100 "$HOME/.agent-lab/logs/ollama.stderr.log"
   bin/agent-lab health
   ```

Do not install a second Ollama service or start an ad-hoc `ollama serve` on the
same port. If the LaunchAgent is genuinely absent, the one-time
`bin/agent-lab start --install-launch-agent` path requires interactive
confirmation and is documented in [installation](installation.md).

### Open WebUI is unhealthy

1. **Read-only:** distinguish a stopped Docker engine, an exited container, an
   image-digest mismatch, and an application health failure.

   ```sh
   docker info
   docker compose --env-file .env -f compose.yaml ps
   docker compose --env-file .env -f compose.yaml logs --tail 100 open-webui
   bin/agent-lab status
   ```

2. Start Docker Desktop if its engine is unavailable. Otherwise use the
   supported **service actions**, which preserve the named volume:

   ```sh
   bin/agent-lab stop
   bin/agent-lab start
   bin/agent-lab health
   ```

3. If WebUI remains unhealthy, stop retrying and take a backup before treating
   its persistent data as suspect. Follow [corrupted WebUI data](recovery.md#corrupted-open-webui-data)
   rather than deleting or reinitializing the live volume.

### Port 11434 or 3000 is already in use

1. **Read-only:** identify the owning process and, for a container, its name.

   ```sh
   lsof -nP -iTCP@127.0.0.1:11434 -sTCP:LISTEN
   lsof -nP -iTCP@127.0.0.1:3000 -sTCP:LISTEN
   docker ps --format 'table {{.Names}}\t{{.Ports}}'
   ```

2. If Agent Lab already owns the listener, use `bin/agent-lab status`; a second
   start is unnecessary. If another application owns it, stop that application
   through its own supported control and retry `bin/agent-lab start`.
3. Do not use `kill -9`, delete an unknown container, or silently expose the
   service on a non-loopback address. A deliberate port change also requires
   updating and retesting the status, health, and client endpoint configuration;
   it is a configuration change, not an incident shortcut.

### An approved model fails to load

1. **Read-only:** verify the server, artifact, current residency, free disk, and
   memory pressure.

   ```sh
   bin/agent-lab health
   bin/agent-lab models verify
   curl --fail --silent http://127.0.0.1:11434/api/ps | jq .
   memory_pressure -Q
   ```

2. If another model is resident, wait for its request to finish and retry the
   request serially. Agent Lab intentionally permits only one loaded model.
3. If memory is critical, follow the memory-pressure procedure below. If
   Ollama itself is unhealthy, restart it through `bin/agent-lab stop` and
   `bin/agent-lab start`; this **service action** does not remove weights.
4. When the artifact verification fails, do not keep loading it. Follow the
   digest-mismatch procedure in [recovery](recovery.md#model-digest-mismatch).
   A model-not-found response is local and must never be redirected to a hosted
   model.

### Critical memory pressure

1. **Read-only:** inspect system pressure and the one resident model.

   ```sh
   memory_pressure -Q
   curl --fail --silent http://127.0.0.1:11434/api/ps | jq .
   ```

2. Cancel or let active generation finish; do not start concurrent requests.
   Close unrelated memory-heavy applications.
3. If pressure remains critical, `bin/agent-lab stop` is a reversible **service
   action** that unloads the model and preserves all data. Wait for pressure to
   recover, then run `bin/agent-lab start` and select the smaller `qwen-4b` model
   for the next request.
4. Keep `OLLAMA_MAX_LOADED_MODELS=1`. Raising it or adding a second inference
   server is not a recovery action. Record repeatable pressure for the hardware
   benchmark task instead.

### Embedding cache is missing

1. **Read-only:** confirm the exact pinned snapshot is absent.

   ```sh
   config/open-webui/verify-embedding-cache.sh
   bin/agent-lab status --json | jq '.embedding_cache'
   ```

2. In a selected online profile, run these **network/service actions** once to
   populate and verify the cache in the persistent WebUI volume:

   ```sh
   config/open-webui/apply-rag-config.sh
   config/open-webui/verify-embedding-cache.sh
   tests/integration/test-rag.sh
   ```

3. When strictly offline, do not relax the boundary or substitute an unpinned
   embedding model. RAG remains unavailable until the approved snapshot can be
   restored from a verified full-volume backup or cached during an explicitly
   online maintenance window. See [backup and recovery](recovery.md).

### Profile state or settings drift

1. **Read-only:** inspect the selected state, validate versioned profiles, and
   review local changes.

   ```sh
   bin/agent-lab status --json | jq '.profile, .optional_features'
   scripts/validate-config.sh
   git diff -- config/profiles config/open-webui
   ```

2. Do not hand-edit `.agent-lab/profile` or Open WebUI's database. After
   reviewing the versioned profile, reapply the intended profile with this
   **configuration/service action**:

   ```sh
   config/open-webui/apply-profile.sh offline
   ```

   Replace `offline` with `online-manual` or `online-automatic` only when that
   is the intended, reviewed mode.
3. Re-run `bin/agent-lab health`. For the offline profile, also run the complete
   `bin/agent-lab offline verify` workflow; a valid profile file alone is not
   proof of a network boundary.

### DuckDuckGo search-provider outage

First confirm local chat and WebUI health. A provider timeout, rate limit, or
result-shape change is an external failure and is not evidence that Ollama or
the local model is broken.

```sh
bin/agent-lab health
tests/integration/test-search.sh
```

Retry later and keep working without search, or apply the `offline` profile if
no outbound lookup is needed. Do not place provider responses into permanent
knowledge as a workaround. Do not add credentials, a proxy, another engine, or
SearXNG during incident response; [Decision 0009](decisions/0009-search-provider.md)
defines the evidence and review needed to revisit the provider.

### Offline verification fails

Treat any observed outbound attempt as a failed verification, even when the
local workflows pass.

1. Keep or restore the firewall state exactly as instructed by the verification
   script; do not improvise a permanent `pf` or LuLu rule.
2. Preserve the timestamped result and identify whether the failure is a
   prerequisite/cache failure, a local workflow failure, or observed egress.
3. **Read-only:** run `bin/agent-lab health` and inspect the selected profile.
   Repair missing models or caches only during a separate, explicit online
   maintenance window.
4. Reapply `offline`, close remote tools, then repeat
   `bin/agent-lab offline verify` from the beginning. Do not claim offline
   qualification from a partial rerun or weaken the firewall to make the test
   pass.

An interrupted verification must restore its temporary observation/firewall
state through the script's cleanup path. If that cannot be confirmed, restore
network controls manually before any further test and record the incident.
