#!/bin/bash
# T05 acceptance checks on a fresh clone of the current commit (HEAD), with the
# tiny CI model (profile ci-tiny):
#
#   1. `alab serve` refuses to start without an API key;
#   2. with a key, it starts the backend, then the gateway; `status` shows both
#      and the queue;
#   3. the official openai SDK gets answers through the gateway: plain,
#      streaming, with tools, with a tool result and with reasoning_effort;
#   4. the gateway's prompt token count equals the backend's for every request;
#   5. a request over max_context is refused and never reaches the backend;
#   6. no request body is logged; `alab stop` stops both; HOME stays empty.
#
# Uncommitted changes are not tested.
set -eu -o pipefail

PROFILE=ci-tiny
MODEL=qwen3-0.6b
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
    for log in gateway.log backend.log gateway.console.log; do
        if [ -f "$REPO/var/logs/$log" ]; then
            echo "--- end of var/logs/$log" >&2
            tail -n 40 "$REPO/var/logs/$log" >&2
        fi
    done
    exit 1
}
in_repo() { (cd "$REPO" && env HOME="$FAKE_HOME" "$@"); }
alab() { in_repo ./alab "$@"; }
backend_posts() { grep -c 'POST /v1/chat/completions' "$REPO/var/logs/backend.log" || true; }

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

step "serve without a key"
status=0
alab serve --profile "$PROFILE" > "$WORK/nokey.txt" 2>&1 || status=$?
cat "$WORK/nokey.txt"
[ "$status" = 1 ] || fail "serve without a key exited with $status, expected 1"
grep "no API key exists yet" "$WORK/nokey.txt" > /dev/null || fail "serve did not explain the missing key"
if pgrep -f agent_lab.backend.launch > /dev/null; then fail "a backend was started without a key"; fi

step "keys and serve"
alab keys create ci > "$WORK/key.txt"
KEY=$(grep -o 'sk-alab-[A-Za-z0-9_-]*' "$WORK/key.txt")
[ -n "$KEY" ] || fail "keys create printed no key"
alab keys list | grep '^ci ' > /dev/null || fail "keys list does not show the key"
if grep -F "$KEY" "$REPO/var/secrets/keys.toml" > /dev/null; then fail "the key itself is stored"; fi
alab serve --profile "$PROFILE" | tee "$WORK/serve.txt" || fail "serve failed"
grep "backend ready after" "$WORK/serve.txt" > /dev/null || fail "serve did not start the backend"
grep "gateway ready after" "$WORK/serve.txt" > /dev/null || fail "serve did not start the gateway"
alab status | tee "$WORK/status.txt" || fail "status exited with $? while both run"
grep "gateway: running" "$WORK/status.txt" > /dev/null || fail "status does not show the gateway"
grep "queue: 0 running, 0 waiting" "$WORK/status.txt" > /dev/null || fail "status does not show the queue"
code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/healthz || true)
[ "$code" = 200 ] || fail "/healthz returned $code"

step "requests with the openai SDK"
"$REPO/.venv/bin/python" "$REPO/tests/gateway_client_check.py" --api-key "$KEY" --model "$MODEL" \
    --max-context 8192 > "$WORK/client.txt" 2>&1 || {
    cat "$WORK/client.txt"
    fail "SDK requests failed"
}
cat "$WORK/client.txt"

step "token counts and the limit"
grep 'agent_lab.gateway.requests' "$REPO/var/logs/gateway.log"
if grep "prompt token count mismatch" "$REPO/var/logs/gateway.log"; then
    fail "the gateway counted prompt tokens differently from the backend"
fi
matched=$(grep 'status=200' "$REPO/var/logs/gateway.log" | grep -cE ' prompt_tokens=([0-9]+) backend_prompt_tokens=\1 ' || true)
[ "$matched" -ge 6 ] || fail "expected at least 6 requests with matching token counts, found $matched"
grep -E 'status=400 .*prompt_tokens=[0-9]{4,} backend_prompt_tokens=- ' "$REPO/var/logs/gateway.log" > /dev/null \
    || fail "the oversized request is not logged as refused"
posts=$(backend_posts)
"$REPO/.venv/bin/python" -c '
import json
print(json.dumps({"messages": [{"role": "user", "content": "hello " * 9000}], "max_tokens": 10}))
' > "$WORK/long.json"
code=$(curl -s --noproxy '*' -o "$WORK/long.out" -w '%{http_code}' -H "Authorization: Bearer $KEY" \
    -H 'Content-Type: application/json' --data @"$WORK/long.json" http://127.0.0.1:8000/v1/chat/completions || true)
cat "$WORK/long.out"
echo
[ "$code" = 400 ] || fail "an oversized request returned HTTP $code"
grep context_length_exceeded "$WORK/long.out" > /dev/null || fail "no context_length_exceeded error"
sleep 1
[ "$(backend_posts)" = "$posts" ] || fail "the oversized request reached the backend"
code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --data @"$WORK/long.json" http://127.0.0.1:8000/v1/chat/completions || true)
[ "$code" = 401 ] || fail "a request without a key returned HTTP $code"

step "no bodies in the logs"
if grep -E 'hello hello|Paris|agentlab' "$REPO"/var/logs/gateway*.log; then fail "a request body was logged"; fi

step "stop"
alab stop | tee "$WORK/stop.txt"
grep "gateway: stopped" "$WORK/stop.txt" > /dev/null || fail "stop did not stop the gateway"
grep "backend: stopped" "$WORK/stop.txt" > /dev/null || fail "stop did not stop the backend"
status=0
alab status > /dev/null || status=$?
[ "$status" = 3 ] || fail "status exited with $status after stop, expected 3"
if pgrep -f 'agent_lab.gateway' > /dev/null; then fail "a gateway process is still running"; fi

step "isolation"
[ -z "$(ls -A "$FAKE_HOME")" ] || {
    find "$FAKE_HOME" >&2
    fail "files were written under HOME"
}
echo "HOME is empty"

printf '\nAll T05 acceptance checks passed.\n'
