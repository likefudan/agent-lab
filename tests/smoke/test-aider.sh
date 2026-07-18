#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CONFIG_DIR="$ROOT/config/aider"
readonly FIXTURE_DIR="$ROOT/tests/fixtures/aider-repo"
readonly EXPECTED_AIDER_VERSION='0.86.2'
readonly DEFAULT_AIDER_BIN="$HOME/.local/bin/aider"
readonly AIDER_BIN="${AGENT_LAB_AIDER_BIN:-$DEFAULT_AIDER_BIN}"
readonly OLLAMA_URL="${OLLAMA_HOST:-http://127.0.0.1:11434}"
TEST_ROOT=
MOCK_PID=

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  [[ -z "$TEST_ROOT" ]] || rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

copy_seed() {
  local repo=$1
  cp "$CONFIG_DIR/aider.conf.yml" "$repo/.aider.conf.yml"
  cp "$CONFIG_DIR/aider.model.settings.yml" "$repo/.aider.model.settings.yml"
  cp "$CONFIG_DIR/aider.model.metadata.json" "$repo/.aider.model.metadata.json"
  mkdir -p "$repo/.agent-lab/aider"
}

new_fixture_repo() {
  local name=$1 repo="$TEST_ROOT/$1"
  mkdir -p "$repo"
  cp "$FIXTURE_DIR/calculator.py" "$FIXTURE_DIR/test_calculator.py" \
    "$FIXTURE_DIR/protected.txt" "$repo/"
  (
    cd "$repo"
    git init -q
    git add calculator.py test_calculator.py protected.txt
    git commit -qm baseline
  )
  copy_seed "$repo"
  printf '%s\n' "$repo"
}

run_aider() {
  local repo=$1 output=$2
  shift 2
  (
    cd "$repo"
    env \
      HTTP_PROXY=http://127.0.0.1:9 \
      HTTPS_PROXY=http://127.0.0.1:9 \
      ALL_PROXY=http://127.0.0.1:9 \
      NO_PROXY=127.0.0.1,localhost \
      "$AIDER_BIN" --config .aider.conf.yml --yes-always --no-fancy-input \
      "$@"
  ) >"$output" 2>&1
}

assert_clean_scope() {
  local repo=$1 baseline_commit=$2
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$baseline_commit" ]] ||
    fail 'Aider created a commit despite the review-first configuration'
  [[ "$(git -C "$repo" status --short --untracked-files=no)" == ' M calculator.py' ]] ||
    fail 'Aider modified a tracked file outside calculator.py'
  [[ "$(<"$repo/protected.txt")" == 'AGENT_LAB_AIDER_PROTECTED_SENTINEL' ]] ||
    fail 'Aider changed the protected out-of-scope sentinel'
  cmp -s "$repo/test_calculator.py" "$FIXTURE_DIR/test_calculator.py" ||
    fail 'Aider changed the out-of-scope test file'
  local expected_diff
  expected_diff=$'diff --git a/calculator.py b/calculator.py\nindex 8390b7f..e2907f6 100644\n--- a/calculator.py\n+++ b/calculator.py\n@@ -1,3 +1,3 @@\n def add(left: int, right: int) -> int:\n     """Return the sum of two integers."""\n-    return left - right\n+    return left + right'
  [[ "$(git -C "$repo" diff -- calculator.py)" == "$expected_diff" ]] ||
    fail 'Aider repair was not the expected minimal one-line diff'
  (cd "$repo" && python3 -m unittest -q) || fail 'repaired fixture tests failed'
}

[[ -x "$AIDER_BIN" ]] || fail "pinned Aider is missing: $AIDER_BIN"
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v git >/dev/null 2>&1 || fail 'git is required'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
[[ "$OLLAMA_URL" == 'http://127.0.0.1:11434' ]] ||
  fail "OLLAMA_HOST must be the Agent Lab loopback endpoint, got: $OLLAMA_URL"
[[ "$($AIDER_BIN --version | awk '{print $NF}')" == "$EXPECTED_AIDER_VERSION" ]] ||
  fail "Aider version mismatch; expected $EXPECTED_AIDER_VERSION"
curl --silent --show-error --fail --max-time 3 "$OLLAMA_URL/api/version" >/dev/null ||
  fail 'local Ollama is unavailable; start Agent Lab before running this smoke test'

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-aider-smoke.XXXXXX")
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)

repair_repo=$(new_fixture_repo repair)
repair_head=$(git -C "$repair_repo" rev-parse HEAD)
run_aider "$repair_repo" "$TEST_ROOT/repair.out" \
  --message-file "$FIXTURE_DIR/repair-request.txt" calculator.py || {
    sed -n '1,240p' "$TEST_ROOT/repair.out" >&2
    fail 'local noninteractive repair failed'
  }
assert_clean_scope "$repair_repo" "$repair_head"
grep -Fq 'Model: openai/gemma4:12b with whole edit format' "$TEST_ROOT/repair.out" ||
  fail 'Aider did not select the qualified model and edit format'
printf '%s\n' 'PASS: minimal reviewable repair, passing tests, and Git ownership'

port_file="$TEST_ROOT/mock.port"
python3 "$FIXTURE_DIR/mock_openai.py" --port-file "$port_file" &
MOCK_PID=$!
for _ in {1..100}; do
  [[ -s "$port_file" ]] && break
  kill -0 "$MOCK_PID" 2>/dev/null || fail 'local OpenAI fixture server exited'
  sleep 0.05
done
[[ -s "$port_file" ]] || fail 'local OpenAI fixture server did not start'
mock_port=$(<"$port_file")

missing_repo=$(new_fixture_repo missing)
missing_head=$(git -C "$missing_repo" rev-parse HEAD)
run_aider "$missing_repo" "$TEST_ROOT/missing.out" \
  --openai-api-base "http://127.0.0.1:$mock_port/v1" \
  --message 'This request must fail locally without editing anything.' calculator.py
grep -Eiq 'NotFoundError.*model|model.*not found|404' "$TEST_ROOT/missing.out" ||
  fail 'unavailable model did not return a clear local error'
if grep -Eq 'raw\.githubusercontent\.com|api\.openai\.com' "$TEST_ROOT/missing.out"; then
  fail 'unavailable-model path attempted a hosted metadata or inference service'
fi
[[ "$(git -C "$missing_repo" rev-parse HEAD)" == "$missing_head" ]] ||
  fail 'unavailable-model path created a commit'
[[ -z "$(git -C "$missing_repo" status --short --untracked-files=no)" ]] ||
  fail 'unavailable-model path changed a tracked file'
printf '%s\n' 'PASS: unavailable model fails locally without mutation or fallback'

malformed_repo=$(new_fixture_repo malformed)
malformed_head=$(git -C "$malformed_repo" rev-parse HEAD)
run_aider "$malformed_repo" "$TEST_ROOT/malformed.out" \
  --openai-api-base "http://127.0.0.1:$mock_port/v1" \
  --edit-format diff \
  --message 'Fix only calculator.py so the unit tests pass.' calculator.py || {
    sed -n '1,240p' "$TEST_ROOT/malformed.out" >&2
    fail 'Aider did not recover from the malformed first edit'
  }
assert_clean_scope "$malformed_repo" "$malformed_head"
grep -Fq 'SEARCH/REPLACE block failed to match' "$TEST_ROOT/malformed.out" ||
  fail 'malformed edit was not detected before recovery'
printf '%s\n' 'PASS: malformed edit is detected, retried, and repaired safely'

[[ ! -e "$repair_repo/.agent-lab/aider/keys.json" ]] ||
  fail 'Aider wrote a hosted credential file'
printf '%s\n' 'PASS: proxy-blocked offline execution used only local loopback services'
printf '%s\n' 'PASS: Aider smoke test'
