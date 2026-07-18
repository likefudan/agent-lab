#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CLI="${ROOT}/bin/agent-lab"
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect_status() {
  local expected=$1
  shift
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  [[ "$actual" -eq "$expected" ]] || fail "expected exit ${expected}, got ${actual}: $*"
}

help_output="$($CLI --help)"
[[ "$help_output" == *'offline verify'* ]] || fail 'help omits offline verify'
[[ "$help_output" == *'doctor'* ]] || fail 'help omits doctor'

expect_status "$EX_USAGE" "$CLI"
expect_status "$EX_USAGE" "$CLI" unknown-command
expect_status "$EX_USAGE" "$CLI" offline
expect_status "$EX_USAGE" "$CLI" offline unknown

# Doctor exists and owns its own host-dependent result. Dispatch is proven by
# checking its stable heading rather than requiring an unprepared host to pass.
doctor_status=0
doctor_output="$($CLI doctor 2>&1)" || doctor_status=$?
[[ "$doctor_output" == *'Agent Lab doctor (read-only)'* ]] || fail 'doctor was not dispatched'
[[ "$doctor_status" -eq 0 || "$doctor_status" -eq 1 ]] || fail 'doctor returned an unexpected status'

# Implemented downstream scripts must dispatch, while pending commands remain
# distinguishable from successful execution and invalid syntax.
setup_output="$($CLI setup --help)"
[[ "$setup_output" == *'agent-lab setup'* ]] || fail 'setup was not dispatched'
models_output="$($CLI models list)"
[[ "$models_output" == *'qwen-9b'* ]] || fail 'models was not dispatched'
offline_help="$($CLI offline verify --help)"
[[ "$offline_help" == *'--boundary-confirmed'* ]] || fail 'offline verifier was not dispatched'
expect_status "$EX_USAGE" "$CLI" offline verify

tmp_parent="$(mktemp -d "${TMPDIR:-/tmp}/agent lab cli.XXXXXX")"
trap 'rm -rf "$tmp_parent"' EXIT
ln -s "$ROOT" "$tmp_parent/repository with spaces"
space_cli="$tmp_parent/repository with spaces/bin/agent-lab"
[[ "$("$space_cli" --help)" == "$help_output" ]] || fail 'help depends on a space-free path'
[[ "$("$space_cli" setup --help)" == *'agent-lab setup'* ]] || fail 'setup depends on a space-free path'

printf '%s\n' 'PASS: agent-lab dispatcher'
