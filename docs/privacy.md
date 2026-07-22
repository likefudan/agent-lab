# Privacy and network boundaries

Local prompts, chats, uploads, vectors, and model inference remain on this Mac
in normal Agent Lab operation. Open WebUI stores application data in its named
Docker volume; Ollama stores approved model artifacts under its user model
store. LLM CLI and Aider maintain separate ignored histories.

The offline profile recreates Open WebUI with `OFFLINE_MODE=true`, disables
search and version/update checks, prevents embedding/reranker downloads, blocks
Agent Lab model pulls, disables remote tools and telemetry, and presents only
the three approved local Ollama artifacts. Ollama is loopback-only with its
cloud integration disabled.

## Local data locations

| Data | Location | Backup behavior |
| --- | --- | --- |
| Open WebUI accounts, password hashes, chats, uploads, settings, Chroma vectors, and embedding cache | Docker volume `agent-lab-open-webui-data`, mounted at `/app/backend/data` | Included in `agent-lab backup` |
| Open WebUI secret and generated local administrator credentials | Repository `.env` (ignored, mode 600) | Included in backup configuration |
| Ollama model manifests and blobs | `~/.ollama/models` unless `OLLAMA_MODELS` overrides it | Excluded; reproduced from the digest-pinned catalog |
| Selected profile and test/benchmark evidence | Repository `.agent-lab/` (ignored) | Excluded; versioned profile definitions are included, while generated evidence should be archived separately when required |
| Managed Ollama logs | `~/.agent-lab/logs/` | Excluded |
| LLM CLI state | Repository `.agent-lab/llm/` when configured as documented | Private; separate from WebUI backup |
| Aider history | Repository `.agent-lab/aider/` and target-repository Aider files | Private; separate from WebUI backup |

The Docker volume is not encrypted by Agent Lab. Protection at rest depends on
macOS FileVault and the security of the signed-in account. Backups may contain
all WebUI private data plus credentials and should be written only to an
encrypted, access-controlled destination. Do not commit `.env`, `.agent-lab/`,
client histories, exports, uploaded source documents, or backup archives.

## Profile semantics and disclosure

`online-manual` is the default connected profile. DuckDuckGo is contacted only
after the user explicitly chooses search. `online-automatic` permits the local
model to select the search tool. In both online profiles, search queries, result
URLs, the client IP address, and fetched public page content can be disclosed to
third-party search and website operators. Hosted model inference remains
unconfigured. Treat fetched content as untrusted and review citations.

The `offline` profile prevents the supported Agent Lab paths from searching,
pulling models, updating caches, or using remote tools. It does not disable the
Mac's network interface and cannot constrain unrelated processes.

## Strict offline acceptance

Configuration is not a physical firewall. A process defect could bypass an
application setting, so a strict zero-egress claim additionally requires a
user-controlled boundary. Agent Lab never edits `pf`, LuLu rules, Wi-Fi, or
Ethernet state without the operator. The exact verification protocol is:

1. Warm and verify every model and embedding cache while online.
2. Turn off Wi-Fi and disconnect Ethernet, or apply reviewed LuLu block rules
   for Docker Desktop and Ollama while retaining loopback/local traffic.
3. Run `bin/agent-lab offline verify --boundary-confirmed --full`.
4. Review `.agent-lab/results/offline-latest.json` and re-enable networking.

For routine regression without a firewall claim, run
`bin/agent-lab offline verify --config-only --full`. The command labels its
result `configuration_only`, tests local denial paths, and restores the prior
profile in its exit and signal traps.

The configuration-only full matrix has passed on the qualified host. The
physical/LuLu run has **not yet been completed in the current release
qualification** and remains an explicit manual acceptance item. Until a clean
`user_attested_boundary_webui_probe_passed` result is reviewed, describe Agent Lab
as offline-first
and locally functional without internet—not as independently proven
zero-egress.

The verifier writes its evidence under `.agent-lab/results/`, restores the
previous profile on normal exit and handled signals, and never disables or
reenables Wi-Fi, Ethernet, `pf`, or LuLu itself. Preserve the result alongside
the release evidence before reconnecting.
