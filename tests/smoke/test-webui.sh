#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly EXPECTED_MODELS='["gemma4:12b","qwen3.5:4b","qwen3.5:9b"]'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v docker >/dev/null 2>&1 || fail 'Docker CLI is required'
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup before this smoke test'

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")
[[ -n $admin_email && -n $admin_password ]] || fail 'Open WebUI admin credentials are missing from .env'

api() {
  local method=$1
  local path=$2
  local body=${3:-}
  if [[ -n $body ]]; then
    curl --fail --silent --show-error --max-time 180 \
      -X "$method" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${token}" \
      --data "$body" "${WEBUI_URL}${path}"
  else
    curl --fail --silent --show-error --max-time 180 \
      -X "$method" -H "Authorization: Bearer ${token}" \
      "${WEBUI_URL}${path}"
  fi
}

sign_in() {
  local response
  response=$(curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
    "${WEBUI_URL}/api/v1/auths/signin") || fail 'Open WebUI admin sign-in failed'
  token=$(jq -er '.token' <<<"$response") || fail 'Open WebUI sign-in returned no token'
}

wait_for_webui() {
  local attempt
  for attempt in {1..90}; do
    if curl --fail --silent --max-time 2 "${WEBUI_URL}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  fail 'Open WebUI did not become healthy after restart'
}

sign_in

# Persist the same allowlist that seeds fresh installations. This also upgrades
# an existing volume created before the allowlist was introduced.
config_body=$(jq -cn '{ENABLE_OLLAMA_API:true,OLLAMA_BASE_URLS:["http://host.docker.internal:11434"],OLLAMA_API_CONFIGS:{"0":{enable:true,connection_type:"local",model_ids:["qwen3.5:4b","qwen3.5:9b","gemma4:12b"]}}}')
api POST /ollama/config/update "$config_body" >/dev/null

models=$(api GET /ollama/api/tags | jq -c '[.models[].model] | sort')
[[ $models == "$EXPECTED_MODELS" ]] || fail "model selector received unexpected models: ${models}"

text_response=$(api POST /ollama/api/chat \
  '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Reply with exactly WEBUI-LOCAL-OK"}],"stream":false,"think":false,"keep_alive":0}')
[[ $(jq -r '.message.content' <<<"$text_response") == *'WEBUI-LOCAL-OK'* ]] ||
  fail 'local text chat did not return the expected marker'

marker="agent-lab-persistence-$(date +%s)"
chat_body=$(jq -cn --arg marker "$marker" '{chat:{title:"Agent Lab persistence smoke",messages:[{id:"smoke-user",role:"user",content:$marker,timestamp:0}],models:["qwen3.5:4b"],history:{messages:{},currentId:null}}}')
chat_response=$(api POST /api/v1/chats/new "$chat_body")
chat_id=$(jq -er '.id' <<<"$chat_response") || fail 'failed to create persistence test conversation'
cleanup() {
  if [[ -n ${token:-} && -n ${chat_id:-} ]]; then
    api DELETE "/api/v1/chats/${chat_id}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM

docker compose --project-directory "$ROOT" -f "${ROOT}/compose.yaml" restart open-webui >/dev/null
wait_for_webui
sign_in
persisted=$(api GET "/api/v1/chats/${chat_id}")
[[ $(jq -r '.chat.messages[0].content' <<<"$persisted") == "$marker" ]] ||
  fail 'conversation did not persist across an Open WebUI restart'
# Open WebUI initializes its in-memory provider routing table when the model
# catalog is requested, as the browser does before starting a conversation.
models_after_restart=$(api GET /ollama/api/tags | jq -c '[.models[].model] | sort')
[[ $models_after_restart == "$EXPECTED_MODELS" ]] ||
  fail "model selector changed after restart: ${models_after_restart}"

image_b64=$(base64 < "${ROOT}/evals/fixtures/model-qualification/vision-card.svg.png" | tr -d '\n')
vision_body=$(jq -cn --arg image "$image_b64" '{model:"gemma4:12b",messages:[{role:"user",content:"Read the large identifying text in this image. Reply with only that text.",images:[$image]}],stream:false,think:false,keep_alive:0}')
vision_response=$(api POST /ollama/api/chat "$vision_body")
[[ $(jq -r '.message.content' <<<"$vision_response") == *'AGENT 42'* ]] ||
  fail 'image chat did not reach the approved multimodal model'

before_models=$(curl --fail --silent --show-error http://127.0.0.1:11434/api/tags | jq -c '[.models[].name] | sort')
missing_body='{"model":"agent-lab/definitely-missing:never","messages":[{"role":"user","content":"hello"}],"stream":false}'
missing_response=$(mktemp "${TMPDIR:-/tmp}/agent-lab-webui-missing.XXXXXX")
http_code=$(curl --silent --output "$missing_response" --write-out '%{http_code}' --max-time 30 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  --data "$missing_body" "${WEBUI_URL}/ollama/api/chat")
[[ $http_code == '400' || $http_code == '404' ]] ||
  fail "unavailable model returned unexpected HTTP ${http_code}"
jq -e '((.detail // .error // "") | ascii_downcase) | contains("model") and contains("not found")' "$missing_response" >/dev/null ||
  fail 'unavailable model did not return an explicit local not-found error'
rm -f -- "$missing_response"
after_models=$(curl --fail --silent --show-error http://127.0.0.1:11434/api/tags | jq -c '[.models[].name] | sort')
[[ $after_models == "$before_models" ]] || fail 'unavailable-model request changed the local model store'

printf '%s\n' 'PASS: Open WebUI local chat, image input, presentation, and persistence'
