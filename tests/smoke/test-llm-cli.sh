#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CONFIG_DIR="$ROOT/config/llm"
readonly MODELS_FILE="$ROOT/config/models.json"
readonly IMAGE_FIXTURE="$ROOT/tests/fixtures/rag/vision-card.png"
readonly EXPECTED_LLM_VERSION='0.31.1'
readonly EXPECTED_PLUGIN_VERSION='0.16.1'
readonly DEFAULT_LLM_BIN="$HOME/.local/bin/llm"
readonly LLM_BIN="${AGENT_LAB_LLM_BIN:-$DEFAULT_LLM_BIN}"
readonly OLLAMA_URL="${OLLAMA_HOST:-http://127.0.0.1:11434}"
TEST_DIR=
STREAM_PID=
STREAM_CHILD_PID=

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pid_is_running() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
  [[ -n "$state" && "$state" != Z* ]]
}

wait_for_pid_exit() {
  local pid=$1 attempts=$2
  local attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    pid_is_running "$pid" || return 0
    sleep 0.1
  done
  return 1
}

terminate_pid_bounded() {
  local pid=$1
  pid_is_running "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_pid_exit "$pid" 30 || {
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" 30 || true
  }
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  if [[ -n "$STREAM_CHILD_PID" ]] && kill -0 "$STREAM_CHILD_PID" 2>/dev/null; then
    terminate_pid_bounded "$STREAM_CHILD_PID"
  fi
  if [[ -n "$STREAM_PID" ]] && kill -0 "$STREAM_PID" 2>/dev/null; then
    terminate_pid_bounded "$STREAM_PID"
  fi
  [[ -z "$TEST_DIR" ]] || rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

[[ -x "$LLM_BIN" ]] || fail "pinned LLM CLI is missing: $LLM_BIN"
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'
[[ "$OLLAMA_URL" == 'http://127.0.0.1:11434' ]] ||
  fail "OLLAMA_HOST must be the Agent Lab loopback endpoint, got: $OLLAMA_URL"
curl --silent --show-error --fail --max-time 3 "$OLLAMA_URL/api/version" >/dev/null ||
  fail 'local Ollama is unavailable; start Agent Lab before running this smoke test'

actual_llm_version=$($LLM_BIN --version | awk '{print $NF}')
[[ "$actual_llm_version" == "$EXPECTED_LLM_VERSION" ]] ||
  fail "LLM CLI version mismatch: expected $EXPECTED_LLM_VERSION, got $actual_llm_version"
actual_plugin_version=$($LLM_BIN plugins --all | jq -r \
  '.[] | select(.name == "llm-ollama") | .version')
[[ "$actual_plugin_version" == "$EXPECTED_PLUGIN_VERSION" ]] ||
  fail "llm-ollama version mismatch: expected $EXPECTED_PLUGIN_VERSION, got ${actual_plugin_version:-missing}"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-llm-smoke.XXXXXX")
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
cp "$CONFIG_DIR/aliases.json" "$CONFIG_DIR/default_model.txt" \
  "$CONFIG_DIR/logs-off" "$TEST_DIR/"
export LLM_USER_PATH="$TEST_DIR"
export LLM_LOAD_PLUGINS=llm-ollama
export OLLAMA_HOST="$OLLAMA_URL"

[[ "$($LLM_BIN logs status)" == 'No log database found at '* ]] ||
  fail 'test runtime unexpectedly has LLM history enabled'
[[ "$($LLM_BIN logs path)" == "$TEST_DIR/logs.db" ]] ||
  fail 'LLM history path is not isolated in the disposable runtime'

for alias in qwen-4b qwen-9b gemma-12b; do
  tag=$(jq -er --arg alias "$alias" \
    '.models[] | select(.alias == $alias and .executable == true) | .tag' \
    "$MODELS_FILE") || fail "approved alias is absent from model catalog: $alias"
  [[ "$(jq -r --arg alias "$alias" '.[$alias]' "$CONFIG_DIR/aliases.json")" == "$tag" ]] ||
    fail "LLM alias does not match approved catalog: $alias"
done

one_shot=$($LLM_BIN -n -m qwen-4b --no-stream -o think false \
  -o temperature 0 -o num_predict 24 \
  'Reply with exactly: AGENT_LAB_TEXT_OK')
[[ "$one_shot" == *'AGENT_LAB_TEXT_OK'* ]] || fail 'one-shot text prompt failed'
printf '%s\n' 'PASS: one-shot text prompt and approved model selection'

chat_output=$(printf '%s\n' \
  'Remember the token ORCHID-731. Reply with exactly STORED.' \
  'What token did I ask you to remember? Reply with only the token.' \
  'exit' | $LLM_BIN chat -m qwen-4b --no-stream -o think false \
    -o temperature 0 -o num_predict 48)
[[ "$chat_output" == *'STORED'* && "$chat_output" == *'ORCHID-731'* ]] ||
  fail 'interactive multi-turn chat did not preserve context'
printf '%s\n' 'PASS: interactive multi-turn chat protocol'

image_output=$($LLM_BIN -n -m gemma-12b --no-stream -o think false \
  -o temperature 0 -o num_predict 80 \
  'Read the card. Return the shape, color, and exact code.' -a "$IMAGE_FIXTURE")
[[ "$image_output" == *'PIXEL-6158'* ]] || fail 'Gemma image attachment failed exact OCR'
printf '%s\n' 'PASS: Gemma image attachment'

run_stream_client() {
  local child_pid child_status
  "$LLM_BIN" -n -m qwen-4b -o think false -o temperature 0 \
    -o num_predict 1024 \
    'Write a long numbered list of 300 short facts. Do not stop early.' &
  child_pid=$!
  printf '%s\n' "$child_pid" >"$TEST_DIR/stream.pid"
  set +e
  wait "$child_pid"
  child_status=$?
  set -e
  [[ ! -e "$TEST_DIR/interrupt-requested" ]] || exit 130
  exit "$child_status"
}

stream_file="$TEST_DIR/stream.out"
run_stream_client >"$stream_file" 2>&1 &
STREAM_PID=$!
for _ in {1..100}; do
  [[ -s "$TEST_DIR/stream.pid" ]] && break
  pid_is_running "$STREAM_PID" || break
  sleep 0.1
done
[[ -s "$TEST_DIR/stream.pid" ]] || fail 'stream client did not publish its child PID'
STREAM_CHILD_PID=$(<"$TEST_DIR/stream.pid")
[[ "$STREAM_CHILD_PID" =~ ^[0-9]+$ ]] || fail 'stream client published an invalid child PID'
stream_observed=false
for _ in {1..300}; do
  if [[ -s "$stream_file" ]] && pid_is_running "$STREAM_CHILD_PID"; then
    stream_observed=true
    break
  fi
  pid_is_running "$STREAM_CHILD_PID" || break
  sleep 0.1
done
[[ "$stream_observed" == true ]] || fail 'streaming output was not observed before completion'
touch "$TEST_DIR/interrupt-requested"
kill -INT "$STREAM_CHILD_PID" 2>/dev/null || fail 'could not interrupt the active stream'
wait_for_pid_exit "$STREAM_CHILD_PID" 30 || {
  kill -TERM "$STREAM_CHILD_PID" 2>/dev/null || true
  wait_for_pid_exit "$STREAM_CHILD_PID" 30 || {
    kill -KILL "$STREAM_CHILD_PID" 2>/dev/null || true
    wait_for_pid_exit "$STREAM_CHILD_PID" 30 ||
      fail 'stream client child survived bounded INT, TERM, and KILL attempts'
  }
}
STREAM_CHILD_PID=
wait_for_pid_exit "$STREAM_PID" 30 || {
  terminate_pid_bounded "$STREAM_PID"
  fail 'stream client wrapper did not reap its interrupted child within 3 seconds'
}
set +e
wait "$STREAM_PID"
interrupt_status=$?
set -e
STREAM_PID=
[[ "$interrupt_status" -ne 0 ]] || fail 'interrupted stream unexpectedly exited successfully'
curl --silent --show-error --fail --max-time 3 "$OLLAMA_URL/api/version" >/dev/null ||
  fail 'Ollama was unhealthy after stream interruption'
printf '%s\n' 'PASS: streaming and interruption'

set +e
missing_output=$($LLM_BIN -n -m agent-lab-model-does-not-exist --no-stream \
  'This must fail locally.' 2>&1)
missing_status=$?
set -e
[[ "$missing_status" -ne 0 ]] || fail 'unavailable model unexpectedly succeeded'
[[ "$missing_output" == *'Unknown model'* ]] ||
  fail 'unavailable model did not return a clear local error'
printf '%s\n' 'PASS: unavailable model fails without a pull or fallback'

offline_output=$(env \
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
  ALL_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
  "$LLM_BIN" -n -m qwen-4b --no-stream -o think false \
  -o temperature 0 -o num_predict 24 \
  'Reply with exactly: AGENT_LAB_OFFLINE_OK')
[[ "$offline_output" == *'AGENT_LAB_OFFLINE_OK'* ]] || fail 'offline local prompt failed'
[[ ! -e "$TEST_DIR/keys.json" ]] || fail 'smoke test wrote credentials'
printf '%s\n' 'PASS: offline local execution with isolated history and no credentials'
printf '%s\n' 'PASS: LLM CLI smoke test'
