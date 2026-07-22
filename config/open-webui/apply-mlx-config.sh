#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly CHAT_URL='http://host.docker.internal:8081/v1'
readonly VISION_URL='http://host.docker.internal:8082/v1'
readonly CHAT_PRESET_ID='agent-lab-mlx-qwen-9b'
readonly VISION_PRESET_ID='agent-lab-mlx-gemma-12b'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$ROOT/.env" ]] || fail 'run bin/agent-lab setup first'

admin_email=${OPEN_WEBUI_ADMIN_EMAIL:-$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "$ROOT/.env")}
admin_password=${OPEN_WEBUI_ADMIN_PASSWORD:-$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$ROOT/.env")}
[[ -n $admin_email && -n $admin_password ]] || fail 'Open WebUI administrator credentials are missing'

qwen_path=$(python3 "$ROOT/scripts/mlx-models.py" path qwen-9b-mlx) ||
  fail 'the pinned Qwen MLX snapshot is unavailable'
gemma_path=$(python3 "$ROOT/scripts/mlx-models.py" path gemma-12b-mlx) ||
  fail 'the pinned Gemma MLX snapshot is unavailable'

auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "$WEBUI_URL/api/v1/auths/signin") ||
  fail 'Open WebUI admin sign-in failed; synchronize .env or set OPEN_WEBUI_ADMIN_PASSWORD'
token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'

api() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl --fail --silent --show-error --max-time 60 -X "$method" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
      --data "$body" "$WEBUI_URL$path"
  else
    curl --fail --silent --show-error --max-time 60 -X "$method" \
      -H "Authorization: Bearer ${token}" "$WEBUI_URL$path"
  fi
}

upsert_preset() {
  local id=$1 preset=$2 status_file status response
  status_file=$(mktemp "${TMPDIR:-/tmp}/agent-lab-mlx-model.XXXXXX")
  status=$(curl --silent --show-error --max-time 30 -o "$status_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" "$WEBUI_URL/api/v1/models/model?id=$id") ||
    fail "failed to inspect Open WebUI model preset $id"
  rm -f -- "$status_file"
  case $status in
    200) response=$(api POST /api/v1/models/model/update "$preset") ;;
    404) response=$(api POST /api/v1/models/create "$preset") ;;
    *) fail "unexpected model preset lookup status for $id: $status" ;;
  esac
  jq -e --arg id "$id" '.id == $id and .is_active == true' <<<"$response" >/dev/null ||
    fail "Open WebUI did not persist model preset $id"
}

current=$(curl --fail --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${token}" "$WEBUI_URL/openai/config") ||
  fail 'failed to read Open WebUI provider configuration'

body=$(jq -cn \
  --argjson current "$current" \
  --arg chat_url "$CHAT_URL" --arg vision_url "$VISION_URL" \
  --arg qwen_path "$qwen_path" --arg gemma_path "$gemma_path" '
  ([range(0; ($current.OPENAI_API_BASE_URLS | length)) as $i |
    {url:$current.OPENAI_API_BASE_URLS[$i],
     key:($current.OPENAI_API_KEYS[$i] // ""),
     config:($current.OPENAI_API_CONFIGS[($i|tostring)] //
             $current.OPENAI_API_CONFIGS[$current.OPENAI_API_BASE_URLS[$i]] // {})} |
    select(.url != $chat_url and .url != $vision_url)] +
  [{url:$chat_url,key:"",config:{enable:true,connection_type:"local",auth_type:"none",prefix_id:"mlx-lm",model_ids:[$qwen_path]}},
   {url:$vision_url,key:"",config:{enable:true,connection_type:"local",auth_type:"none",prefix_id:"mlx-vlm",model_ids:[$gemma_path]}}]) as $entries |
  {ENABLE_OPENAI_API:true,
   OPENAI_API_BASE_URLS:[$entries[].url],
   OPENAI_API_KEYS:[$entries[].key],
   OPENAI_API_CONFIGS:(reduce range(0; $entries|length) as $i ({}; .[($i|tostring)]=$entries[$i].config))}')

response=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  --data "$body" "$WEBUI_URL/openai/config/update") ||
  fail 'failed to update Open WebUI MLX connections'

jq -e --arg chat_url "$CHAT_URL" --arg vision_url "$VISION_URL" '
  .ENABLE_OPENAI_API == true and
  (.OPENAI_API_BASE_URLS | index($chat_url) != null) and
  (.OPENAI_API_BASE_URLS | index($vision_url) != null)' <<<"$response" >/dev/null ||
  fail 'Open WebUI did not persist both MLX connections'

# Refresh providers before binding friendly Agent Lab model names to their
# prefixed Open WebUI base-model identifiers.
api GET /api/models >/dev/null
chat_preset=$(jq -cn --arg id "$CHAT_PRESET_ID" --arg base "mlx-lm.$qwen_path" '{
  id:$id,base_model_id:$base,name:"Agent Lab MLX Qwen 9B",
  meta:{description:"Fast native MLX-LM chat and coding model.",capabilities:{vision:false}},
  params:{think:false,temperature:0,max_tokens:16384},access_grants:[],is_active:true}')
vision_preset=$(jq -cn --arg id "$VISION_PRESET_ID" --arg base "mlx-vlm.$gemma_path" '{
  id:$id,base_model_id:$base,name:"Agent Lab MLX Gemma 12B Vision",
  meta:{description:"Native MLX-VLM multimodal Gemma model.",capabilities:{vision:true}},
  params:{temperature:0,max_tokens:16384},access_grants:[],is_active:true}')
upsert_preset "$CHAT_PRESET_ID" "$chat_preset"
upsert_preset "$VISION_PRESET_ID" "$vision_preset"
api GET /api/models >/dev/null

printf '%s\n' 'PASS: Open WebUI has local MLX-LM and MLX-VLM connections with friendly model presets'
