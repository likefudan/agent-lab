#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly OLLAMA_BIN='/opt/homebrew/opt/ollama/bin/ollama'
readonly API='http://127.0.0.1:11434'
readonly RESULTS_DIR="${ROOT}/.agent-lab/results"
readonly RESULT_FILE="${RESULTS_DIR}/model-lifecycle.json"
readonly RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-lifecycle.XXXXXX")"
readonly REQUEST_TIMEOUT=240
server_pid=

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

wait_for_health() {
  local attempt
  for attempt in {1..120}; do
    if curl --silent --fail --max-time 2 "${API}/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  fail 'Ollama did not become healthy within 30 seconds'
}

start_server() {
  [[ ! -n "$server_pid" ]] || fail 'test server PID already set'
  OLLAMA_HOST=127.0.0.1:11434 \
  OLLAMA_NO_CLOUD=1 \
  OLLAMA_MAX_LOADED_MODELS=1 \
  OLLAMA_KEEP_ALIVE=5m \
    "$OLLAMA_BIN" serve >"${RUN_DIR}/ollama.stdout.log" 2>"${RUN_DIR}/ollama.stderr.log" &
  server_pid=$!
  wait_for_health
}

stop_server() {
  [[ -n "$server_pid" ]] || return 0
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=
}

chat_request() {
  local tag=$1
  local output=$2
  curl --silent --show-error --fail --max-time "$REQUEST_TIMEOUT" \
    --header 'Content-Type: application/json' \
    --data "$(jq -nc --arg model "$tag" '{model:$model,messages:[{role:"user",content:"Reply with exactly READY"}],stream:false,think:false,keep_alive:"5m",options:{temperature:0,num_predict:32,num_ctx:4096}}')" \
    "${API}/api/chat" >"$output"
  [[ "$(jq -r '.message.content' "$output" | tr -d '[:space:]')" == READY ]] ||
    fail "$tag did not return READY"
}

loaded_count() {
  curl --silent --fail "${API}/api/ps" | jq '.models | length'
}

loaded_name() {
  curl --silent --fail "${API}/api/ps" | jq -r '.models[0].name // ""'
}

wait_for_unload() {
  local attempt
  for attempt in {1..80}; do
    [[ "$(loaded_count)" -eq 0 ]] && return 0
    sleep 0.25
  done
  fail 'model did not unload within 20 seconds'
}

unload_model() {
  local tag=$1
  curl --silent --show-error --fail --max-time 30 \
    --header 'Content-Type: application/json' \
    --data "$(jq -nc --arg model "$tag" '{model:$model,keep_alive:0}')" \
    "${API}/api/generate" >/dev/null
  wait_for_unload
}

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'requires Apple Silicon macOS'
[[ -x "$OLLAMA_BIN" ]] || fail "missing pinned Ollama: $OLLAMA_BIN"
command -v jq >/dev/null || fail 'jq is required'
command -v curl >/dev/null || fail 'curl is required'

if lsof -nP -iTCP@127.0.0.1:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 { found=1 } END { exit !found }'; then
  fail 'port 127.0.0.1:11434 is already occupied; stop the existing service before this isolated test'
fi

mkdir -p "$RESULTS_DIR"
"${ROOT}/scripts/models.sh" verify >/dev/null
start_server

models=(qwen3.5:4b qwen3.5:9b gemma4:12b)
switch_results='[]'
max_loaded=0

for tag in "${models[@]}"; do
  started=$(date +%s)
  chat_request "$tag" "${RUN_DIR}/${tag//[:\/]/-}.json"
  elapsed=$(( $(date +%s) - started ))
  count=$(loaded_count)
  (( count > max_loaded )) && max_loaded=$count
  [[ "$count" -eq 1 ]] || fail "expected one loaded model after $tag, got $count"
  [[ "$(loaded_name)" == "$tag" ]] || fail "active model does not match $tag"
  resident_bytes=$(curl --silent --fail "${API}/api/ps" | jq '.models[0].size_vram // .models[0].size')
  memory_free_percent=
  if command -v memory_pressure >/dev/null 2>&1; then
    memory_free_percent=$(memory_pressure -Q 2>/dev/null |
      awk -F': ' '/System-wide memory free percentage/ {gsub(/%/, "", $2); print $2; exit}')
  fi
  if [[ "$memory_free_percent" =~ ^[0-9]+$ ]]; then
    (( memory_free_percent >= 5 )) || fail "critical memory pressure while $tag was loaded"
    memory_json=$memory_free_percent
  else
    memory_json=null
  fi
  switch_results=$(jq -c --arg tag "$tag" --argjson elapsed "$elapsed" \
    --argjson resident "$resident_bytes" --argjson free_percent "$memory_json" \
    '. + [{model:$tag,request_and_load_seconds:$elapsed,resident_bytes:$resident,
           system_memory_free_percent:$free_percent}]' <<<"$switch_results")
done
[[ "$max_loaded" -le 1 ]] || fail "more than one model was resident: $max_loaded"

unload_model gemma4:12b

missing_code=$(curl --silent --output "${RUN_DIR}/missing.json" --write-out '%{http_code}' --max-time 30 \
  --header 'Content-Type: application/json' \
  --data '{"model":"agent-lab-model-does-not-exist","messages":[{"role":"user","content":"hello"}],"stream":false}' \
  "${API}/api/chat")
[[ "$missing_code" == 404 ]] || fail "missing model returned HTTP $missing_code, expected 404"
curl --silent --fail "${API}/api/version" >/dev/null || fail 'server unhealthy after failed load'

# Concurrent different-model requests must both finish while polling never sees
# more than the configured one-model residency limit.
chat_request qwen3.5:4b "${RUN_DIR}/concurrent-4b.json" &
first_pid=$!
chat_request qwen3.5:9b "${RUN_DIR}/concurrent-9b.json" &
second_pid=$!
while kill -0 "$first_pid" 2>/dev/null || kill -0 "$second_pid" 2>/dev/null; do
  count=$(loaded_count)
  (( count > max_loaded )) && max_loaded=$count
  [[ "$count" -le 1 ]] || fail "concurrent requests loaded $count models"
  sleep 0.1
done
wait "$first_pid"
wait "$second_pid"
[[ "$max_loaded" -le 1 ]] || fail 'single-model limit failed during concurrency'

# Cancel a long stream at the client, then require the local server to recover.
curl --silent --show-error --no-buffer --max-time "$REQUEST_TIMEOUT" \
  --header 'Content-Type: application/json' \
  --data '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Write a very long numbered list."}],"stream":true,"think":false,"keep_alive":"5m","options":{"num_predict":2048,"num_ctx":4096}}' \
  "${API}/api/chat" >"${RUN_DIR}/stream.jsonl" &
stream_pid=$!
for _ in {1..100}; do
  [[ -s "${RUN_DIR}/stream.jsonl" ]] && break
  sleep 0.1
done
[[ -s "${RUN_DIR}/stream.jsonl" ]] || fail 'stream produced no output before cancellation'
kill "$stream_pid" 2>/dev/null || true
wait "$stream_pid" 2>/dev/null || true
curl --silent --fail "${API}/api/version" >/dev/null || fail 'server unhealthy after stream cancellation'
chat_request qwen3.5:4b "${RUN_DIR}/post-cancel.json"
unload_model qwen3.5:4b

# A server restart must recover without a pull or catalog change.
stop_server
start_server
chat_request qwen3.5:4b "${RUN_DIR}/post-restart.json"
unload_model qwen3.5:4b

jq -n \
  --arg ollama_version "$(curl --silent --fail "${API}/api/version" | jq -r '.version')" \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson switches "$switch_results" \
  --argjson max_loaded "$max_loaded" \
  '{schema_version:1,completed_at:$completed_at,ollama_version:$ollama_version,
    switches:$switches,max_loaded_models_observed:$max_loaded,
    unload:"pass",failed_load_recovery:"pass",concurrent_requests:"pass",
    streaming_cancellation_recovery:"pass",server_restart_recovery:"pass"}' >"$RESULT_FILE"

printf 'PASS: model lifecycle; results: %s\n' "$RESULT_FILE"
