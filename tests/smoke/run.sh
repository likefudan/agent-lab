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

printf '%s\n' 'Smoke checks'
run tests/smoke/test-doctor.sh
run tests/smoke/test-llm-cli.sh
run tests/smoke/test-aider.sh
run tests/smoke/test-webui.sh

if [[ $fail -ne 0 ]]; then
  printf '%s\n' 'FAIL: one or more smoke checks failed' >&2
  exit 1
fi
printf '%s\n' 'PASS: smoke checks'
