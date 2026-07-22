#!/usr/bin/env bash
# Apply Agent Lab Open WebUI defaults (persisted in webui.db):
# - DEFAULT_MODEL_PARAMS: think off, bounded tokens, 4k ctx, 5m keep-alive
# - Task config + Memory: upstream-friendly on (title/tags/follow-up/autocomplete)
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly PARAMS_FILE="${ROOT}/config/open-webui/model-params.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup first'
[[ -f "$PARAMS_FILE" ]] || fail "missing $PARAMS_FILE"
curl --fail --silent --max-time 5 "${WEBUI_URL}/health" >/dev/null 2>&1 ||
  fail "Open WebUI not healthy at ${WEBUI_URL}/health (run: bin/agent-lab start)"

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")
[[ -n $admin_email && -n $admin_password ]] || fail 'WEBUI_ADMIN_EMAIL / WEBUI_ADMIN_PASSWORD missing from .env'

auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" \
    '{email:$email,password:$password}')" \
  "${WEBUI_URL}/api/v1/auths/signin") || fail 'Open WebUI admin sign-in failed'
token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'
auth_hdr=( -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' )

desired=$(jq -c '.DEFAULT_MODEL_PARAMS' "$PARAMS_FILE") || fail 'model-params.json missing DEFAULT_MODEL_PARAMS'
task_overrides=$(jq -c '.TASK_CONFIG // {}' "$PARAMS_FILE")
memory_want=$(jq -r '.USER_UI.memory // empty' "$PARAMS_FILE")

# --- DEFAULT_MODEL_PARAMS ---
current=$(curl --fail --silent --show-error --max-time 30 \
  "${auth_hdr[@]}" "${WEBUI_URL}/api/v1/configs/models") ||
  fail 'failed to read /api/v1/configs/models'

body=$(jq -cn --argjson cur "$current" --argjson params "$desired" '
  {
    DEFAULT_MODELS: ($cur.DEFAULT_MODELS // ""),
    DEFAULT_PINNED_MODELS: ($cur.DEFAULT_PINNED_MODELS // ""),
    MODEL_ORDER_LIST: ($cur.MODEL_ORDER_LIST // []),
    DEFAULT_MODEL_METADATA: ($cur.DEFAULT_MODEL_METADATA // null),
    DEFAULT_MODEL_PARAMS: $params
  }
')

response=$(curl --fail --silent --show-error --max-time 60 \
  "${auth_hdr[@]}" --data "$body" "${WEBUI_URL}/api/v1/configs/models") ||
  fail 'failed to update /api/v1/configs/models'

jq -e --argjson want "$desired" '
  (.DEFAULT_MODEL_PARAMS.think == $want.think) and
  (.DEFAULT_MODEL_PARAMS.temperature == $want.temperature) and
  (.DEFAULT_MODEL_PARAMS.num_ctx == $want.num_ctx) and
  (.DEFAULT_MODEL_PARAMS.max_tokens == $want.max_tokens) and
  (.DEFAULT_MODEL_PARAMS.keep_alive == $want.keep_alive)
' <<<"$response" >/dev/null ||
  fail "Open WebUI did not persist DEFAULT_MODEL_PARAMS: $(jq -c '.DEFAULT_MODEL_PARAMS' <<<"$response")"

printf 'PASS: DEFAULT_MODEL_PARAMS applied: '
jq -c '.DEFAULT_MODEL_PARAMS' <<<"$response"

# --- Background task generators (title / tags / follow-up / autocomplete) ---
if [[ $(jq -r 'type' <<<"$task_overrides") == object && $(jq 'length' <<<"$task_overrides") -gt 0 ]]; then
  task_cur=$(curl --fail --silent --show-error --max-time 30 \
    "${auth_hdr[@]}" "${WEBUI_URL}/api/v1/tasks/config") ||
    fail 'failed to read /api/v1/tasks/config'

  task_body=$(jq -cn --argjson cur "$task_cur" --argjson ov "$task_overrides" '$cur * $ov')
  task_resp=$(curl --fail --silent --show-error --max-time 60 \
    "${auth_hdr[@]}" --data "$task_body" "${WEBUI_URL}/api/v1/tasks/config/update") ||
    fail 'failed to update /api/v1/tasks/config'

  jq -e --argjson ov "$task_overrides" '
    (.ENABLE_TITLE_GENERATION == $ov.ENABLE_TITLE_GENERATION) and
    (.ENABLE_TAGS_GENERATION == $ov.ENABLE_TAGS_GENERATION) and
    (.ENABLE_FOLLOW_UP_GENERATION == $ov.ENABLE_FOLLOW_UP_GENERATION) and
    (.ENABLE_AUTOCOMPLETE_GENERATION == $ov.ENABLE_AUTOCOMPLETE_GENERATION)
  ' <<<"$task_resp" >/dev/null ||
    fail "task config not persisted: $(jq -c '{ENABLE_TITLE_GENERATION,ENABLE_TAGS_GENERATION,ENABLE_FOLLOW_UP_GENERATION,ENABLE_AUTOCOMPLETE_GENERATION}' <<<"$task_resp")"

  printf 'PASS: task generators applied: '
  jq -c '{ENABLE_TITLE_GENERATION,ENABLE_TAGS_GENERATION,ENABLE_FOLLOW_UP_GENERATION,ENABLE_AUTOCOMPLETE_GENERATION}' <<<"$task_resp"
fi

# --- Chat Controls / user ui.params (required for max_tokens to actually bind) ---
# Open WebUI Admin DEFAULT_MODEL_PARAMS alone are unreliable here: a request that
# only sends {think:false} still ran unbounded generation (~3k tokens). Push the
# same knobs into the admin user's ui.params so the browser includes them.
user_params=$(jq -c '.DEFAULT_MODEL_PARAMS' "$PARAMS_FILE")
if settings=$(curl --fail --silent --show-error --max-time 30 \
  "${auth_hdr[@]}" "${WEBUI_URL}/api/v1/users/user/settings" 2>/dev/null); then
  memory_json='null'
  [[ -n $memory_want ]] && memory_json=$(jq -cn --argjson m "$memory_want" '$m')
  updated=$(jq -c --argjson params "$user_params" --argjson mem "$memory_json" '
    . as $s
    | ($s.ui // {}) as $ui
    | ($ui * {
        params: (($ui.params // {}) + $params),
        memory: (if $mem == null then ($ui.memory // false) else $mem end),
        features: (
          (if ($ui.features | type) == "object" then $ui.features else {} end)
          + (if $mem == null then {} else {memory: $mem} end)
        )
      }) as $new_ui
    | $s + {ui: $new_ui}
  ' <<<"$settings")
  if curl --fail --silent --show-error --max-time 30 \
    "${auth_hdr[@]}" --data "$updated" \
    "${WEBUI_URL}/api/v1/users/user/settings/update" >/dev/null 2>&1; then
    printf 'PASS: admin ui.params updated: '
    jq -c '.ui.params' <<<"$updated"
    [[ -n $memory_want ]] && printf 'PASS: admin user memory preference set to %s\n' "$memory_want"
  else
    printf 'WARN: could not update user settings; set Max Tokens in Chat Controls manually\n' >&2
  fi
fi

printf 'NOTE: keep Controls → Think Off. Hard-refresh the browser and open a NEW chat.\n' >&2
printf 'NOTE: confirm Chat Controls show Max Tokens matching model-params.json (currently 512).\n' >&2
