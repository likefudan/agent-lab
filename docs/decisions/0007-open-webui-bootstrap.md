# Decision 0007: Open WebUI bootstrap and model presentation

Status: accepted

## Decision

Agent Lab bootstraps the pinned Open WebUI image with authentication enabled,
public signup disabled, loopback-only publishing, telemetry disabled, and one
generated local administrator. The administrator email and random password live
only in the ignored, mode-0600 `.env` file. `scripts/setup.sh` preserves an
existing file and data volume instead of rotating credentials or destroying
application state.

Open WebUI connects only to native Ollama at
`http://host.docker.internal:11434`. Its Ollama connection is classified as
`local` and presents exactly these qualified artifacts:

- `qwen3.5:4b`
- `qwen3.5:9b`
- `gemma4:12b`

The other locally retained artifacts are qualification evidence and are hidden
from normal browser use. The allowlist is seeded through
`OLLAMA_API_CONFIGS`; the smoke test also applies it through Open WebUI's
authenticated configuration API so an older persistent volume converges to the
same setting.

No cloud model endpoint, remote inference credential, automatic model pull, or
custom Agent Lab UI is configured. A missing model therefore fails at local
Ollama. Upstream Open WebUI branding remains intact.

## Verification

Run `tests/smoke/test-webui.sh` after `bin/agent-lab start`. It verifies the
authenticated API, exact model presentation, local text chat, multimodal image
input, conversation persistence across a container restart, and local failure
for an unavailable model without changing the Ollama model store.

The following UI-only checklist is recorded for the pinned release and should
be repeated after an Open WebUI upgrade:

1. Open `http://127.0.0.1:3000` and sign in with the values from the local
   `.env` file; confirm signup is unavailable.
2. Confirm the upstream Open WebUI name and visual branding are present.
3. Open the model selector and confirm it contains only the three artifacts
   listed above.
4. Send a text message to `qwen3.5:4b`, reload the browser, and confirm the
   conversation remains in history.
5. Attach `evals/fixtures/model-qualification/vision-card.svg.png` to
   `gemma4:12b` and confirm the reply identifies `AGENT 42`.
6. Confirm no cloud provider or remote connection is configured in the admin
   connections page.

The automated API path covers behavior and durable state; the checklist covers
browser rendering, branding, and controls that have no stable public API.
