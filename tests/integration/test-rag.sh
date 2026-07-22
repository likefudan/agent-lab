#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly CASES="${ROOT}/evals/fixtures/rag/questions.json"
readonly FIXTURES="${ROOT}/tests/fixtures/rag"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup first'

admin_email=${OPEN_WEBUI_ADMIN_EMAIL:-$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")}
admin_password=${OPEN_WEBUI_ADMIN_PASSWORD:-$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")}
sign_in() {
  local auth
  auth=$(curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
    "${WEBUI_URL}/api/v1/auths/signin") || fail 'Open WebUI admin sign-in failed'
  token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'
}

api() {
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl --fail --silent --show-error --max-time 180 -X "$method" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
      --data "$body" "${WEBUI_URL}${path}"
  else
    curl --fail --silent --show-error --max-time 180 -X "$method" \
      -H "Authorization: Bearer ${token}" "${WEBUI_URL}${path}"
  fi
}

file_ids=()
cleanup() {
  local id
  for id in "${file_ids[@]:-}"; do
    [[ -n $id ]] && api DELETE "/api/v1/files/${id}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT HUP INT TERM

sign_in
"${ROOT}/config/open-webui/apply-rag-config.sh" >/dev/null
"${ROOT}/config/open-webui/verify-embedding-cache.sh" >/dev/null

mapfile_cmd=()
while IFS= read -r fixture; do
  mapfile_cmd+=("$fixture")
done < <(jq -r '.fixtures[] | select(.role == "queryable" or .role == "queryable_near_duplicate" or .role == "irrelevant_distractor") | .path' "$CASES")

for fixture in "${mapfile_cmd[@]}"; do
  upload=$(curl --fail --silent --show-error --max-time 180 \
    -H "Authorization: Bearer ${token}" -F "file=@${FIXTURES}/${fixture}" \
    "${WEBUI_URL}/api/v1/files/?process=true&process_in_background=false") ||
    fail "failed to ingest ${fixture}"
  file_id=$(jq -er '.id' <<<"$upload") || fail "upload returned no id for ${fixture}"
  file_ids+=("$file_id")
done

collections=$(printf '%s\n' "${file_ids[@]}" | jq -R '"file-" + .' | jq -s '.')
results_dir="${ROOT}/.agent-lab/results"
mkdir -p "$results_dir"
results_file="${results_dir}/rag-latest.jsonl"
: > "$results_file"

run_cases() {
  local phase=$1 case_json case_id question expected_source top_k query response rank
  while IFS= read -r case_json; do
    case_id=$(jq -r '.id' <<<"$case_json")
    question=$(jq -r '.question' <<<"$case_json")
    expected_source=$(jq -r '.expected_source' <<<"$case_json")
    top_k=$(jq -r '.acceptable_top_k' <<<"$case_json")
    query=$(jq -cn --argjson collections "$collections" --arg question "$question" --argjson k "$top_k" '{collection_names:$collections,query:$question,k:$k,hybrid:true,hybrid_bm25_weight:0.5}')
    started=$(date +%s)
    response=$(api POST /api/v1/retrieval/query/collection "$query") || fail "retrieval failed for ${case_id}"
    elapsed=$(( $(date +%s) - started ))
    rank=$(jq -r --arg source "$expected_source" '[.metadatas[0][].name] | index($source) | if . == null then -1 else . + 1 end' <<<"$response")
    (( rank > 0 && rank <= top_k )) || fail "${case_id}: expected source ${expected_source} ranked ${rank}"
    jq -e --arg source "$expected_source" --argjson rank "$rank" '.metadatas[0][$rank - 1] | .name == $source and (.file_id | length > 0) and (.hash | length > 0)' <<<"$response" >/dev/null ||
      fail "${case_id}: citation metadata is incomplete"
    while IFS= read -r fact; do
      jq -e --arg fact "$fact" --arg source "$expected_source" '[range(0; (.documents[0] | length)) as $i | select(.metadatas[0][$i].name == $source) | .documents[0][$i]] | any(ascii_downcase | contains($fact | ascii_downcase))' <<<"$response" >/dev/null ||
        fail "${case_id}: expected answer fact not present in retrieved source: ${fact}"
    done < <(jq -r '.expected_answer_facts[]' <<<"$case_json")
    jq -cn --arg phase "$phase" --arg case_id "$case_id" --arg source "$expected_source" --argjson rank "$rank" --argjson latency_seconds "$elapsed" '{phase:$phase,case_id:$case_id,source:$source,rank:$rank,latency_seconds:$latency_seconds,citation_fields:["name","file_id","hash"]}' >> "$results_file"
  done < <(jq -c '.cases[] | select(.evaluation_scope == "queryable_rag")' "$CASES")
}

run_cases before_restart
docker compose --project-directory "$ROOT" -f "${ROOT}/compose.yaml" restart open-webui >/dev/null
for _ in {1..90}; do
  curl --fail --silent --max-time 2 "${WEBUI_URL}/health" >/dev/null 2>&1 && break
  sleep 2
done
sign_in
run_cases after_restart

config=$(api GET /api/v1/retrieval/config)
jq -e '.TOP_K == 5 and .ENABLE_RAG_HYBRID_SEARCH == true and .RAG_RERANKING_MODEL == "" and .CHUNK_SIZE == 500 and .CHUNK_OVERLAP == 50' <<<"$config" >/dev/null ||
  fail 'RAG configuration did not persist across restart'

printf 'PASS: local RAG retrieval, source metadata, and persistence (%s)\n' "$results_file"
