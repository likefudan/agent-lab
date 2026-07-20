#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
run() {
  local script=$1
  if [[ -x $script ]]; then
    "$script" || fail=1
  else
    printf 'SKIP: %s is not executable\n' "$script"
  fi
}

printf '%s\n' 'Integration checks'
# Offline and search are intentionally ordered later / separately in the
# acceptance matrix so offline proof stays unambiguous.
run tests/integration/test-models.sh
run tests/integration/test-lifecycle.sh

# Isolated Ollama lifecycle needs a free loopback:11434. When the managed
# LaunchAgent is already bound, skip rather than fighting the live stack.
if lsof -nP -iTCP@127.0.0.1:11434 -sTCP:LISTEN >/dev/null 2>&1; then
  printf '%s\n' 'SKIP: tests/integration/test-model-lifecycle.sh (127.0.0.1:11434 is occupied; stop managed Ollama to run the isolated lifecycle drill)'
else
  run tests/integration/test-model-lifecycle.sh
fi

run tests/integration/test-rag.sh
run tests/integration/test-backup-restore.sh
run tests/integration/test-diagnostics.sh
run tests/integration/test-backends.sh

if [[ $fail -ne 0 ]]; then
  printf '%s\n' 'FAIL: one or more integration checks failed' >&2
  exit 1
fi
printf '%s\n' 'PASS: integration checks'
