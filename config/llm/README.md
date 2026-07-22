# LLM CLI configuration seed

These files are the versioned source for Agent Lab's LLM CLI configuration when
the active backend is `ollama`. Prefer `agent-lab backend use <id>` /
`agent-lab apply-inference`, which write the private runtime under
`.agent-lab/llm/` for the active backend (Ollama-native or OpenAI `/v1`).

## Day-to-day (recommended)

```sh
# Install once (pinned; see docs/installation.md)
uv tool install --from 'llm==0.31.1' llm --with 'llm-ollama==0.16.1'

bin/agent-lab start                 # Ollama / active backend
bin/agent-lab apply-inference       # refresh .agent-lab/llm/
bin/agent-lab llm -m qwen-4b -o think false -o num_predict 256 '世界杯是什么？'
bin/agent-lab llm -m qwen-9b chat -o think false
```

`bin/agent-lab llm` sets `LLM_USER_PATH` to `.agent-lab/llm/` and loads the
active-backend `environment.env`. Use `-o think false` so Qwen does not burn
the token budget on hidden reasoning (same lesson as Open WebUI).

## Manual copy (ollama path only)

```sh
mkdir -p .agent-lab/llm
cp config/llm/aliases.json config/llm/default_model.txt \
  config/llm/logs-off .agent-lab/llm/
cp config/llm/environment.env .agent-lab/llm/
export LLM_USER_PATH="$PWD/.agent-lab/llm"
set -a; . .agent-lab/llm/environment.env; set +a
```

For non-Ollama backends, the generated runtime sets `LLM_LOAD_PLUGINS=-llm-ollama`
and `extra-openai-models.yaml` so requests go only to the active `/v1` URL.

`LLM_USER_PATH` must not point at this source directory: `llm-ollama` writes a
capability cache beneath it. The runtime directory is ignored by Git. The
checked-in `logs-off` marker requests disabled SQLite logging by default.
Interactive chat in the pinned CLI can still create private conversation state,
so treat the entire runtime directory as sensitive. Delete the copied marker
only if you deliberately want logging enabled for all commands. Never copy
`keys.json`, `logs.db`, or plugin caches back here.
