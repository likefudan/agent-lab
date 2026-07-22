#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly CHAT_MAX_TOKENS=16384
readonly CHAT_CONTEXT_TOKENS=32768

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup first'

admin_email=${OPEN_WEBUI_ADMIN_EMAIL:-$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")}
admin_password=${OPEN_WEBUI_ADMIN_PASSWORD:-$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")}
[[ -n $admin_email && -n $admin_password ]] || fail 'Open WebUI administrator credentials are missing'

auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "${WEBUI_URL}/api/v1/auths/signin") ||
  fail 'Open WebUI admin sign-in failed; synchronize .env after changing the UI password or set OPEN_WEBUI_ADMIN_PASSWORD'
token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'

config=$(curl --fail --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${token}" "${WEBUI_URL}/api/v1/configs/models") ||
  fail 'failed to read Open WebUI model defaults'
body=$(jq --argjson max_tokens "$CHAT_MAX_TOKENS" --argjson context_tokens "$CHAT_CONTEXT_TOKENS" \
  '.DEFAULT_MODEL_PARAMS = ((.DEFAULT_MODEL_PARAMS // {}) + {
    think:false,
    temperature:0,
    num_ctx:$context_tokens,
    max_tokens:$max_tokens,
    keep_alive:"5m"
  })' <<<"$config")
response=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  --data "$body" "${WEBUI_URL}/api/v1/configs/models") ||
  fail 'failed to update Open WebUI model defaults'

jq -e --argjson max_tokens "$CHAT_MAX_TOKENS" --argjson context_tokens "$CHAT_CONTEXT_TOKENS" \
  '.DEFAULT_MODEL_PARAMS.think == false and
   .DEFAULT_MODEL_PARAMS.temperature == 0 and
   .DEFAULT_MODEL_PARAMS.num_ctx == $context_tokens and
   .DEFAULT_MODEL_PARAMS.max_tokens == $max_tokens and
   .DEFAULT_MODEL_PARAMS.keep_alive == "5m"' <<<"$response" >/dev/null ||
  fail 'Open WebUI did not persist the approved main-chat defaults'

printf 'PASS: Open WebUI main chat uses a %s-token output cap and %s-token context\n' \
  "$CHAT_MAX_TOKENS" "$CHAT_CONTEXT_TOKENS"
