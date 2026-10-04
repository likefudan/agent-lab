#!/bin/bash
# T02 acceptance checks on a fresh clone of the current commit (HEAD), using
# the CI model from config/models.toml (downloaded from Hugging Face):
#
#   1. an interrupted `alab pull` (SIGINT, as Ctrl-C sends) resumes instead of
#      starting over, and the result verifies;
#   2. a second pull downloads nothing;
#   3. a wrong sha256 in the registry makes the pull fail and deletes the file;
#   4. HOME (a new empty directory) is still empty, so nothing went to
#      ~/.cache/huggingface, and new files are only under .tools/, .venv/, var/.
#
# Uncommitted changes are not tested. Pass a model id to test another model.
set -eu
# Job control: background jobs get their own process group and keep the default
# SIGINT handling, so the interrupt below reaches `alab pull` like a Ctrl-C.
set -m

MODEL=${1:-qwen3-0.6b-mlx-4bit}
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
FAKE_HOME="$WORK/home"
mkdir "$FAKE_HOME"

step() { printf '\n### %s\n' "$*"; }
fail() { printf 'ACCEPTANCE FAILED: %s\n' "$*" >&2; exit 1; }

in_repo() { (cd "$REPO" && env HOME="$FAKE_HOME" "$@"); }

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "note: uncommitted changes in $ROOT are not part of this check"
fi

step "fresh clone of $(git -C "$ROOT" rev-parse --short HEAD) and bootstrap"
git clone --quiet --no-checkout "$ROOT" "$REPO"
git -C "$REPO" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)"
in_repo ./bootstrap.sh > "$WORK/bootstrap.txt" 2>&1 || {
    cat "$WORK/bootstrap.txt"
    fail "bootstrap failed"
}
PARTIAL="$REPO/var/models/$MODEL/.alab/partial"

step "interrupt a pull"
# A rate limit keeps the download running long enough to interrupt it.
in_repo ./alab pull "$MODEL" --limit-rate 20MB > "$WORK/first.txt" 2>&1 &
pid=$!
partial_bytes() { find "$PARTIAL" -name '*.part' -size +10000k 2>/dev/null | head -n 1; }
waited=0
until [ -n "$(partial_bytes)" ]; do
    kill -0 "$pid" 2>/dev/null || {
        cat "$WORK/first.txt"
        fail "pull ended before it could be interrupted"
    }
    [ "$waited" -lt 600 ] || fail "no partial download after 60s"
    sleep 0.1
    waited=$((waited + 1))
done
kill -INT "$pid"
status=0
wait "$pid" || status=$?
cat "$WORK/first.txt"
[ "$status" = 130 ] || fail "interrupted pull exited with $status, expected 130"
grep "run the same command again to resume" "$WORK/first.txt" > /dev/null ||
    fail "no resume hint after the interrupt"
in_repo ./alab models | tee "$WORK/models.txt"
grep -E "^$MODEL +incomplete " "$WORK/models.txt" > /dev/null || fail "state is not incomplete"

step "resume"
in_repo ./alab pull "$MODEL" | tee "$WORK/resume.txt"
grep "resuming at" "$WORK/resume.txt" > /dev/null || fail "the download started over"
grep "files verified" "$WORK/resume.txt" > /dev/null || fail "resumed pull did not verify"
in_repo ./alab models | tee "$WORK/models.txt"
grep -E "^$MODEL +downloaded " "$WORK/models.txt" > /dev/null || fail "state is not downloaded"

step "second pull downloads nothing"
in_repo ./alab pull "$MODEL" | tee "$WORK/second.txt"
grep "downloaded 0.0MB" "$WORK/second.txt" > /dev/null || fail "second pull downloaded something"

step "wrong sha256 in the registry"
# Change the hash of the model's config.json, a small file, so the retry is cheap.
good=$(awk -v id="\"$MODEL\"" '
    $1 == "id" { inside = ($3 == id) }
    inside && /name = "config.json"/ { match($0, /[0-9a-f]{64}/); print substr($0, RSTART, 64); exit }
' "$REPO/config/models.toml")
[ -n "$good" ] || fail "could not find config.json of $MODEL in models.toml"
bad=0000000000000000000000000000000000000000000000000000000000000000
sed -i.orig "s/$good/$bad/" "$REPO/config/models.toml"
rm -f "$REPO/config/models.toml.orig"
if in_repo ./alab pull "$MODEL" > "$WORK/tamper.txt" 2>&1; then
    cat "$WORK/tamper.txt"
    fail "pull accepted a wrong sha256"
fi
cat "$WORK/tamper.txt"
grep "config.json: FAILED verification" "$WORK/tamper.txt" > /dev/null ||
    fail "pull did not report the mismatch"
[ ! -e "$REPO/var/models/$MODEL/config.json" ] || fail "the mismatched file was not deleted"
in_repo ./alab models | tee "$WORK/models.txt"
grep -E "^$MODEL +failed verification " "$WORK/models.txt" > /dev/null ||
    fail "state is not failed verification"
git -C "$REPO" checkout --quiet -- config/models.toml
in_repo ./alab pull "$MODEL" > "$WORK/restore.txt" 2>&1 || {
    cat "$WORK/restore.txt"
    fail "pull with the correct registry failed"
}

step "isolation"
[ -z "$(ls -A "$FAKE_HOME")" ] || {
    find "$FAKE_HOME" >&2
    fail "files were written under HOME"
}
unexpected=$(git -C "$REPO" status --porcelain --ignored |
    grep -v -E '^!! (\.tools|\.venv|var)/$' | grep -v '^$' || true)
[ -z "$unexpected" ] || {
    printf '%s\n' "$unexpected" >&2
    fail "files outside .tools/, .venv/ and var/ changed"
}
echo "HOME is empty; new files are only under .tools/, .venv/ and var/"

printf '\nAll T02 acceptance checks passed.\n'
