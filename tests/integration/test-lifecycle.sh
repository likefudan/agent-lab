#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CLI="${ROOT}/bin/agent-lab"
readonly ENV_FILE="${ROOT}/.env"
readonly VOLUME='agent-lab-open-webui-data'
restore_running=false

cleanup() {
  if [[ "$restore_running" == true ]]; then
    "$CLI" start >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[[ -r "$ENV_FILE" ]] || fail "run agent-lab setup first: $ENV_FILE is missing"
docker info >/dev/null 2>&1 || fail 'Docker engine is unavailable'
[[ -f "$HOME/Library/LaunchAgents/ai.agent-lab.ollama.plist" ]] ||
  fail 'Agent Lab Ollama LaunchAgent is not installed'

volume_mount=$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")
[[ -n "$volume_mount" ]] || fail 'Open WebUI volume is missing'

"$CLI" start >/dev/null
"$CLI" start >/dev/null
"$CLI" health >/dev/null || fail 'repeated start did not produce a healthy stack'

restore_running=true
"$CLI" stop >/dev/null
if "$CLI" health >"${TMPDIR:-/tmp}/agent-lab-stopped-health.$$" 2>&1; then
  fail 'health unexpectedly passed while core services were stopped'
fi
grep -Eq 'FAIL  Ollama( endpoint)?: unavailable' "${TMPDIR:-/tmp}/agent-lab-stopped-health.$$" ||
  fail 'stopped Ollama was not diagnosed'
grep -Eq 'FAIL  Open WebUI: unavailable' "${TMPDIR:-/tmp}/agent-lab-stopped-health.$$" ||
  fail 'stopped Open WebUI was not diagnosed'
rm -f "${TMPDIR:-/tmp}/agent-lab-stopped-health.$$"

"$CLI" stop >/dev/null
[[ "$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")" == "$volume_mount" ]] ||
  fail 'persistent volume changed after repeated stop'

"$CLI" start >/dev/null
"$CLI" health >/dev/null || fail 'stack did not recover after stop'

docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" -f "$ROOT/compose.yaml" \
  stop --timeout 30 open-webui >/dev/null
if "$CLI" health >"${TMPDIR:-/tmp}/agent-lab-webui-health.$$" 2>&1; then
  fail 'health unexpectedly passed with Open WebUI stopped'
fi
grep -q 'PASS  Ollama' "${TMPDIR:-/tmp}/agent-lab-webui-health.$$" ||
  fail 'healthy Ollama was not preserved while WebUI was stopped'
grep -Eq 'FAIL  Open WebUI: unavailable' "${TMPDIR:-/tmp}/agent-lab-webui-health.$$" ||
  fail 'stopped Open WebUI was not diagnosed'
rm -f "${TMPDIR:-/tmp}/agent-lab-webui-health.$$"

"$CLI" start >/dev/null
restore_running=false
"$CLI" health >/dev/null || fail 'final stack health failed'
[[ "$(docker volume inspect --format '{{.Mountpoint}}' "$VOLUME")" == "$volume_mount" ]] ||
  fail 'persistent volume changed after recovery'

printf '%s\n' 'PASS: idempotent stack lifecycle and persistent volume'
