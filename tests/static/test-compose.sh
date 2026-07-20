#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly IMAGE='ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4'
readonly PLACEHOLDER='replace-with-generated-64-character-hex-secret'
readonly ADMIN_PLACEHOLDER='replace-with-generated-32-character-hex-password'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || fail 'Docker CLI is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-compose.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

rendered="${temporary_dir}/compose.json"
docker compose \
  --project-directory "$ROOT" \
  --env-file "${ROOT}/.env.example" \
  -f "${ROOT}/compose.yaml" \
  config --format json > "$rendered"

[[ $(jq '.services | length' "$rendered") -eq 1 ]] ||
  fail 'Compose must contain exactly one MVP application service'
[[ $(jq -r '.services["open-webui"].image' "$rendered") == "$IMAGE" ]] ||
  fail 'Open WebUI image is not pinned to the approved immutable digest'
[[ $(jq -r '.services["open-webui"].ports[0].host_ip' "$rendered") == '127.0.0.1' ]] ||
  fail 'Open WebUI browser port is not bound to IPv4 loopback'
[[ $(jq -r '.services["open-webui"].ports[0].published' "$rendered") == '3000' ]] ||
  fail 'Open WebUI default browser port is not 3000'
[[ $(jq -r '.services["open-webui"].ports[0].target' "$rendered") == '8080' ]] ||
  fail 'Open WebUI container port is not 8080'
[[ $(jq -r '.volumes["open-webui-data"].name' "$rendered") == 'agent-lab-open-webui-data' ]] ||
  fail 'Open WebUI data volume does not use the approved durable name'
[[ $(jq -r '.volumes["open-webui-data"].external' "$rendered") == 'true' ]] ||
  fail 'setup-owned Open WebUI data volume must be declared external'
[[ $(jq -r '.services["open-webui"].volumes[0].target' "$rendered") == '/app/backend/data' ]] ||
  fail 'Open WebUI data volume is not mounted at the documented data directory'
[[ $(jq -r '.services["open-webui"].environment.OLLAMA_BASE_URL' "$rendered") == 'http://host.docker.internal:11434' ]] ||
  fail 'Open WebUI does not use the Docker-to-host Ollama endpoint'
[[ $(jq -r '.services["open-webui"].environment.ENABLE_OLLAMA_API' "$rendered") == 'true' ]] ||
  fail 'Open WebUI Ollama API must default to enabled (ollama active backend)'
[[ $(jq -r '.services["open-webui"].environment.ENABLE_OPENAI_API' "$rendered") == 'false' ]] ||
  fail 'Open WebUI OpenAI API must default to disabled (no silent hosted/Ollama fallthrough)'
approved_models=$(jq -c '.services["open-webui"].environment.OLLAMA_API_CONFIGS | fromjson | .["0"].model_ids' "$rendered")
[[ $approved_models == '["qwen3.5:4b","qwen3.5:9b","gemma4:12b"]' ]] ||
  fail 'Open WebUI model presentation is not restricted to approved artifacts'
[[ $(jq -r '.services["open-webui"].environment.OLLAMA_API_CONFIGS | fromjson | .["0"].connection_type' "$rendered") == 'local' ]] ||
  fail 'Open WebUI Ollama connection is not explicitly classified as local'
[[ $(jq -r '.services["open-webui"].environment.RAG_EMBEDDING_MODEL' "$rendered") == 'sentence-transformers/all-MiniLM-L6-v2' ]] ||
  fail 'Open WebUI does not use the approved local embedding model'
[[ $(jq -r '.services["open-webui"].environment.RAG_EMBEDDING_MODEL_AUTO_UPDATE' "$rendered") == 'false' ]] ||
  fail 'Open WebUI embedding auto-update must be disabled'
[[ $(jq -r '.services["open-webui"].environment.RAG_EMBEDDING_MODEL_TRUST_REMOTE_CODE' "$rendered") == 'false' ]] ||
  fail 'Open WebUI embedding model must not execute remote code'
[[ $(jq -r '.services["open-webui"].environment.VECTOR_DB' "$rendered") == 'chroma' ]] ||
  fail 'Open WebUI does not use its built-in persistent Chroma store'
[[ $(jq -r '.services["open-webui"].environment.ENABLE_VERSION_UPDATE_CHECK' "$rendered") == 'false' ]] ||
  fail 'Open WebUI version checks must be disabled in every profile'
jq -e '.services["open-webui"].healthcheck.test | index("http://127.0.0.1:8080/health")' "$rendered" >/dev/null ||
  fail 'Open WebUI lacks the approved HTTP health probe'
[[ $(jq -r '.services["open-webui"].logging.options["max-size"]' "$rendered") == '10m' ]] ||
  fail 'Open WebUI log size is not bounded'
[[ $(jq -r '.services["open-webui"].logging.options["max-file"]' "$rendered") == '3' ]] ||
  fail 'Open WebUI rotated log count is not bounded'
jq -e '.services["open-webui"].privileged // false | not' "$rendered" >/dev/null ||
  fail 'Open WebUI must not use privileged mode'

if jq -e '.services | has("docling") or has("searxng")' "$rendered" >/dev/null; then
  fail 'deferred Docling or SearXNG service was added to the MVP Compose file'
fi

generated_env="${temporary_dir}/generated.env"
generator_output="${temporary_dir}/generator.out"
"${ROOT}/config/open-webui/generate-env.sh" --output "$generated_env" > "$generator_output"
[[ $(stat -f '%Lp' "$generated_env") == '600' ]] ||
  fail 'generated environment file does not have mode 0600'
generated_secret=$(sed -n 's/^WEBUI_SECRET_KEY=//p' "$generated_env")
generated_admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$generated_env")
[[ $generated_secret =~ ^[0-9a-f]{64}$ ]] ||
  fail 'generated WEBUI_SECRET_KEY is not a 256-bit hexadecimal secret'
[[ $generated_admin_password =~ ^[0-9a-f]{32}$ ]] ||
  fail 'generated WEBUI_ADMIN_PASSWORD is not a 128-bit hexadecimal password'
! grep -Fq "$generated_secret" "$generator_output" ||
  fail 'environment generator printed the generated secret'
! grep -Fq "$generated_admin_password" "$generator_output" ||
  fail 'environment generator printed the generated admin password'
if "${ROOT}/config/open-webui/generate-env.sh" --output "$generated_env" >/dev/null 2>&1; then
  fail 'environment generator overwrote an existing file'
fi

tracked_candidates=$(git -C "$ROOT" ls-files --cached --others --exclude-standard)
if [[ -n "$tracked_candidates" ]] &&
  printf '%s\n' "$tracked_candidates" |
    xargs rg -n '^WEBUI_SECRET_KEY=[0-9A-Fa-f]{32,}$' >/dev/null; then
  fail 'a real-looking WEBUI_SECRET_KEY exists in a tracked or unignored file'
fi
grep -Fqx "WEBUI_SECRET_KEY=${PLACEHOLDER}" "${ROOT}/.env.example" ||
  fail '.env.example must contain only the documented secret placeholder'
grep -Fqx "WEBUI_ADMIN_PASSWORD=${ADMIN_PLACEHOLDER}" "${ROOT}/.env.example" ||
  fail '.env.example must contain only the documented admin-password placeholder'

printf '%s\n' 'PASS: pinned and local-only Open WebUI Compose configuration'
