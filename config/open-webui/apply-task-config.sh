#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly TASK_MODEL_ID='agent-lab-task-qwen-4b'
readonly TASK_BASE_MODEL='qwen3.5:4b'
readonly TASK_MAX_TOKENS=64

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

api() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl --fail --silent --show-error --max-time 60 -X "$method" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
      --data "$body" "${WEBUI_URL}${path}"
  else
    curl --fail --silent --show-error --max-time 60 -X "$method" \
      -H "Authorization: Bearer ${token}" "${WEBUI_URL}${path}"
  fi
}

preset=$(jq -cn \
  --arg id "$TASK_MODEL_ID" \
  --arg base "$TASK_BASE_MODEL" \
  --argjson max_tokens "$TASK_MAX_TOKENS" \
  '{
    id:$id,
    base_model_id:$base,
    name:"Agent Lab Tasks (Qwen 4B)",
    meta:{description:"Low-latency local preset for Open WebUI auxiliary tasks."},
    params:{think:false,temperature:0,num_ctx:4096,max_tokens:$max_tokens,keep_alive:"5m",format:"json"},
    access_grants:[],
    is_active:true
  }')

status_file=$(mktemp "${TMPDIR:-/tmp}/agent-lab-task-model.XXXXXX")
trap 'rm -f -- "$status_file"' EXIT HUP INT TERM
status=$(curl --silent --show-error --max-time 30 -o "$status_file" -w '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  "${WEBUI_URL}/api/v1/models/model?id=${TASK_MODEL_ID}") ||
  fail 'failed to inspect the Open WebUI task model preset'

case $status in
  200) response=$(api POST /api/v1/models/model/update "$preset") ;;
  404) response=$(api POST /api/v1/models/create "$preset") ;;
  *) fail "unexpected task model lookup status: ${status}" ;;
esac

jq -e \
  --arg id "$TASK_MODEL_ID" \
  --arg base "$TASK_BASE_MODEL" \
  --argjson max_tokens "$TASK_MAX_TOKENS" \
  '.id == $id and .base_model_id == $base and .params.think == false and
   .params.temperature == 0 and .params.num_ctx == 4096 and
   .params.max_tokens == $max_tokens and .params.format == "json" and
   .is_active == true' \
  <<<"$response" >/dev/null || fail 'Open WebUI did not persist the approved task model preset'

# Refresh the in-process model registry before selecting the newly created preset.
api GET /api/models >/dev/null

task_config=$(api GET /api/v1/tasks/config)
task_config=$(jq --arg id "$TASK_MODEL_ID" '.TASK_MODEL = $id' <<<"$task_config")
response=$(api POST /api/v1/tasks/config/update "$task_config")
jq -e --arg id "$TASK_MODEL_ID" \
  '.TASK_MODEL == $id and .ENABLE_TITLE_GENERATION == true and
   .ENABLE_FOLLOW_UP_GENERATION == true and .ENABLE_TAGS_GENERATION == true and
   .ENABLE_AUTOCOMPLETE_GENERATION == true' <<<"$response" >/dev/null ||
  fail 'Open WebUI did not select the task preset while preserving auxiliary features'

printf 'PASS: Open WebUI auxiliary tasks use %s with a %s-token cap\n' \
  "$TASK_MODEL_ID" "$TASK_MAX_TOKENS"
