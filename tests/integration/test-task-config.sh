#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly TASK_MODEL_ID='agent-lab-task-qwen-4b'
readonly MAX_SECONDS=15

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

admin_email=${OPEN_WEBUI_ADMIN_EMAIL:-$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")}
admin_password=${OPEN_WEBUI_ADMIN_PASSWORD:-$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")}
auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "${WEBUI_URL}/api/v1/auths/signin") || fail 'Open WebUI admin sign-in failed'
token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'

api() {
  local path=$1 body=$2
  curl --fail --silent --show-error --max-time "$MAX_SECONDS" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
    --data "$body" "${WEBUI_URL}${path}"
}

OPEN_WEBUI_ADMIN_EMAIL="$admin_email" OPEN_WEBUI_ADMIN_PASSWORD="$admin_password" \
  "${ROOT}/config/open-webui/apply-task-config.sh" >/dev/null

model=$(curl --fail --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${token}" \
  "${WEBUI_URL}/api/v1/models/model?id=${TASK_MODEL_ID}")
jq -e '.base_model_id == "qwen3.5:4b" and .params.think == false and
  .params.temperature == 0 and .params.num_ctx == 4096 and
  .params.max_tokens == 64 and .params.format == "json" and
  .is_active == true' <<<"$model" >/dev/null ||
  fail 'task model preset does not match the low-latency contract'

task_config=$(curl --fail --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${token}" "${WEBUI_URL}/api/v1/tasks/config")
jq -e --arg id "$TASK_MODEL_ID" '.TASK_MODEL == $id and
  .ENABLE_TITLE_GENERATION == true and .ENABLE_FOLLOW_UP_GENERATION == true and
  .ENABLE_TAGS_GENERATION == true and .ENABLE_AUTOCOMPLETE_GENERATION == true' \
  <<<"$task_config" >/dev/null || fail 'task features or selected task model are incorrect'

messages='[{"role":"user","content":"四色猜想被证明了吗？"},{"role":"assistant","content":"是的，四色猜想已经被证明了。1976年完成了计算机辅助证明。"}]'
task_body=$(jq -cn --argjson messages "$messages" '{model:"qwen3.5:4b",messages:$messages}')

title=$(api /api/v1/tasks/title/completions "$task_body")
jq -e '.usage.output_tokens <= 64 and (.choices[0].message.content | fromjson | .title | length > 0)' \
  <<<"$title" >/dev/null || fail 'title task exceeded its cap or returned invalid output'

follow_up=$(api /api/v1/tasks/follow_up/completions "$task_body")
jq -e '.usage.output_tokens <= 64 and (.choices[0].message.content | fromjson | .follow_ups | length > 0)' \
  <<<"$follow_up" >/dev/null || fail 'follow-up task exceeded its cap or returned invalid output'

tags=$(api /api/v1/tasks/tags/completions "$task_body")
jq -e '.usage.output_tokens <= 64 and (.choices[0].message.content | fromjson | .tags | length > 0)' \
  <<<"$tags" >/dev/null || fail 'tags task exceeded its cap or returned invalid output'

autocomplete_body=$(jq -cn '{model:"qwen3.5:4b",prompt:"四色猜想",messages:[],type:"prompt autocomplete",stream:false}')
autocomplete=$(api /api/v1/tasks/auto/completions "$autocomplete_body")
jq -e '.usage.output_tokens <= 64 and (.choices[0].message.content | fromjson | .text | length > 0)' \
  <<<"$autocomplete" >/dev/null || fail 'autocomplete task exceeded its cap or returned invalid output'

printf '%s\n' 'PASS: capped title, follow-up, tags, and autocomplete tasks return valid local output'
