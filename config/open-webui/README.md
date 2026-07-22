# Open WebUI local configuration

Open WebUI reads nonsecret defaults from `compose.yaml` and its stable secret
from the ignored repository-root `.env` file. Create that file once with:

```sh
config/open-webui/generate-env.sh
```

The generator uses `openssl rand -hex 32`, creates the file with mode `0600`,
does not print the secret, and refuses to overwrite an existing file. Keep the
same `.env` across restarts so existing sessions remain valid.

The private file also contains a generated first-run administrator password for
`admin@localhost`. Read it directly from `.env` when signing in for the first
time; setup and start never print it. Change the password in the upstream UI
after first login, then continue treating `.env` as sensitive.

Authentication settings are seeded into Open WebUI's database on first start.
The named `agent-lab-open-webui-data` volume contains the complete application
state and must be preserved and backed up as one unit.

Inference provider wiring follows the active backend (see
`config/inference/README.md`). Default is Ollama via
`host.docker.internal:11434`. `agent-lab backend use <id>` /
`apply-inference` switches between the Ollama-native connection and an
OpenAI-compatible `/v1` connection; non-Ollama backends disable the Ollama
provider so chat cannot silently fall through. Optional second connection for
a vision split (`mlx_lm` + `mlx_vlm`) is documented under `config/inference/`.

## Chat model defaults (performance)

Open WebUI stores admin **DEFAULT_MODEL_PARAMS** in `webui.db`. Agent Lab's
approved baseline lives in `config/open-webui/model-params.json`:

- **Keep:** `think:false`, `max_tokens:512`, `num_ctx:4096`, `keep_alive:5m`
  (Think On and missing Max Tokens are what dominate latency. Admin
  `DEFAULT_MODEL_PARAMS` alone may not reach the browser; apply also writes
  these into the admin user's Chat Controls `ui.params`.)
- **Also apply:** title / tags / follow-up / autocomplete **on**, Memory **on**
  (not the main latency drivers when Max Tokens is enforced).

```sh
bin/agent-lab start
bin/agent-lab apply-webui-params
```

`apply-inference` also re-applies these when WebUI is reachable. Chat Controls →
**Think** and per-chat Advanced Params still override defaults. Do not put
`think` or `num_predict` in Advanced Params as **strings** — use the Controls
toggle and Default Model Params instead.
