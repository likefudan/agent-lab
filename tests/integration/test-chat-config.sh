#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

admin_email=${OPEN_WEBUI_ADMIN_EMAIL:-$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")}
admin_password=${OPEN_WEBUI_ADMIN_PASSWORD:-$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")}
OPEN_WEBUI_ADMIN_EMAIL="$admin_email" OPEN_WEBUI_ADMIN_PASSWORD="$admin_password" \
  "${ROOT}/config/open-webui/apply-chat-config.sh" >/dev/null

auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "${WEBUI_URL}/api/v1/auths/signin") || fail 'Open WebUI admin sign-in failed'
token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'

config=$(curl --fail --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${token}" "${WEBUI_URL}/api/v1/configs/models")
jq -e '.DEFAULT_MODEL_PARAMS.think == false and
  .DEFAULT_MODEL_PARAMS.temperature == 0 and
  .DEFAULT_MODEL_PARAMS.num_ctx == 8192 and
  .DEFAULT_MODEL_PARAMS.max_tokens == 4096 and
  .DEFAULT_MODEL_PARAMS.keep_alive == "5m"' <<<"$config" >/dev/null ||
  fail 'main-chat defaults do not match the long-response contract'

task_model=$(curl --fail --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${token}" \
  "${WEBUI_URL}/api/v1/models/model?id=agent-lab-task-qwen-4b")
jq -e '.params.max_tokens == 64 and .params.think == false and .params.format == "json"' \
  <<<"$task_model" >/dev/null || fail 'main-chat configuration changed the task-model cap'

printf '%s\n' 'PASS: main chat has 4,096 output tokens in an 8,192-token context while tasks remain capped at 64'
