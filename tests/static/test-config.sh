#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly VALIDATOR="${REPO_ROOT}/scripts/validate-config.sh"
readonly COMPONENTS="${REPO_ROOT}/config/components.json"
readonly MODELS="${REPO_ROOT}/config/models.json"
readonly FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-config-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

expect_pass() {
  local name="$1"
  local components="$2"
  local models="$3"
  local output

  if ! output="$(bash "$VALIDATOR" "$components" "$models" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "$name should pass"
  fi
  [[ "$output" == *"Configuration catalogs are valid."* ]] || fail "$name did not print success"
  pass "$name"
}

expect_fail() {
  local name="$1"
  local expected="$2"
  local components="$3"
  local models="$4"
  local output

  if output="$(bash "$VALIDATOR" "$components" "$models" 2>&1)"; then
    fail "$name should fail"
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf '%s\n' "$output" >&2
    fail "$name did not report actionable message containing: $expected"
  }
  pass "$name"
}

make_component_fixture() {
  local name="$1"
  local filter="$2"
  jq "$filter" "$COMPONENTS" >"${FIXTURE_DIR}/${name}.components.json"
  printf '%s\n' "${FIXTURE_DIR}/${name}.components.json"
}

make_model_fixture() {
  local name="$1"
  local filter="$2"
  jq "$filter" "$MODELS" >"${FIXTURE_DIR}/${name}.models.json"
  printf '%s\n' "${FIXTURE_DIR}/${name}.models.json"
}

expect_pass "checked-in catalogs" "$COMPONENTS" "$MODELS"

printf '{not json\n' >"${FIXTURE_DIR}/syntax.components.json"
expect_fail "invalid JSON syntax" "components: invalid JSON syntax" \
  "${FIXTURE_DIR}/syntax.components.json" "$MODELS"

fixture="$(make_component_fixture missing-field 'del(.components[0].license)')"
expect_fail "missing required component field" "components.components[0].license" "$fixture" "$MODELS"

fixture="$(make_component_fixture invalid-type '.components[0].type = "custom_gateway"')"
expect_fail "unsupported component type" "components.components[0].type: unsupported" "$fixture" "$MODELS"

fixture="$(make_component_fixture invalid-entry '.components[0] = 42')"
expect_fail "invalid component entry shape" "components.components[0]: expected an object" "$fixture" "$MODELS"

fixture="$(make_component_fixture duplicate-id '.components += [.components[0]]')"
expect_fail "duplicate component identifier" "duplicate id" "$fixture" "$MODELS"

fixture="$(make_component_fixture floating-image '.components[1].artifact.reference = "ghcr.io/open-webui/open-webui:latest"')"
expect_fail "floating OCI image tag" "artifact.reference: OCI images must use an immutable" "$fixture" "$MODELS"

fixture="$(make_component_fixture missing-revision 'del(.components[0].source.revision)')"
expect_fail "missing component revision" "source.revision: expected an immutable" "$fixture" "$MODELS"

fixture="$(make_component_fixture remote-endpoint '.components[0].endpoints.openai_api = "https://api.example.com/v1"')"
expect_fail "remote API endpoint" "endpoints.openai_api: MVP endpoint must be local" "$fixture" "$MODELS"

fixture="$(make_component_fixture remote-default '.components[1].required_environment.OLLAMA_BASE_URL = "https://api.example.com/v1"')"
expect_fail "remote API endpoint default" "required_environment.OLLAMA_BASE_URL: MVP endpoint default must be local" "$fixture" "$MODELS"

fixture="$(make_component_fixture missing-artifact-digest 'del(.components[0].artifact.sha256)')"
expect_fail "missing native artifact digest" "artifact.sha256: expected 64 lowercase hex" "$fixture" "$MODELS"

fixture="$(make_component_fixture committed-secret '.components[1].required_environment.WEBUI_SECRET_KEY = "actual-production-secret-value"')"
expect_fail "committed secret" "catalog contains a secret-like value" "$fixture" "$MODELS"

fixture="$(make_model_fixture duplicate-alias '.models[1].alias = .models[0].alias')"
expect_fail "duplicate model alias" "duplicate alias" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture missing-digest 'del(.models[3].manifest_digest)')"
expect_fail "missing model digest" "models.models[3].manifest_digest" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture missing-embedding-revision 'del(.rag.embedding.revision)')"
expect_fail "missing Hugging Face revision" "models.rag.embedding.revision" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture missing-cache '.rag.embedding.cache_path = ""')"
expect_fail "missing embedding cache location" "models.rag.embedding.cache_path" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture missing-license 'del(.models[4].license)')"
expect_fail "missing model license" "models.models[4].license" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture missing-capability 'del(.models[4].capabilities.tools)')"
expect_fail "missing executable capability" "executable models require boolean text, code, tools, and vision" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture floating-model '.models[3].tag = "qwen3.5:latest"')"
expect_fail "floating model tag" "models.models[3].tag: expected an exact non-floating" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture invalid-default '.defaults.chat = "qwen-4b-mlx-rejected"')"
expect_fail "non-executable default alias" "models.defaults.chat" "$COMPONENTS" "$fixture"

fixture="$(make_model_fixture incapable-default '.defaults.vision = "qwen-9b"')"
expect_fail "incapable default alias" "lacks required vision capability" "$COMPONENTS" "$fixture"

fixture="$(make_component_fixture all-errors '.components += [.components[0]] | .components[0].endpoints.native_api = "https://remote.example/api"')"
output=""
if output="$(bash "$VALIDATOR" "$fixture" "$MODELS" 2>&1)"; then
  fail "all-errors fixture should fail"
fi
[[ "$output" == *"duplicate id"* ]] || fail "validator did not print duplicate-id error"
[[ "$output" == *"endpoints.native_api: MVP endpoint must be local"* ]] || fail "validator did not print remote-endpoint error"
pass "validator prints all semantic errors"

printf '1..%d\n' "$pass_count"
