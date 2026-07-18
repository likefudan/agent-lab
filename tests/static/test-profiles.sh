#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/profile.sh
. "$ROOT/scripts/lib/profile.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-profiles.XXXXXX")
cleanup() { rm -rf -- "$temporary_dir"; }
trap cleanup EXIT HUP INT TERM

for profile in offline online-manual online-automatic; do
    agent_lab_validate_profile "$profile" || fail "valid profile rejected: $profile"
    effective=$(agent_lab_effective_profile "$profile")
    [ "$(printf '%s\n' "$effective" | wc -l | tr -d ' ')" -eq 13 ] ||
        fail "effective profile is not complete: $profile"
    printf '%s\n' "$effective" | grep -Fqx "AGENT_LAB_PROFILE=$profile" ||
        fail "effective profile omits its identity: $profile"
done

unset AGENT_LAB_PROFILE
[ "$(agent_lab_selected_profile)" = online-manual ] || fail 'default profile is not online-manual'

fixture_dir="$temporary_dir/profiles"
mkdir -p "$fixture_dir"
cp "$ROOT/config/profiles/online-manual.env" "$fixture_dir/online-manual.env"
cp "$ROOT/config/profiles/offline.env" "$fixture_dir/offline.env"
cp "$ROOT/config/profiles/online-automatic.env" "$fixture_dir/online-automatic.env"
AGENT_LAB_PROFILE_DIR=$fixture_dir
export AGENT_LAB_PROFILE_DIR

printf '%s\n' 'UNKNOWN_REMOTE_ENDPOINT=https://example.invalid' >> "$fixture_dir/offline.env"
if agent_lab_validate_profile offline >/dev/null 2>&1; then
    fail 'unknown profile key was accepted'
fi
cp "$ROOT/config/profiles/offline.env" "$fixture_dir/offline.env"

marker="$temporary_dir/injected"
awk -v marker="$marker" '
    /^WEB_SEARCH_ENGINE=/ { print "WEB_SEARCH_ENGINE=$(touch " marker ")"; next }
    { print }
' "$ROOT/config/profiles/offline.env" > "$fixture_dir/offline.env"
if agent_lab_validate_profile offline >/dev/null 2>&1; then
    fail 'injected profile value was accepted'
fi
[ ! -e "$marker" ] || fail 'profile validation executed injected shell syntax'
cp "$ROOT/config/profiles/offline.env" "$fixture_dir/offline.env"

manual=$(agent_lab_effective_profile online-manual)
automatic=$(agent_lab_effective_profile online-automatic)
offline=$(agent_lab_effective_profile offline)
[ "$manual" != "$automatic" ] || fail 'manual and automatic effective configs are identical'
[ "$manual" != "$offline" ] || fail 'online and offline effective configs are identical'
printf '%s\n' "$manual" | grep -Fqx 'AGENT_LAB_SEARCH_MODE=manual' ||
    fail 'manual effective config does not require explicit search'
printf '%s\n' "$offline" | grep -Fqx 'ENABLE_WEB_SEARCH=false' ||
    fail 'offline effective config exposes search'
printf '%s\n' "$offline" | grep -Fqx 'AGENT_LAB_ALLOW_MODEL_PULLS=false' ||
    fail 'offline effective config permits model pulls'
! printf '%s\n' "$offline" | grep -E 'https?://|OPENAI|REMOTE_ENDPOINT' >/dev/null ||
    fail 'offline profile can configure a remote model endpoint'

state_file="$temporary_dir/state/profile"
AGENT_LAB_PROFILE_STATE_FILE=$state_file
export AGENT_LAB_PROFILE_STATE_FILE
persistent_data="$temporary_dir/persistent-chat-data"
printf '%s\n' 'must survive profile switches' > "$persistent_data"
recreate_log="$temporary_dir/recreate.log"
mock_recreate() {
    printf '%s\t%s\n' "$1" "$2" >> "$recreate_log"
}

[ "$(agent_lab_active_profile)" = online-manual ] || fail 'missing state did not select the default'
if agent_lab_profile_restart_required online-manual; then
    fail 'default profile incorrectly requires restart'
fi
agent_lab_profile_restart_required offline || fail 'profile change did not require restart'
agent_lab_switch_profile offline mock_recreate true || fail 'confirmed profile switch failed'
[ "$(agent_lab_active_profile)" = offline ] || fail 'profile state was not updated'
[ "$(cat "$persistent_data")" = 'must survive profile switches' ] || fail 'profile switch altered persistent data'
[ "$(cat "$recreate_log")" = $'offline\topen-webui' ] || fail 'switch recreated an unexpected service'
agent_lab_switch_profile offline mock_recreate true || fail 'repeated switch failed'
[ "$(wc -l < "$recreate_log" | tr -d ' ')" -eq 1 ] || fail 'repeated switch recreated Open WebUI'
if agent_lab_profile_restart_required offline; then
    fail 'active profile still reports restart required'
fi
agent_lab_profile_restart_required online-automatic || fail 'new profile did not report restart required'

printf '%s\n' 'PASS: validated, restart-aware Agent Lab configuration profiles'
