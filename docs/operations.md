# Operations

Run Agent Lab from the repository root. Normal lifecycle operations preserve
the Ollama model store and the external Open WebUI data volume:

```sh
bin/agent-lab start
bin/agent-lab status
bin/agent-lab health
bin/agent-lab stop
```

`status` is read-only and has a stable JSON form for automation. `health`
checks the pinned runtime, WebUI, models, profile, local storage, and embedding
cache and exits nonzero when action is required. `stop` stops WebUI and unloads
the managed Ollama process without uninstalling the launch agent or deleting
data.

## Profile operations

Agent Lab has three explicit profiles:

| Profile | Network-dependent behavior | Intended use |
| --- | --- | --- |
| `online-manual` | DuckDuckGo search only after explicit user selection; model pulls allowed | Default connected use |
| `online-automatic` | The local model may choose DuckDuckGo search; model pulls allowed | Opt-in agentic search |
| `offline` | Search, pulls, remote tools, update checks, and model auto-updates disabled | Cached local workflows only |

Apply a profile with:

```sh
config/open-webui/apply-profile.sh online-manual
```

Replace the last argument with another reviewed profile. Applying one recreates
the Open WebUI container to make environment changes effective, updates its
durable search configuration, and records the selection in the ignored
`.agent-lab/profile`; the named data volume is preserved. Wait for the command
to report success before sending requests. Profile selection is application
policy, not a firewall or zero-egress proof; see [privacy](privacy.md).

## Model selection and memory

Use `qwen-9b` for normal chat, `qwen-4b` when latency or memory matters, and
`gemma-12b` for coding or images. Agent Lab configures Ollama to keep at most one
model loaded. Avoid concurrent requests across models on the 24 GB target.

```sh
bin/agent-lab models list
bin/agent-lab models verify
curl --fail --silent http://127.0.0.1:11434/api/ps | jq .
```

Model pulls are online maintenance actions, are blocked by the offline profile,
and must be performed one alias at a time. A missing alias fails locally; there
is no cloud fallback.

### Native MLX backends

Use MLX-LM for normal chat/coding and switch to MLX-VLM before sending an image
to Gemma:

```sh
bin/agent-lab mlx start chat
bin/agent-lab mlx health

bin/agent-lab mlx start vision
bin/agent-lab mlx health
```

Starting one role stops the other. This is intentional: Qwen 9B and Gemma 12B
must not remain resident together on the 24 GB target. Open WebUI keeps both
friendly presets visible, but a request to the inactive preset fails locally
until its backend is selected. The endpoints are:

| Role | Open WebUI preset | Local endpoint |
| --- | --- | --- |
| Chat and code | `Agent Lab MLX Qwen 9B` | `http://127.0.0.1:8081/v1` |
| Images and multimodal chat | `Agent Lab MLX Gemma 12B Vision` | `http://127.0.0.1:8082/v1` |

Inspect state and logs without changing models:

```sh
bin/agent-lab mlx status
bin/agent-lab mlx logs chat
bin/agent-lab mlx logs vision
```

The model snapshots are pinned separately from Ollama. `models verify` performs
a complete SHA-256 pass over approximately 12.7 GB and can take several
seconds; startup uses the quicker size/completeness check after installation.

```sh
bin/agent-lab mlx models list
bin/agent-lab mlx models verify
```

After package, model, or launch-setting changes, run the hardware integration
test. It checks Qwen text generation, exclusive switching, and Gemma image
reading, then restores the chat backend:

```sh
make test-mlx
```

Downloads require an online profile. Inference launch jobs force
`HF_HUB_OFFLINE=1`, so a missing or drifted snapshot fails instead of fetching
anything implicitly.

Normal chat and auxiliary tasks have deliberately separate output budgets.
Apply the normal-chat defaults after first start and after restoring an older
WebUI data volume:

```sh
config/open-webui/apply-chat-config.sh
```

Normal Qwen and Gemma answers receive up to 16,384 output tokens within a
32,768-token context. The task preset below remains capped at 64 tokens in its
separate 4,096-token context, so raising the chat budget cannot reintroduce
runaway title or tag generation.

## Open WebUI auxiliary tasks

Title generation, follow-up suggestions, automatic tags, and prompt
autocomplete are separate model requests. Apply the Agent Lab task preset after
first start and after restoring an older WebUI data volume:

```sh
config/open-webui/apply-task-config.sh
```

The preset reuses `qwen3.5:4b`, disables thinking, constrains responses to JSON,
and enforces a 64-token output limit. All four features remain enabled. When a
main answer uses MLX, this small Ollama task model may coexist briefly with the
active MLX model; Ollama still limits its own residency to one model. Without
this preset, the pinned Open WebUI/Ollama
combination can lose the task output cap, consume the entire 4,096-token
context, return unparseable metadata, and occupy the single local runner for
several minutes.

If the administrator password was changed in Open WebUI without updating the
ignored `.env`, either synchronize `WEBUI_ADMIN_PASSWORD` in that private file
or apply the preset once with `OPEN_WEBUI_ADMIN_PASSWORD` set in the shell.

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

## Incident triage and command safety

Run commands in this document from the repository root. Start with the
read-only diagnostics; they do not start a service, load or pull a model, or
change configuration:

```sh
bin/agent-lab status
bin/agent-lab health
bin/agent-lab status --json | jq .
```

`health` exits nonzero when any required check fails. Its final `action` text is
the first supported correction to try. Preserve that output and the relevant
logs before restarting anything when the same failure recurs.

The procedures below use these safety labels:

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

### Port 11434, 3000, 8081, or 8082 is already in use

1. **Read-only:** identify the owning process and, for a container, its name.

   ```sh
   lsof -nP -iTCP@127.0.0.1:11434 -sTCP:LISTEN
   lsof -nP -iTCP@127.0.0.1:3000 -sTCP:LISTEN
   lsof -nP -iTCP@127.0.0.1:8081 -sTCP:LISTEN
   lsof -nP -iTCP@127.0.0.1:8082 -sTCP:LISTEN
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
