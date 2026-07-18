# Privacy and network boundaries

Local prompts, chats, uploads, vectors, and model inference remain on this Mac
in normal Agent Lab operation. Open WebUI stores application data in the named
Docker volume; Ollama stores approved model artifacts under its user model
store. LLM CLI and Aider maintain separate ignored histories.

The offline profile recreates Open WebUI with `OFFLINE_MODE=true`, disables
search and version/update checks, prevents embedding/reranker downloads, blocks
Agent Lab model pulls, disables remote tools and telemetry, and presents only
the three approved local Ollama artifacts. Ollama is loopback-only with its
cloud integration disabled.

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
`bin/agent-lab offline verify --config-only --quick`. The command labels its
result `configuration_only`, tests local denial paths, and restores the prior
profile in its exit and signal traps.

Online-manual is the default connected profile. DuckDuckGo is contacted only
after the user explicitly chooses search. Online-automatic permits the local
model to select the search tool. Search queries, result URLs, and fetched page
content leave the computer in both online modes; hosted model inference remains
unconfigured. Treat fetched content as untrusted and review citations.
