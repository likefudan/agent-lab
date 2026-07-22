#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CLI="$ROOT/bin/agent-lab"
restart_managed_stack=false

cleanup() {
  if [[ $restart_managed_stack == true ]]; then
    "$CLI" start >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM

run_test() {
  local test_script=$1
  printf '==> integration/%s\n' "$test_script"
  "$ROOT/tests/integration/$test_script"
}

# Network-dependent search, strict offline verification, Promptfoo, and the
# hardware benchmark are intentionally separate release-matrix rows.
run_test test-diagnostics.sh
run_test test-models.sh
run_test test-lifecycle.sh
run_test test-task-config.sh
run_test test-rag.sh
run_test test-backup-restore.sh

# This test owns port 11434 so it can validate server restart and cancellation
# without mutating the installed launch-agent definition.
printf '%s\n' '==> integration/test-model-lifecycle.sh (isolated Ollama server)'
restart_managed_stack=true
"$CLI" stop >/dev/null
"$ROOT/tests/integration/test-model-lifecycle.sh"
"$CLI" start >/dev/null
restart_managed_stack=false
"$CLI" health >/dev/null

printf '%s\n' 'PASS: integration suite'
