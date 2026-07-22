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
time; setup and start never print it. If the password is changed in the
upstream UI, synchronize `WEBUI_ADMIN_PASSWORD` in `.env` so authenticated
configuration scripts continue to work, then continue treating the file as
sensitive.

After the first start, apply the local RAG and low-latency auxiliary-task
presets:

```sh
config/open-webui/apply-rag-config.sh
config/open-webui/apply-chat-config.sh
config/open-webui/apply-task-config.sh
config/open-webui/apply-mlx-config.sh
```

The MLX configuration preserves unrelated OpenAI-compatible connections, adds
the two loopback host bridges, and creates friendly Qwen/Gemma model presets.
Use `bin/agent-lab mlx start chat|vision` to choose which large MLX model is
actually resident.

Authentication settings are seeded into Open WebUI's database on first start.
The named `agent-lab-open-webui-data` volume contains the complete application
state and must be preserved and backed up as one unit.
