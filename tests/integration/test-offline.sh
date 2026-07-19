#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

before=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf '%s' online-manual)
"$ROOT/scripts/offline-verify.sh" --config-only --quick
after=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf '%s' online-manual)
[[ $after == "$before" ]] || fail 'offline verification did not restore the prior profile'
jq -e '.status == "pass" and .boundary == "configuration_only" and .remote_attempts.search == "denied" and .remote_attempts.model_pull == "denied" and .remote_attempts.remote_model == "denied" and .remote_attempts.version_update_check == "disabled" and .remote_attempts.remote_tools == "disabled" and (.outbound_evidence | type == "array" and length >= 1)' \
  "$ROOT/.agent-lab/results/offline-latest.json" >/dev/null || fail 'offline result artifact is invalid'

if "$ROOT/scripts/offline-verify.sh" --config-only --boundary-confirmed >/dev/null 2>&1; then
  fail 'offline verifier accepted mutually exclusive boundary modes'
fi

# Interrupted verification must restore the prior profile via the EXIT trap.
# Bash 3.2 on macOS does not reliably deliver SIGINT during sleep, so the hold
# mode watches .agent-lab/offline-verify.stop instead of relying on signals.
interrupt_before=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf '%s' online-manual)
rm -f -- "$ROOT/.agent-lab/offline-verify.stop" "$ROOT/.agent-lab/offline-verify.pid"
AGENT_LAB_OFFLINE_TEST_HOLD=1 "$ROOT/scripts/offline-verify.sh" --config-only --quick >/tmp/agent-lab-offline-interrupt.log 2>&1 &
interrupt_pid=$!
for _ in {1..240}; do
  current=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || true)
  if [[ $current == offline && -f $ROOT/.agent-lab/offline-verify.pid ]]; then
    break
  fi
  if ! kill -0 "$interrupt_pid" 2>/dev/null; then
    wait "$interrupt_pid" || true
    fail 'offline hold process exited before applying the offline profile'
  fi
  sleep 0.5
done
[[ $(cat "$ROOT/.agent-lab/profile" 2>/dev/null || true) == offline ]] || fail 'offline hold never reached the offline profile'
[[ -f $ROOT/.agent-lab/offline-verify.pid ]] || fail 'offline hold never wrote its pid file'
: > "$ROOT/.agent-lab/offline-verify.stop"
wait "$interrupt_pid" || true
interrupt_after=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf '%s' online-manual)
[[ $interrupt_after == "$interrupt_before" ]] || fail "interrupted offline verification did not restore profile (before=$interrupt_before after=$interrupt_after)"
[[ ! -f $ROOT/.agent-lab/offline-verify.stop ]] || fail 'offline hold left a stop file behind'
[[ ! -f $ROOT/.agent-lab/offline-verify.pid ]] || fail 'offline hold left a pid file behind'

printf '%s\n' 'PASS: offline configuration, denial paths, local chat, interrupt cleanup, and profile cleanup'
