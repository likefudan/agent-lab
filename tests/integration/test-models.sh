#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly MODELS_SCRIPT="${ROOT}/scripts/models.sh"
readonly SETUP_SCRIPT="${ROOT}/scripts/setup.sh"
readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-model-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

store="${TEMP_ROOT}/store"
manifest_source="${TEMP_ROOT}/manifest.json"
blob_source="${TEMP_ROOT}/blob.bin"
catalog="${TEMP_ROOT}/models.json"
fake_bin="${TEMP_ROOT}/bin"
calls="${TEMP_ROOT}/calls"
mkdir -p "$store" "$fake_bin"
printf '%s\n' '{"schemaVersion":2,"layers":["agent-lab-test"]}' >"$manifest_source"
printf '%s' 'approved-model-blob' >"$blob_source"
manifest_sha="$(shasum -a 256 "$manifest_source" | awk '{print $1}')"
blob_sha="$(shasum -a 256 "$blob_source" | awk '{print $1}')"
blob_bytes="$(wc -c <"$blob_source" | tr -d ' ')"

jq -n \
  --arg manifest "sha256:${manifest_sha}" \
  --arg blob "sha256:${blob_sha}" \
  --argjson blob_bytes "$blob_bytes" \
  '{schema_version: 1, models: [
    {alias:"approved", tag:"testmodel:v1", executable:true,
     manifest_digest:$manifest, artifact_bytes:$blob_bytes,
     blobs:[{digest:$blob,size:$blob_bytes}]},
    {alias:"rejected", tag:"testmodel:bad", executable:false,
     manifest_digest:$manifest, artifact_bytes:$blob_bytes,
     blob_digest_set:{digest:$blob}}
  ]}' >"$catalog"

cat >"${fake_bin}/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CALLS"
[[ ${1:-} == pull ]] || exit 64
if [[ ${FAKE_INTERRUPT_ONCE:-0} == 1 && ! -e ${FAKE_STATE} ]]; then
  : >"$FAKE_STATE"
  exit 75
fi
mkdir -p "$AGENT_LAB_MODEL_STORE/manifests/registry.ollama.ai/library/testmodel"
mkdir -p "$AGENT_LAB_MODEL_STORE/blobs"
cp "$FAKE_MANIFEST_SOURCE" "$AGENT_LAB_MODEL_STORE/manifests/registry.ollama.ai/library/testmodel/v1"
cp "$FAKE_BLOB_SOURCE" "$AGENT_LAB_MODEL_STORE/blobs/sha256-${FAKE_BLOB_SHA}"
EOF
chmod +x "${fake_bin}/ollama"

export AGENT_LAB_MODELS_FILE="$catalog"
export AGENT_LAB_MODEL_STORE="$store"
export AGENT_LAB_AVAILABLE_BYTES=$((4 * 1024 * 1024 * 1024))
export FAKE_CALLS="$calls"
export FAKE_MANIFEST_SOURCE="$manifest_source"
export FAKE_BLOB_SOURCE="$blob_source"
export FAKE_BLOB_SHA="$blob_sha"
export PATH="${fake_bin}:$PATH"

expect_fail() {
  local expected=$1
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly passed: $*"
  fi
  [[ "$output" == *"$expected"* ]] || fail "missing error '$expected' from: $output"
}

list_output="$($MODELS_SCRIPT list)"
[[ "$list_output" == *$'approved\ttestmodel:v1\tmissing'* ]] || fail 'list did not report missing approved model'
[[ "$list_output" != *rejected* ]] || fail 'list exposed rejected alias as executable'
expect_fail 'unknown or non-executable model alias' "$MODELS_SCRIPT" verify rejected
expect_fail 'unavailable model' "$MODELS_SCRIPT" verify approved

: >"$calls"
AGENT_LAB_PROFILE=offline expect_fail 'prohibited by the offline profile' "$MODELS_SCRIPT" pull --yes approved
[[ ! -s "$calls" ]] || fail 'offline pull invoked Ollama'

AGENT_LAB_AVAILABLE_BYTES=1 expect_fail 'insufficient disk space' "$MODELS_SCRIPT" pull --yes approved
[[ ! -s "$calls" ]] || fail 'disk preflight failure invoked Ollama'

expect_fail 'model pull was not confirmed' "$MODELS_SCRIPT" pull approved
[[ ! -s "$calls" ]] || fail 'unconfirmed pull invoked Ollama'

FAKE_INTERRUPT_ONCE=1 FAKE_STATE="${TEMP_ROOT}/interrupted" \
  expect_fail '' "$MODELS_SCRIPT" pull --yes approved
[[ ! -f "$store/manifests/registry.ollama.ai/library/testmodel/v1" ]] || fail 'interrupted fake pull installed a manifest'
FAKE_INTERRUPT_ONCE=1 FAKE_STATE="${TEMP_ROOT}/interrupted" "$MODELS_SCRIPT" pull --yes approved >/dev/null
"$MODELS_SCRIPT" verify approved >/dev/null

call_count_before="$(wc -l <"$calls" | tr -d ' ')"
"$MODELS_SCRIPT" pull --yes approved >/dev/null
call_count_after="$(wc -l <"$calls" | tr -d ' ')"
[[ "$call_count_before" == "$call_count_after" ]] || fail 'already-present model invoked Ollama'

printf '%s' 'tampered' >"$store/manifests/registry.ollama.ai/library/testmodel/v1"
expect_fail 'manifest digest mismatch' "$MODELS_SCRIPT" verify approved
cp "$manifest_source" "$store/manifests/registry.ollama.ai/library/testmodel/v1"
printf '%s' 'wrong' >"$store/blobs/sha256-${blob_sha}"
expect_fail 'model blob size mismatch' "$MODELS_SCRIPT" verify approved
cp "$blob_source" "$store/blobs/sha256-${blob_sha}"

"$MODELS_SCRIPT" verify >/dev/null
setup_output="$($SETUP_SCRIPT)"
[[ "$setup_output" == *'No model was requested'* ]] || fail 'setup validation-only mode failed'

printf '%s\n' 'PASS: approved model setup and verification'
