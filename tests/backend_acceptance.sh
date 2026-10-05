#!/bin/bash
# T04 acceptance checks on a fresh clone of the current commit (HEAD), with the
# tiny CI model (profile ci-tiny):
#
#   1. `alab serve` starts the backend; a second `serve` finds it and starts nothing;
#   2. a chat request (plain and streaming) gets an answer; `status` shows pid,
#      port, RSS and the log;
#   3. `alab stop` ends the process and frees the port;
#   4. a backend killed from outside is reported by `status`, with the log path;
#   5. with a very low Metal memory limit, a long prompt makes the backend stop
#      with a logged error instead of using more memory, and `status` reports it;
#   6. HOME (a new empty directory) is still empty afterwards.
#
# Uncommitted changes are not tested.
set -eu -o pipefail

PROFILE=ci-tiny
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)  # resolved, as alab prints it (/var -> /private/var)
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
    if [ -f "$REPO/var/logs/backend.log" ]; then
        echo "--- end of var/logs/backend.log" >&2
        tail -n 40 "$REPO/var/logs/backend.log" >&2
    fi
    exit 1
}
in_repo() { (cd "$REPO" && env HOME="$FAKE_HOME" "$@"); }
alab() { in_repo ./alab "$@"; }
backend_pid() { "$REPO/.venv/bin/python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$REPO/var/run/backend.json"; }
launch_count() { pgrep -f "agent_lab.backend.launch" | wc -l | tr -d ' '; }
port_listening() { /usr/sbin/lsof -nP -iTCP:8100 -sTCP:LISTEN > /dev/null 2>&1; }
chat() {  # chat <body-file> <output-file>: prints the HTTP status, 000 if the connection failed
    curl -s --noproxy '*' -o "$2" -w '%{http_code}' -H 'Content-Type: application/json' \
        --max-time 300 --data @"$1" http://127.0.0.1:8100/v1/chat/completions || true
}

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "note: uncommitted changes in $ROOT are not part of this check"
fi
[ "$(launch_count)" = 0 ] || fail "a backend is already running on this machine"

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
alab gpu-limit show --profile "$PROFILE" || true

step "serve"
alab serve --profile "$PROFILE" | tee "$WORK/serve.txt" || fail "serve failed"
grep "backend ready after" "$WORK/serve.txt" > /dev/null || fail "serve did not report ready"
pid=$(backend_pid)
kill -0 "$pid" || fail "backend pid $pid is not running"
port_listening || fail "nothing listens on port 8100"

step "serve again"
alab serve --profile "$PROFILE" | tee "$WORK/serve2.txt" || fail "second serve failed"
grep "not starting another" "$WORK/serve2.txt" > /dev/null || fail "second serve did not detect the backend"
[ "$(backend_pid)" = "$pid" ] || fail "the recorded pid changed"
[ "$(launch_count)" = 1 ] || fail "expected one backend process, found $(launch_count)"

step "chat requests"
cat > "$WORK/chat.json" << 'EOF'
{"messages": [{"role": "user", "content": "Say hello in one short sentence."}], "max_tokens": 40}
EOF
code=$(chat "$WORK/chat.json" "$WORK/chat.out")
cat "$WORK/chat.out"
echo
[ "$code" = 200 ] || fail "chat request returned HTTP $code"
"$REPO/.venv/bin/python" -c '
import json, sys
message = json.load(open(sys.argv[1]))["choices"][0]["message"]
assert message["content"].strip(), "empty answer"
assert "<think>" not in message["content"], "thinking content in the answer"
' "$WORK/chat.out" || fail "unexpected chat response"
cat > "$WORK/stream.json" << 'EOF'
{"messages": [{"role": "user", "content": "Count from one to five."}], "max_tokens": 40, "stream": true}
EOF
code=$(chat "$WORK/stream.json" "$WORK/stream.out")
head -n 3 "$WORK/stream.out"
[ "$code" = 200 ] || fail "streaming request returned HTTP $code"
grep -F "data: [DONE]" "$WORK/stream.out" > /dev/null || fail "stream did not end with [DONE]"

step "status"
alab status | tee "$WORK/status.txt" || fail "status exited with $? while running"
grep "backend: running (pid $pid, port 8100" "$WORK/status.txt" > /dev/null || fail "status does not show the pid and port"
grep "RSS: " "$WORK/status.txt" > /dev/null || fail "status does not show RSS"
grep "log: $REPO/var/logs/backend.log" "$WORK/status.txt" > /dev/null || fail "status does not show the log"
if grep -F '"messages"' "$REPO"/var/logs/backend*.log > /dev/null; then fail "a request body was logged"; fi

step "stop"
alab stop | tee "$WORK/stop.txt"
grep "stopped (pid $pid)" "$WORK/stop.txt" > /dev/null || fail "stop did not stop the backend"
if kill -0 "$pid" 2> /dev/null; then fail "pid $pid is still running"; fi
if port_listening; then fail "port 8100 is still in use"; fi
status=0
alab status || status=$?
[ "$status" = 3 ] || fail "status exited with $status after stop, expected 3"

step "unexpected exit"
alab serve --profile "$PROFILE" > /dev/null || fail "serve failed"
pid=$(backend_pid)
kill -9 "$pid"
sleep 1
status=0
alab status > "$WORK/crash.txt" || status=$?
cat "$WORK/crash.txt"
[ "$status" = 1 ] || fail "status exited with $status after a crash, expected 1"
grep "exited unexpectedly (pid $pid" "$WORK/crash.txt" > /dev/null || fail "status does not report the exit"
grep "log: $REPO/var/logs/backend.log" "$WORK/crash.txt" > /dev/null || fail "status does not show the log"
alab stop | grep "had already exited" > /dev/null || fail "stop did not clear the record"

step "memory limit"
# The weights take about 0.35GB; a 600MB limit leaves too little for a long prompt's KV cache.
sed 's/^metal_memory_limit = .*/metal_memory_limit = "600MB"/' \
    "$REPO/config/profiles/ci-tiny.toml" > "$REPO/config/profiles/ci-lowmem.toml"
alab serve --profile ci-lowmem | tee "$WORK/serve-low.txt" || fail "serve with a low limit failed"
pid=$(backend_pid)
"$REPO/.venv/bin/python" -c '
import json
print(json.dumps({"messages": [{"role": "user", "content": "hello " * 8000}], "max_tokens": 10}))
' > "$WORK/long.json"
code=$(chat "$WORK/long.json" "$WORK/long.out")
echo "long prompt: HTTP $code"
[ "$code" != 200 ] || fail "a long prompt over the memory limit succeeded"
waited=0
until ! kill -0 "$pid" 2> /dev/null; do
    [ "$waited" -lt 30 ] || fail "the backend did not stop after exceeding the memory limit"
    sleep 1
    waited=$((waited + 1))
done
status=0
alab status > "$WORK/lowmem.txt" || status=$?
cat "$WORK/lowmem.txt"
[ "$status" = 1 ] || fail "status exited with $status, expected 1"
grep "Metal memory limit exceeded" "$WORK/lowmem.txt" > /dev/null || fail "status does not show why the backend stopped"
alab stop > /dev/null

step "isolation"
[ -z "$(ls -A "$FAKE_HOME")" ] || {
    find "$FAKE_HOME" >&2
    fail "files were written under HOME"
}
echo "HOME is empty"

printf '\nAll T04 acceptance checks passed.\n'
