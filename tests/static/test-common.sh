#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck source=../../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command_exists sh || fail 'command_exists rejected sh'
! command_exists agent-lab-command-that-does-not-exist || fail 'command_exists accepted missing command'
version_at_least 2.30.1 2.30 || fail 'version comparison rejected newer version'
! version_at_least 1.9 2.0 || fail 'version comparison accepted older version'
[ "$(repository_root "$ROOT/tests")" = "$ROOT" ] || fail 'repository root discovery failed'

tmp_dir=$(mktemp -d)
trap 'rm -f "$tmp_dir"/*; rmdir "$tmp_dir"' EXIT HUP INT TERM
printf '{"answer":42}\n' > "$tmp_dir/value.json"
[ "$(json_get "$tmp_dir/value.json" '.answer')" = 42 ] || fail 'JSON lookup failed'

marker=$tmp_dir/executed
printf '%s\n' 'SAFE_VALUE="plain value"' 'DANGEROUS_VALUE=$(touch '"$marker"')' > "$tmp_dir/profile.env"
load_profile "$tmp_dir/profile.env"
[ "$SAFE_VALUE" = 'plain value' ] || fail 'profile value not loaded'
[ ! -e "$marker" ] || fail 'profile executed shell code'
[ "$DANGEROUS_VALUE" = '$(touch '"$marker"')' ] || fail 'profile content changed unexpectedly'

! port_is_available invalid >/dev/null 2>&1 || fail 'invalid port accepted'
! require_available_port invalid >/dev/null 2>&1 || fail 'invalid required port accepted'
! confirm 'noninteractive prompt' no || fail 'noninteractive confirmation accepted'

# Bash 3.2 with nounset must tolerate an empty cleanup registry, both directly
# and when the EXIT trap invokes it.
AGENT_LAB_CLEANUP_PATHS=
cleanup_registered_paths
(AGENT_LAB_CLEANUP_PATHS=; install_cleanup_trap)

touch "$tmp_dir/cleanup"
register_cleanup_path "$tmp_dir/cleanup"
cleanup_registered_paths
[ ! -e "$tmp_dir/cleanup" ] || fail 'registered file was not cleaned'

(cd / && [ "$(repository_root "$ROOT/scripts")" = "$ROOT" ]) || fail 'root discovery depends on cwd'
printf '%s\n' 'PASS: common shell helpers'
