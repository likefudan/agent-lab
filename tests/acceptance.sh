#!/bin/sh
# T01 acceptance checks on a fresh clone of the current commit (HEAD).
#
#   1. bootstrap + doctor with HOME pointing at a new empty directory (and a
#      UV_PROJECT_ENVIRONMENT inside it), which must still be empty afterwards;
#   2. every new file is under .tools/, .venv/ or var/;
#   3. a second bootstrap downloads nothing and is faster;
#   4. a tampered sha256 in config/tools.toml makes bootstrap fail;
#   5. deleting .tools/, .venv/ and var/ restores the fresh-clone state.
#
# Uncommitted changes are not tested. doctor must pass on Apple Silicon; on
# other platforms its machine checks are expected to fail and only the
# toolchain checks are asserted.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
FAKE_HOME="$WORK/home"
mkdir "$FAKE_HOME"

step() { printf '\n### %s\n' "$*"; }
fail() { printf 'ACCEPTANCE FAILED: %s\n' "$*" >&2; exit 1; }
now() { date +%s; }

home_is_empty() {
    [ -z "$(ls -A "$FAKE_HOME")" ] || {
        find "$FAKE_HOME" >&2
        fail "files were written under HOME"
    }
}

only_ignored_runtime_dirs() {
    status=$(git -C "$REPO" status --porcelain --ignored)
    unexpected=$(printf '%s\n' "$status" | grep -v -E '^!! (\.tools|\.venv|var)/$' | grep -v '^$' || true)
    [ -z "$unexpected" ] || {
        printf '%s\n' "$unexpected" >&2
        fail "files outside .tools/, .venv/ and var/ changed"
    }
}

# A user-level uv setting that would install outside the project if bootstrap honoured it.
in_repo() { (cd "$REPO" && env HOME="$FAKE_HOME" UV_PROJECT_ENVIRONMENT="$FAKE_HOME/venv" "$@"); }

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "note: uncommitted changes in $ROOT are not part of this check"
fi

step "fresh clone of $(git -C "$ROOT" rev-parse --short HEAD)"
git clone --quiet --no-checkout "$ROOT" "$REPO"
git -C "$REPO" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)"

step "first bootstrap (HOME=$FAKE_HOME)"
start=$(now)
in_repo ./bootstrap.sh
first=$(($(now) - start))

step "doctor"
if in_repo ./alab doctor > "$WORK/doctor.txt"; then doctor_ok=1; else doctor_ok=0; fi
cat "$WORK/doctor.txt"
if [ "$(uname -s)/$(uname -m)" = "Darwin/arm64" ]; then
    [ "$doctor_ok" = 1 ] || fail "doctor failed on Apple Silicon"
fi
for name in python uv cloudflared secrets profile; do
    grep -E "^  ok +$name " "$WORK/doctor.txt" > /dev/null || fail "doctor check $name did not pass"
done

step "isolation"
home_is_empty
only_ignored_runtime_dirs
echo "HOME is empty; new files are only under .tools/, .venv/ and var/"

step "second bootstrap"
start=$(now)
in_repo ./bootstrap.sh > "$WORK/second.txt" 2>&1
second=$(($(now) - start))
cat "$WORK/second.txt"
grep "uv .* already installed" "$WORK/second.txt" > /dev/null || fail "uv was installed again"
grep "cloudflared .* already installed" "$WORK/second.txt" > /dev/null ||
    fail "cloudflared was installed again"
if grep -i -E "downloading|downloaded" "$WORK/second.txt"; then
    fail "second bootstrap downloaded something"
fi
echo "first run ${first}s, second run ${second}s"
[ "$second" -le "$first" ] || fail "second bootstrap was not faster"

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) platform=darwin-arm64 ;;
    *) platform=linux-x86_64 ;;
esac
for tool in uv cloudflared; do
    step "tampered sha256 for $tool"
    good=$(awk -v want="[$tool.$platform]" '
        $0 == want { inside = 1; next }
        /^\[/ { inside = 0 }
        inside && $1 == "sha256" { gsub(/"/, "", $3); print $3; exit }
    ' "$REPO/config/tools.toml")
    [ -n "$good" ] || fail "could not find the $tool sha256 in tools.toml"
    bad=0000000000000000000000000000000000000000000000000000000000000000
    sed -i.orig "s/$good/$bad/" "$REPO/config/tools.toml"
    rm -f "$REPO/config/tools.toml.orig"
    if in_repo ./bootstrap.sh > "$WORK/tamper.txt" 2>&1; then
        cat "$WORK/tamper.txt"
        fail "bootstrap accepted a wrong sha256 for $tool"
    fi
    cat "$WORK/tamper.txt"
    grep "checksum mismatch for $tool" "$WORK/tamper.txt" > /dev/null ||
        fail "bootstrap did not explain the $tool checksum mismatch"
    git -C "$REPO" checkout --quiet -- config/tools.toml
done
home_is_empty
only_ignored_runtime_dirs

step "clean up"
rm -rf "$REPO/.tools" "$REPO/.venv" "$REPO/var"
[ -z "$(git -C "$REPO" status --porcelain --ignored)" ] ||
    fail "deleting .tools/, .venv/ and var/ did not restore the fresh clone"
home_is_empty

printf '\nAll T01 acceptance checks passed.\n'
