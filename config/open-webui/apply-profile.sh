#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/profile.sh
. "$ROOT/scripts/lib/profile.sh"

readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"

usage() {
  printf '%s\n' 'Usage: config/open-webui/apply-profile.sh PROFILE'
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }
profile=$1
agent_lab_validate_profile "$profile" || exit 1
[[ -f "$ROOT/.env" ]] || die 'run bin/agent-lab setup first' || exit 1
require_command curl
require_command jq
require_command docker

profile_value() {
  agent_lab_effective_profile "$profile" | awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}'
}

enabled=$(profile_value ENABLE_WEB_SEARCH)
engine=$(profile_value WEB_SEARCH_ENGINE)
[[ $engine != none ]] || engine=''
agent_lab_load_profile "$profile"
docker info >/dev/null 2>&1 || die 'Docker engine is unavailable' || exit 1
docker compose --project-directory "$ROOT" --env-file "$ROOT/.env" -f "$ROOT/compose.yaml" \
  up --detach --no-build --force-recreate open-webui >/dev/null
for _ in {1..240}; do
  curl --fail --silent --max-time 2 "$WEBUI_URL/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl --fail --silent --max-time 2 "$WEBUI_URL/health" >/dev/null ||
  die 'Open WebUI did not become healthy after profile recreation' || exit 1

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "$ROOT/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$ROOT/.env")
auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "$WEBUI_URL/api/v1/auths/signin") || die 'Open WebUI admin sign-in failed' || exit 1
token=$(jq -er '.token' <<<"$auth") || die 'Open WebUI sign-in returned no token' || exit 1

web=$(jq -cn --argjson enabled "$enabled" --arg engine "$engine" '{ENABLE_WEB_SEARCH:$enabled,ENABLE_WEB_SEARCH_CONFIRMATION:false,WEB_SEARCH_ENGINE:$engine,WEB_SEARCH_TRUST_ENV:false,WEB_SEARCH_RESULT_COUNT:3,WEB_SEARCH_CONCURRENT_REQUESTS:1,WEB_SEARCH_DOMAIN_FILTER_LIST:[],WEB_FETCH_MAX_CONTENT_LENGTH:20000,WEB_LOADER_CONCURRENT_REQUESTS:2,BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL:false,BYPASS_WEB_SEARCH_WEB_LOADER:false,DDGS_BACKEND:"auto",WEB_LOADER_ENGINE:"safe_web",ENABLE_WEB_LOADER_SSL_VERIFICATION:true}')
body=$(jq -cn --argjson web "$web" '{web:$web}')
response=$(curl --fail --silent --show-error --max-time 60 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  --data "$body" "$WEBUI_URL/api/v1/retrieval/config/update") ||
  die 'failed to apply Open WebUI profile settings' || exit 1
jq -e --argjson enabled "$enabled" --arg engine "$engine" '.web.ENABLE_WEB_SEARCH == $enabled and .web.WEB_SEARCH_ENGINE == $engine and .web.WEB_SEARCH_TRUST_ENV == false' <<<"$response" >/dev/null ||
  die 'Open WebUI did not persist the selected search profile' || exit 1

state_file=$(agent_lab_profile_state_file)
state_dir=$(dirname "$state_file")
mkdir -p "$state_dir"
temporary=$(mktemp "$state_dir/.profile.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
printf '%s\n' "$profile" > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$state_file"
trap - EXIT HUP INT TERM
printf 'PASS: applied Agent Lab profile %s to Open WebUI\n' "$profile"
