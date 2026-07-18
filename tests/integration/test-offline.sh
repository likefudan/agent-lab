#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

before=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf '%s' online-manual)
"$ROOT/scripts/offline-verify.sh" --config-only --quick
after=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf '%s' online-manual)
[[ $after == "$before" ]] || fail 'offline verification did not restore the prior profile'
jq -e '.status == "pass" and .boundary == "configuration_only" and .remote_attempts.search == "denied" and .remote_attempts.model_pull == "denied" and .remote_attempts.remote_model == "denied"' \
  "$ROOT/.agent-lab/results/offline-latest.json" >/dev/null || fail 'offline result artifact is invalid'

if "$ROOT/scripts/offline-verify.sh" --config-only --boundary-confirmed >/dev/null 2>&1; then
  fail 'offline verifier accepted mutually exclusive boundary modes'
fi

printf '%s\n' 'PASS: offline configuration, denial paths, local chat, and profile cleanup'
