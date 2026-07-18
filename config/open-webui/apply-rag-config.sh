#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup first'

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")
auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "${WEBUI_URL}/api/v1/auths/signin") || fail 'Open WebUI admin sign-in failed'
token=$(jq -er '.token' <<<"$auth") || fail 'Open WebUI sign-in returned no token'

embedding_body=$(jq -cn '{RAG_EMBEDDING_ENGINE:"",RAG_EMBEDDING_MODEL:"sentence-transformers/all-MiniLM-L6-v2",RAG_EMBEDDING_BATCH_SIZE:1,ENABLE_ASYNC_EMBEDDING:true,RAG_EMBEDDING_CONCURRENT_REQUESTS:0}')
curl --fail --silent --show-error --max-time 120 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  --data "$embedding_body" "${WEBUI_URL}/api/v1/retrieval/embedding/update" >/dev/null ||
  fail 'failed to apply local embedding configuration'

rag_body=$(jq -cn '{TOP_K:5,ENABLE_RAG_HYBRID_SEARCH:true,ENABLE_RAG_HYBRID_SEARCH_ENRICHED_TEXTS:false,TOP_K_RERANKER:5,RELEVANCE_THRESHOLD:0.0,HYBRID_BM25_WEIGHT:0.5,RAG_RERANKING_ENGINE:"",RAG_RERANKING_MODEL:"",TEXT_SPLITTER:"",ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER:true,CHUNK_SIZE:500,CHUNK_MIN_SIZE_TARGET:0,CHUNK_OVERLAP:50,PDF_EXTRACT_IMAGES:false,PDF_LOADER_MODE:"page"}')
response=$(curl --fail --silent --show-error --max-time 60 \
  -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  --data "$rag_body" "${WEBUI_URL}/api/v1/retrieval/config/update") ||
  fail 'failed to apply RAG retrieval configuration'

jq -e '.TOP_K == 5 and .ENABLE_RAG_HYBRID_SEARCH == true and .HYBRID_BM25_WEIGHT == 0.5 and .CHUNK_SIZE == 500 and .CHUNK_OVERLAP == 50 and .RAG_RERANKING_MODEL == ""' <<<"$response" >/dev/null ||
  fail 'Open WebUI did not persist the approved RAG configuration'

printf '%s\n' 'PASS: approved Open WebUI RAG configuration applied'
