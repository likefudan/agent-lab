#!/bin/bash
# T06 acceptance check on a fresh clone of the current commit (HEAD), with the
# tiny CI model (profile ci-tiny): a shortened `alab bench --quick` runs every
# section through the gateway and writes its reports. It checks the flow, not
# the numbers (those come from the device run in docs/benchmarks/).
#
#   1. `alab bench` refuses to run while nothing is served;
#   2. with the service up, every section completes without failed requests;
#   3. report.json and report.md exist, the backend's per-request statistics
#      were read, the agent conversation filled max_context;
#   4. the temporary API key is revoked again; HOME stays empty.
#
# Uncommitted changes are not tested.
set -eu -o pipefail

PROFILE=ci-tiny
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
REPO="$WORK/repo"
FAKE_HOME="$WORK/home"
mkdir "$FAKE_HOME"

cleanup() {
    if [ -x "$REPO/alab" ]; then (cd "$REPO" && HOME="$FAKE_HOME" ./alab stop > /dev/null 2>&1) || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n### %s\n' "$*"; }
fail() {
    printf 'ACCEPTANCE FAILED: %s\n' "$*" >&2
    for log in gateway.log backend.log; do
        if [ -f "$REPO/var/logs/$log" ]; then
            echo "--- end of var/logs/$log" >&2
            tail -n 40 "$REPO/var/logs/$log" >&2
        fi
    done
    exit 1
}
in_repo() { (cd "$REPO" && env HOME="$FAKE_HOME" "$@"); }
alab() { in_repo ./alab "$@"; }

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "note: uncommitted changes in $ROOT are not part of this check"
fi

step "fresh clone of $(git -C "$ROOT" rev-parse --short HEAD), bootstrap and pull"
git clone --quiet --no-checkout "$ROOT" "$REPO"
git -C "$REPO" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)"
in_repo ./bootstrap.sh > "$WORK/bootstrap.txt" 2>&1 || {
    cat "$WORK/bootstrap.txt"
    fail "bootstrap failed"
}
alab pull --profile "$PROFILE" > "$WORK/pull.txt" 2>&1 || {
    cat "$WORK/pull.txt"
    fail "pull failed"
}

step "bench without a running service"
status=0
alab bench --profile "$PROFILE" --quick > "$WORK/idle.txt" 2>&1 || status=$?
cat "$WORK/idle.txt"
[ "$status" = 1 ] || fail "bench without a service exited with $status, expected 1"
grep "start both first" "$WORK/idle.txt" > /dev/null || fail "bench did not say to start the service"

step "serve"
alab keys create ci > /dev/null
alab serve --profile "$PROFILE" > "$WORK/serve.txt" 2>&1 || {
    cat "$WORK/serve.txt"
    fail "serve failed"
}

step "alab bench --quick"
alab bench --profile "$PROFILE" --quick 2>&1 | tee "$WORK/bench.txt" || fail "bench exited with $?"
report_dir=$(find "$REPO/var/bench" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$report_dir" ] || fail "no report directory under var/bench"
[ -s "$report_dir/report.md" ] || fail "report.md is missing"
cat "$report_dir/report.md"
"$REPO/.venv/bin/python" - "$report_dir/report.json" << 'PY' || fail "report.json does not have the expected content"
import json
import sys

report = json.load(open(sys.argv[1]))
sections = report["sections"]
expected = ["cache", "prefill", "decode", "agent", "sustained", "offline"]
assert list(sections) == expected, list(sections)
for name, section in sections.items():
    assert "failed" not in section, (name, section)
rows = [*sections["cache"]["turns"], *sections["prefill"]["rows"], *sections["decode"]["rows"]]
rows += [r for run in sections["agent"]["runs"] for r in run["rounds"]]
assert all(r["ok"] for r in rows), [r["error"] for r in rows if not r["ok"]]
assert all(r["backend_stats"] for r in rows), "the backend's statistics were not read"
assert all(r["metal_peak_bytes"] > 0 for r in rows)
assert sections["cache"]["verdict"], sections["cache"]
assert all(run["filled"] for run in sections["agent"]["runs"])
assert sections["sustained"]["rows"], sections["sustained"]
assert sections["offline"]["request"]["ok"]
assert not sections["offline"]["outside_sockets"], sections["offline"]
print("report.json has all sections, numbers from the backend and a filled conversation")
PY

step "the temporary key is gone"
alab keys list | tee "$WORK/keys.txt"
if grep '^bench-' "$WORK/keys.txt"; then fail "the bench key was not revoked"; fi
grep '^ci ' "$WORK/keys.txt" > /dev/null || fail "the existing key disappeared"

step "stop and isolation"
alab stop
[ -z "$(ls -A "$FAKE_HOME")" ] || {
    find "$FAKE_HOME" >&2
    fail "files were written under HOME"
}
echo "HOME is empty"

printf '\nAll T06 acceptance checks passed.\n'
