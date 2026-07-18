#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
readonly STATUS="$ROOT/scripts/status.sh"
readonly HEALTH="$ROOT/scripts/health.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fixture=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-diagnostics.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/bin" "$fixture/profiles" \
  "$fixture/models/manifests/registry.ollama.ai/library/test-model"

printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "ollama version 1.2.3"' >"$fixture/ollama"
chmod +x "$fixture/ollama"
ollama_sha=$(shasum -a 256 "$fixture/ollama" | awk '{print $1}')

printf '%s\n' '{"schema":2,"layers":[]}' >"$fixture/models/manifests/registry.ollama.ai/library/test-model/latest"
manifest_sha="sha256:$(shasum -a 256 "$fixture/models/manifests/registry.ollama.ai/library/test-model/latest" | awk '{print $1}')"

jq -n --arg ollama_sha "$ollama_sha" '
  {components:[
    {id:"ollama",version:"1.2.3",artifact:{executable_sha256:$ollama_sha}},
    {id:"open-webui",version:"9.8.7",artifact:{index_digest:"sha256:webui-pinned"}}
  ]}
' >"$fixture/components.json"
jq -n --arg manifest_sha "$manifest_sha" '
  {rag:{embedding:{revision:"fixture-revision"},reranking:{enabled:false}},models:[
    {alias:"test",tag:"test-model:latest",executable:true,manifest_digest:$manifest_sha}
  ]}
' >"$fixture/models.json"
printf '%s\n' \
  'AGENT_LAB_PROFILE=online-manual' \
  'AGENT_LAB_ALLOW_MODEL_PULLS=true' \
  'AGENT_LAB_ALLOW_REMOTE_TOOLS=false' \
  'AGENT_LAB_SEARCH_MODE=manual' \
  'OFFLINE_MODE=false' \
  'ENABLE_VERSION_UPDATE_CHECK=false' \
  'ENABLE_WEB_SEARCH=true' \
  'WEB_SEARCH_ENGINE=duckduckgo' \
  'RAG_EMBEDDING_MODEL_AUTO_UPDATE=false' \
  'RAG_RERANKING_MODEL_AUTO_UPDATE=false' \
  'SCARF_NO_ANALYTICS=true' \
  'DO_NOT_TRACK=true' \
  'ANONYMIZED_TELEMETRY=false' >"$fixture/profiles/online-manual.env"
printf '%s\n' 'WEBUI_SECRET_KEY=this-must-never-appear' >"$fixture/.env"

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=${!#}
case ${FIXTURE_CASE:-healthy} in
  stopped) exit 22 ;;
  partial)
    [[ "$url" == *11434* ]] || exit 22
    ;;
esac
case $url in
  */api/version)
    case ${FIXTURE_CASE:-healthy} in
      version-drift) printf '%s\n' '{"version":"9.9.9"}' ;;
      malformed) printf '%s\n' '{not-json' ;;
      *) printf '%s\n' '{"version":"1.2.3"}' ;;
    esac
    ;;
  */api/ps) printf '%s\n' '{"models":[{"name":"test-model:latest"}]}' ;;
  */health) printf '%s\n' 'healthy' ;;
  *) exit 22 ;;
esac
EOF

cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  info) exit 0 ;;
  volume)
    [[ ${FIXTURE_CASE:-healthy} != partial ]]
    ;;
  inspect)
    digest='sha256:webui-pinned'
    [[ ${FIXTURE_CASE:-healthy} != digest-drift ]] || digest='sha256:unexpected'
    printf '[{"State":{"Status":"running"},"Config":{"Image":"ghcr.io/open-webui/open-webui@%s"}}]\n' "$digest"
    ;;
  exec)
    [[ ${FIXTURE_CASE:-healthy} != partial ]]
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$fixture/bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
if [[ ${FIXTURE_CASE:-healthy} == low-disk ]]; then
  printf '%s\n' '/dev/test 100 99 1 99% /fixture'
else
  printf '%s\n' '/dev/test 99999999 1 99999998 1% /fixture'
fi
EOF
chmod +x "$fixture/bin/curl" "$fixture/bin/docker" "$fixture/bin/df"

run_health() {
  local test_case=$1
  shift
  env PATH="$fixture/bin:$PATH" FIXTURE_CASE="$test_case" \
    AGENT_LAB_COMPONENTS_FILE="$fixture/components.json" \
    AGENT_LAB_MODELS_FILE="$fixture/models.json" \
    AGENT_LAB_PROFILE_DIR="$fixture/profiles" \
    AGENT_LAB_ENV_FILE="$fixture/.env" \
    AGENT_LAB_MODEL_STORE="$fixture/models" \
    AGENT_LAB_OLLAMA_BIN="$fixture/ollama" \
    AGENT_LAB_DISK_PATH="$fixture" \
    AGENT_LAB_MIN_FREE_BYTES=10240 \
    "$@" "$HEALTH" --json
}

healthy=$(run_health healthy env) || fail 'healthy fixture failed'
jq -e '.healthy == true and .ollama.active_models == ["test-model:latest"] and .optional_features.web_search_mode == "manual"' <<<"$healthy" >/dev/null ||
  fail 'healthy JSON is incomplete'
grep -q 'this-must-never-appear' <<<"$healthy" && fail 'JSON leaked an environment secret'

for test_case in stopped partial version-drift digest-drift low-disk malformed; do
  output="$fixture/$test_case.json"
  if run_health "$test_case" env >"$output"; then
    fail "$test_case fixture unexpectedly passed"
  fi
  jq -e '.healthy == false' "$output" >/dev/null || fail "$test_case did not emit valid unhealthy JSON"
done
jq -e '.ollama.action | length > 10' "$fixture/stopped.json" >/dev/null || fail 'stopped service lacks corrective action'
jq -e '.open_webui.reachable == false and .volume.exists == false' "$fixture/partial.json" >/dev/null || fail 'partial state was not diagnosed'
jq -e '.ollama.version_matches == false and (.ollama.action | test("reinstall pinned Ollama"))' "$fixture/version-drift.json" >/dev/null || fail 'version drift was not diagnosed'
jq -e '.open_webui.digest_matches == false and (.open_webui.action | test("pinned"))' "$fixture/digest-drift.json" >/dev/null || fail 'digest drift was not diagnosed'
jq -e '.disk.ok == false and (.disk.action | test("free at least"))' "$fixture/low-disk.json" >/dev/null || fail 'low disk was not diagnosed'
jq -e '.ollama.response_valid == false and (.ollama.action | test("malformed JSON"))' "$fixture/malformed.json" >/dev/null || fail 'malformed response was not diagnosed'

invalid="$fixture/invalid-profile.json"
if run_health healthy env AGENT_LAB_PROFILE=not-a-profile >"$invalid"; then
  fail 'invalid profile unexpectedly passed'
fi
jq -e '.profile.valid == false and (.profile.action | test("select offline"))' "$invalid" >/dev/null ||
  fail 'invalid profile was not diagnosed'

printf '%s\n' '{"schema":2,"layers":["drift"]}' >"$fixture/models/manifests/registry.ollama.ai/library/test-model/latest"
drift="$fixture/model-drift.json"
if run_health healthy env >"$drift"; then
  fail 'model digest drift unexpectedly passed'
fi
jq -e '.models[0].state == "digest-mismatch" and (.models[0].action | test("remove the drifted"))' "$drift" >/dev/null ||
  fail 'model/catalog digest drift was not diagnosed'

human=$(env PATH="$fixture/bin:$PATH" FIXTURE_CASE=healthy \
  AGENT_LAB_COMPONENTS_FILE="$fixture/components.json" AGENT_LAB_MODELS_FILE="$fixture/models.json" \
  AGENT_LAB_PROFILE_DIR="$fixture/profiles" AGENT_LAB_ENV_FILE="$fixture/.env" \
  AGENT_LAB_MODEL_STORE="$fixture/models" AGENT_LAB_OLLAMA_BIN="$fixture/ollama" \
  AGENT_LAB_DISK_PATH="$fixture" AGENT_LAB_MIN_FREE_BYTES=10240 "$STATUS")
grep -q '^PROFILE' <<<"$human" || fail 'human status format lacks PROFILE row'
grep -q '^OVERALL' <<<"$human" || fail 'human status format lacks OVERALL row'

printf '%s\n' 'PASS: read-only status and health diagnostics fixtures'
