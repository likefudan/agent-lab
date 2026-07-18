#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly CASES="$ROOT/evals/fixtures/search/questions.json"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "$ROOT/.env" ]] || fail 'run bin/agent-lab setup first'
admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "$ROOT/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$ROOT/.env")

sign_in() {
  local auth
  auth=$(curl --fail --silent --show-error --max-time 30 -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
    "$WEBUI_URL/api/v1/auths/signin") || fail 'Open WebUI sign-in failed'
  token=$(jq -er '.token' <<<"$auth") || fail 'sign-in returned no token'
}

search_request() {
  local query=$1 output=$2
  curl --silent --show-error --max-time 180 --output "$output" --write-out '%{http_code}' \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
    --data "$(jq -cn --arg query "$query" '{queries:[$query]}')" \
    "$WEBUI_URL/api/v1/retrieval/process/web/search"
}

sign_in
"$ROOT/config/open-webui/apply-profile.sh" offline >/dev/null
offline_response=$(mktemp "${TMPDIR:-/tmp}/agent-lab-search-offline.XXXXXX")
trap 'rm -f -- "$offline_response"' EXIT HUP INT TERM
offline_code=$(search_request 'IANA reserved domains' "$offline_response")
[[ $offline_code == 403 ]] || fail "offline search returned HTTP $offline_code instead of 403"

"$ROOT/config/open-webui/apply-profile.sh" online-manual >/dev/null
config=$(curl --fail --silent --show-error -H "Authorization: Bearer ${token}" "$WEBUI_URL/api/v1/retrieval/config")
jq -e '.web.ENABLE_WEB_SEARCH == true and .web.WEB_SEARCH_ENGINE == "duckduckgo"' <<<"$config" >/dev/null ||
  fail 'online-manual did not expose DuckDuckGo search'

results_dir="$ROOT/.agent-lab/results"
mkdir -p "$results_dir"
results_file="$results_dir/search-latest.jsonl"
: > "$results_file"
successes=0
external_failures=0
while IFS= read -r case_json; do
  case_id=$(jq -r '.id' <<<"$case_json")
  query=$(jq -r '.query' <<<"$case_json")
  domain=$(jq -r '.expected_url_domain' <<<"$case_json")
  term=$(jq -r '.expected_snippet_term' <<<"$case_json")
  response=$(mktemp "${TMPDIR:-/tmp}/agent-lab-search-result.XXXXXX")
  started=$(date +%s)
  code=$(search_request "$query" "$response")
  elapsed=$(( $(date +%s) - started ))
  if [[ $code != 200 ]]; then
    external_failures=$((external_failures + 1))
    jq -cn --arg id "$case_id" --argjson code "$code" --argjson latency "$elapsed" '{case_id:$id,status:"external_provider_failure",http_code:$code,latency_seconds:$latency}' >> "$results_file"
    rm -f -- "$response"
    continue
  fi
  jq -e --arg domain "$domain" --arg term "$term" '([.filenames[]? | select(test($domain; "i"))] | length) > 0 and ([.items[]? | ((.title // "") + " " + (.snippet // "")) | select(test($term; "i"))] | length) > 0' "$response" >/dev/null || {
    external_failures=$((external_failures + 1))
    jq -cn --arg id "$case_id" --argjson latency "$elapsed" '{case_id:$id,status:"provider_result_drift",latency_seconds:$latency}' >> "$results_file"
    rm -f -- "$response"
    continue
  }
  jq -e '(.loaded_count > 0) and (.collection_names | length) > 0 and (.filenames | length) > 0 and (.items | length) > 0 and ([.items[] | has("link") and has("title") and has("snippet")] | all) and ([.items[].link] - .filenames | length) == 0' "$response" >/dev/null ||
    fail "$case_id returned incomplete citation/source records"
  successes=$((successes + 1))
  jq -cn --arg id "$case_id" --argjson latency "$elapsed" '{case_id:$id,status:"pass",latency_seconds:$latency}' >> "$results_file"
  rm -f -- "$response"
done < <(jq -c '.cases[]' "$CASES")
((successes >= 1)) || fail "DuckDuckGo produced no qualified results (${external_failures} external failures)"

# Automatic mode exposes search to the model; tool choice itself is checked
# directly against the qualified local tool-calling model.
"$ROOT/config/open-webui/apply-profile.sh" online-automatic >/dev/null
tools='[{"type":"function","function":{"name":"web_search","description":"Search the current public web","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}]'
needs_search=$(jq -cn --argjson tools "$tools" '{model:"qwen3.5:4b",messages:[{role:"user",content:"Use web_search to find the current weather in Seattle."}],tools:$tools,stream:false,think:false,keep_alive:0}')
tool_response=$(curl --fail --silent --show-error --max-time 120 -H 'Content-Type: application/json' --data "$needs_search" http://127.0.0.1:11434/api/chat)
jq -e '.message.tool_calls[0].function.name == "web_search"' <<<"$tool_response" >/dev/null ||
  fail 'automatic profile model did not select search for a current-information request'
no_search=$(jq -cn --argjson tools "$tools" '{model:"qwen3.5:4b",messages:[{role:"user",content:"Answer 2 + 2. Do not use web search."}],tools:$tools,stream:false,think:false,keep_alive:0}')
no_search_response=$(curl --fail --silent --show-error --max-time 120 -H 'Content-Type: application/json' --data "$no_search" http://127.0.0.1:11434/api/chat)
jq -e '((.message.tool_calls // []) | length) == 0' <<<"$no_search_response" >/dev/null ||
  fail 'automatic profile model searched for a timeless local question'

"$ROOT/config/open-webui/apply-profile.sh" online-manual >/dev/null
printf 'PASS: profile-gated DuckDuckGo search and local automatic tool choice (%s)\n' "$results_file"
