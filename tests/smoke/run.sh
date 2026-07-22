#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

"$ROOT/bin/agent-lab" start >/dev/null
"$ROOT/bin/agent-lab" health >/dev/null

tests=(
  test-doctor.sh
  test-webui.sh
  test-llm-cli.sh
  test-aider.sh
)

for test_script in "${tests[@]}"; do
  printf '==> smoke/%s\n' "$test_script"
  "$ROOT/tests/smoke/$test_script"
done

printf '%s\n' 'PASS: smoke suite'
