# 0004 — Open WebUI compatibility baseline

- **Status:** Accepted
- **Verified:** 2026-07-18
- **Component:** Open WebUI `0.10.2`
- **Target:** Docker Desktop 4.80.0 on Apple Silicon macOS

## Decision

Use the unmodified upstream Open WebUI `0.10.2` container as Agent Lab's MVP
web application. Pin the multi-platform OCI index as
`ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4`.
On the qualified Apple Silicon host, that index resolves to the Linux/arm64
manifest
`sha256:0d58a66704d69e52da83f72bcd43869ad4fd0c761313778bc95ef6940a0b81e3`.
The image reports `v0.10.2` at startup and embeds upstream revision
`ecd48e2f718220a6400ecf49eafd4867a38feb10`, which is also the commit targeted
by tag `v0.10.2`.

Publish container port `8080` only as `127.0.0.1:3000`. Mount the named volume
`agent-lab-open-webui-data` at `/app/backend/data`, and connect to native Ollama
with `OLLAMA_BASE_URL=http://host.docker.internal:11434`. Open WebUI remains the
upstream application: Agent Lab does not fork, rebrand, or replace its UI.

## Artifact and source evidence

| Property | Selected or observed value |
| --- | --- |
| Release | [`v0.10.2`](https://github.com/open-webui/open-webui/releases/tag/v0.10.2), published 2026-07-01 |
| Source revision | [`ecd48e2f718220a6400ecf49eafd4867a38feb10`](https://github.com/open-webui/open-webui/commit/ecd48e2f718220a6400ecf49eafd4867a38feb10) |
| Image repository | `ghcr.io/open-webui/open-webui` |
| OCI index digest | `sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4` |
| Linux/arm64 digest | `sha256:0d58a66704d69e52da83f72bcd43869ad4fd0c761313778bc95ef6940a0b81e3` |
| Container data directory | `/app/backend/data` |
| Container health endpoint | `GET /health` on port `8080` |
| Qualified host URL | `http://127.0.0.1:3000` |

The digest was resolved from GHCR's OCI registry API and then pulled by the
arm64 digest. `docker image inspect`, the embedded `/app/build/_app/version.json`,
and the exact image's Python sources were inspected after the pull. Hosted
documentation is useful context, but the configuration table below is based on
the selected image rather than a different moving release.

## License and branding

This release is a multi-license codebase. Newer work is governed by the
[`Open WebUI License`](https://github.com/open-webui/open-webui/blob/v0.10.2/LICENSE),
while older contributions retain the MIT or BSD 3-Clause terms identified in
[`LICENSE_NOTICE`](https://github.com/open-webui/open-webui/blob/v0.10.2/LICENSE_NOTICE)
and
[`LICENSE_HISTORY`](https://github.com/open-webui/open-webui/blob/v0.10.2/LICENSE_HISTORY).
The current license prohibits changing, removing, obscuring, or replacing Open
WebUI branding except for deployments with no more than 50 end users in a
rolling 30-day period, written permission, or an applicable enterprise
license. Agent Lab takes the simpler and safer path: run the upstream UI
unmodified with its branding intact and reproduce the required license notice
with distributions.

## Verified configuration contract

These names and semantics exist in the pinned `0.10.2` image. A later upgrade
must recheck the new image source before changing executable configuration.

| Area | Pinned keys and decision | Persistence behavior |
| --- | --- | --- |
| Ollama | `OLLAMA_BASE_URL=http://host.docker.internal:11434`; `ENABLE_OLLAMA_API=true` | Connection defaults are seeded into the configuration database on first start. Existing database values take precedence while persistent configuration is enabled. |
| Authentication | `WEBUI_AUTH=true`, `ENABLE_SIGNUP=false`, `ENABLE_LOGIN_FORM=true` | Auth and signup defaults are seeded on first start; later admin changes are database-backed. Authentication is retained across restarts in the data volume. |
| Bootstrap admin | Optional first-run-only `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`, and `WEBUI_ADMIN_NAME` | Creates the initial administrator when credentials are supplied and no user exists. Production setup must not commit or log the password. Interactive first-user signup is also supported but is not the automated bootstrap path. |
| Secrets | `WEBUI_SECRET_KEY` | A non-empty secret is a hard requirement when authentication is enabled. Generate it outside Git, keep it stable across restarts, and pass it from a local ignored secret source. `WEBUI_JWT_SECRET_KEY` is deprecated. |
| Data | `DATA_DIR=/app/backend/data` (image default) | The named volume contains `webui.db`, users, chats, per-key configuration, uploads, local knowledge documents, caches, embedding assets, and vector data under `vector_db`. Back up the whole volume consistently. |
| Persistent settings | `ENABLE_PERSISTENT_CONFIG=true` (default) | Version `0.10.2` stores each configuration key as a row in `webui.db`. Environment values seed missing keys; they do not overwrite existing rows. Set `ENABLE_PERSISTENT_CONFIG=false` only when a profile intentionally requires environment values to remain authoritative. |
| Embeddings | `RAG_EMBEDDING_ENGINE`, `RAG_EMBEDDING_MODEL`, `RAG_EMBEDDING_MODEL_AUTO_UPDATE` | Engine/model are database-backed defaults. The standard image includes `sentence-transformers/all-MiniLM-L6-v2`; P0-T05 selects the production model. Offline profiles set auto-update false. |
| Reranking | `RAG_RERANKING_ENGINE`, `RAG_RERANKING_MODEL`, `RAG_RERANKING_MODEL_AUTO_UPDATE` | Database-backed defaults; blank disables local reranking. P0-T05 decides whether measured retrieval gains justify a model. Offline profiles set auto-update false. |
| Extraction | `CONTENT_EXTRACTION_ENGINE`; blank selects built-in extraction | Database-backed. External Docling or another engine remains deferred until the acceptance corpus demonstrates a gap. |
| Hybrid retrieval | `ENABLE_RAG_HYBRID_SEARCH` and `RAG_HYBRID_BM25_WEIGHT` | Database-backed. P5 owns the measured production settings. |
| Web search | `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE`; `duckduckgo` is implemented by this image | Database-backed. It remains disabled in offline mode and is enabled only by the later online profiles. |
| Offline/update behavior | `OFFLINE_MODE=true`, `ENABLE_VERSION_UPDATE_CHECK=false`, `RAG_EMBEDDING_MODEL_AUTO_UPDATE=false`, `RAG_RERANKING_MODEL_AUTO_UPDATE=false` | `OFFLINE_MODE` also forces `HF_HUB_OFFLINE=1` and disables the version check in this release. Image upgrades remain an explicit Agent Lab operation; Open WebUI does not replace its running container. |
| Telemetry | `SCARF_NO_ANALYTICS=true`, `DO_NOT_TRACK=true`, `ANONYMIZED_TELEMETRY=false` | These are already defaults in the selected standard image and are set explicitly by Agent Lab so privacy intent survives image-default changes. Strict offline verification still supplies the network-boundary proof. |

The upstream [environment variable reference](https://docs.openwebui.com/reference/env-configuration/)
describes the broader surface. The source files at the pinned revision are the
authority for this decision, notably
[`env.py`](https://github.com/open-webui/open-webui/blob/ecd48e2f718220a6400ecf49eafd4867a38feb10/backend/open_webui/env.py),
[`config.py`](https://github.com/open-webui/open-webui/blob/ecd48e2f718220a6400ecf49eafd4867a38feb10/backend/open_webui/config.py),
and the database-backed
[`models/config.py`](https://github.com/open-webui/open-webui/blob/ecd48e2f718220a6400ecf49eafd4867a38feb10/backend/open_webui/models/config.py).

## Runtime verification

Docker Desktop `4.80.0` (engine `29.6.1`) ran the exact Linux/arm64 manifest in
an isolated container with a uniquely named temporary volume. Results:

- Docker reported the container healthy, with `GET /` and `GET /health`
  returning HTTP 200 and no restart.
- The published binding was exactly `127.0.0.1:3000 -> 8080/tcp`; no wildcard
  host bind was used.
- Startup reported `v0.10.2`, created `webui.db`, loaded the bundled local
  embedding model while `OFFLINE_MODE=true`, and skipped external plug-in
  dependency installation.
- `WEBUI_ADMIN_*` created the temporary administrator; an authenticated signin
  returned the expected `admin` role while public API access returned 401.
- Through `host.docker.internal`, Open WebUI's Ollama proxy listed the two local
  Ollama models. A proxied native `POST /ollama/api/chat` to
  `qwen3.5:4b-mlx`, with thinking disabled and `keep_alive: 0`, completed
  locally with the exact response `bridge-ok` and `done_reason: stop`.
- Restarting against the same named volume retained the database-backed test
  state. The task then removed only its `agent-lab-p0t04-*` container and
  volume. No unrelated Docker image, container, volume, or Ollama model was
  changed or removed.

The bridge test used the already-approved Ollama `0.32.1` binary on
`127.0.0.1:11434`, with cloud disabled and the one-model limit. It did not use
remote inference. The downloaded pinned container image and its bundled assets
remain cached so later work can run offline.

## Reproduction outline

Production Compose is added by P3-T01. Its effective settings must be
equivalent to this outline, with the secret and optional bootstrap credentials
supplied outside version control:

```sh
docker run --detach \
  --name open-webui \
  --publish 127.0.0.1:3000:8080 \
  --volume agent-lab-open-webui-data:/app/backend/data \
  --env OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  --env WEBUI_AUTH=true \
  --env ENABLE_SIGNUP=false \
  --env WEBUI_SECRET_KEY='<generated-local-secret>' \
  --env SCARF_NO_ANALYTICS=true \
  --env DO_NOT_TRACK=true \
  --env ANONYMIZED_TELEMETRY=false \
  ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4
```

Do not copy the literal placeholder into a deployment. Profile tasks add
offline/search settings; RAG tasks add only models that their decision gates
approve.

## Consequences

- P0-T05 may evaluate local embedding and reranking models against this exact
  Open WebUI release and its database/environment semantics.
- P3-T01 must pin the OCI index digest, bind only to loopback, use the selected
  production volume name, and require a stable ignored secret.
- P3-T02 must avoid assuming that changing an environment value updates an
  existing database-backed setting. Profile changes must either use the
  supported admin/config API or explicitly disable persistent configuration
  when environment-authoritative behavior is intended.
- P5 and P6 own the final RAG and web-search values. This task verifies their
  configuration keys; it does not silently select retrieval models or enable
  online search.
- An Open WebUI upgrade requires a new digest, license review, source-key
  inspection, database migration test, bootstrap test, host-bridge request,
  and persistence/backup compatibility test.
