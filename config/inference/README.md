# Inference client wiring (P10-T05)

Agent Lab day-to-day clients talk to one **active backend** selected with
`agent-lab backend use <id>` (default `ollama`). That command records
`~/.agent-lab/state/active-backend` and runs `apply-inference`, which writes:

| Artifact | Purpose |
| --- | --- |
| `~/.agent-lab/state/inference.env` | `AGENT_LAB_INFERENCE_BACKEND`, Compose Ollama/OpenAI flags, OpenAI `/v1` URL |
| `.agent-lab/llm/` | LLM CLI runtime (`environment.env`, aliases, optional `extra-openai-models.yaml`) |
| `.agent-lab/aider/` | Aider runtime (`aider.conf.yml` pointed at the active `/v1`) |
| Open WebUI providers | API update when WebUI is healthy (Ollama-native only for `ollama`) |

Re-run without changing the active id:

```sh
bin/agent-lab apply-inference
# or
bin/agent-lab apply-inference mlx_lm --skip-webui
```

## Client contract

- Prefer OpenAI-compatible `http://127.0.0.1:<port>/v1` for every backend.
- Ollama-native WebUI / `llm-ollama` are used **only** when the active backend is
  `ollama`. Non-Ollama paths set `ENABLE_OLLAMA_API=false` and exclude the
  `llm-ollama` plugin so requests cannot silently fall through Ollama.
- Compose loads `.env` then `inference.env` (later wins). Profile apply
  (`config/open-webui/apply-profile.sh`) keeps offline search/pull blocks and
  still honors the active inference env.

## Optional vision split (second Open WebUI connection)

Text/coding and vision may live on different servers (for example `mlx_lm` on
`:11435` and `mlx_vlm` on `:11436`) without a custom gateway. Day-to-day
`backend use` wires a **single** active connection. Operators who need both can
add a second OpenAI connection in the Open WebUI admin UI to the other
loopback `/v1` URL and pin model ids from `config/models.json`. LLM CLI and
Aider still target only the active backend unless pointed elsewhere manually.
Full ops documentation is P10-T07; this note is the minimum wiring guidance.

See also: `docs/decisions/0011-inference-backends.md`,
`docs/decisions/0012-backend-model-pins.md`,
`docs/installation.md#optional-inference-backends-post-mvp`,
`docs/operations.md#inference-backends`,
`docs/privacy.md#multi-backend-weights-and-downloads`.
