#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DOCTOR=$ROOT/scripts/doctor.sh
tmp_dir=$(mktemp -d)
trap 'rm -f "$tmp_dir"/*; rmdir "$tmp_dir"' EXIT HUP INT TERM

run_doctor() {
    local output_file=$1
    local test_path=$2
    (cd / && PATH="$test_path" "$DOCTOR") > "$output_file" 2>&1
}

# Fake an old jq while leaving the other host tools discoverable.
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "printf 'jq-1.5\\n'" > "$tmp_dir/jq"
chmod +x "$tmp_dir/jq"
if run_doctor "$tmp_dir/old.out" "$tmp_dir:/usr/bin:/bin"; then
    printf '%s\n' 'FAIL: doctor accepted an unsupported mandatory dependency' >&2
    exit 1
fi
grep -q 'FAIL  jq: unsupported version 1.5; need >= 1.6' "$tmp_dir/old.out"
grep -q '^SUMMARY pass/warn/fail:' "$tmp_dir/old.out"

# A restricted PATH must report missing software and must still be concise.
mv "$tmp_dir/jq" "$tmp_dir/jq.hidden"
ln -s /usr/bin/dirname "$tmp_dir/dirname"
ln -s /usr/bin/awk "$tmp_dir/awk"
ln -s /bin/bash "$tmp_dir/bash"
if run_doctor "$tmp_dir/missing.out" "$tmp_dir"; then
    printf '%s\n' 'FAIL: doctor accepted missing mandatory dependencies' >&2
    exit 1
fi
grep -q 'FAIL  jq: missing required software' "$tmp_dir/missing.out"
grep -q 'optional client' "$tmp_dir/missing.out"
grep -Eq 'evaluation prerequisite|pinned evaluation tool' "$tmp_dir/missing.out"
! grep -Eiq 'token=|password=|secret=' "$tmp_dir/missing.out"
[ "$(wc -l < "$tmp_dir/missing.out" | tr -d ' ')" -le 25 ]

# Running from the repository root is also supported. A mandatory failure on
# an unprepared host is expected; this test validates output, not host state.
(cd "$ROOT" && "$DOCTOR") > "$tmp_dir/root.out" 2>&1 || true
grep -q '^Agent Lab doctor (read-only)$' "$tmp_dir/root.out"
grep -q '^SUMMARY pass/warn/fail:' "$tmp_dir/root.out"

printf '%s\n' 'PASS: doctor smoke tests'
