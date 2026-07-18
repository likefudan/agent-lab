#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

readonly ROOT="$(repository_root "$SCRIPT_DIR")"
readonly COMPONENTS_FILE="${AGENT_LAB_COMPONENTS_FILE:-$ROOT/config/components.json}"
readonly MODELS_FILE="${AGENT_LAB_MODELS_FILE:-$ROOT/config/models.json}"
readonly PROFILE_DIR="${AGENT_LAB_PROFILE_DIR:-$ROOT/config/profiles}"
readonly ENV_FILE="${AGENT_LAB_ENV_FILE:-$ROOT/.env}"
readonly MODEL_STORE="${AGENT_LAB_MODEL_STORE:-${OLLAMA_MODELS:-$HOME/.ollama/models}}"
readonly OLLAMA_BIN="${AGENT_LAB_OLLAMA_BIN:-/opt/homebrew/opt/ollama/bin/ollama}"
readonly OLLAMA_URL="${AGENT_LAB_OLLAMA_URL:-http://127.0.0.1:11434}"
readonly WEBUI_URL="${AGENT_LAB_WEBUI_URL:-http://127.0.0.1:3000}"
readonly VOLUME="${AGENT_LAB_WEBUI_VOLUME:-agent-lab-open-webui-data}"
readonly CONTAINER="${AGENT_LAB_WEBUI_CONTAINER:-agent-lab-open-webui-1}"
readonly DISK_PATH="${AGENT_LAB_DISK_PATH:-$ROOT}"
readonly MIN_FREE_BYTES="${AGENT_LAB_MIN_FREE_BYTES:-10737418240}"

usage() {
  cat <<'EOF'
Usage: agent-lab status [--json]

Inspect the local stack without starting services, loading models, pulling
artifacts, or changing configuration. --json emits one machine-readable object.
EOF
}

json=false
case $# in
  0) ;;
  1)
    case $1 in
      --json) json=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  *) usage >&2; exit 64 ;;
esac

require_command jq
require_command shasum

[[ -r "$COMPONENTS_FILE" ]] || die "component catalog is not readable: $COMPONENTS_FILE"
[[ -r "$MODELS_FILE" ]] || die "model catalog is not readable: $MODELS_FILE"
jq -e '.components | type == "array"' "$COMPONENTS_FILE" >/dev/null 2>&1 ||
  die "component catalog is malformed: run 'agent-lab validate'"
jq -e '.models | type == "array"' "$MODELS_FILE" >/dev/null 2>&1 ||
  die "model catalog is malformed: run 'agent-lab validate'"
[[ "$MIN_FREE_BYTES" =~ ^[0-9]+$ ]] || die 'AGENT_LAB_MIN_FREE_BYTES must be an integer'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-status.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT HUP INT TERM

expected_ollama_version=$(jq -r '.components[] | select(.id == "ollama") | .version' "$COMPONENTS_FILE")
expected_ollama_sha=$(jq -r '.components[] | select(.id == "ollama") | .artifact.executable_sha256' "$COMPONENTS_FILE")
expected_webui_version=$(jq -r '.components[] | select(.id == "open-webui") | .version' "$COMPONENTS_FILE")
expected_webui_digest=$(jq -r '.components[] | select(.id == "open-webui") | .artifact.index_digest' "$COMPONENTS_FILE")
expected_embedding_revision=$(jq -r '.rag.embedding.revision' "$MODELS_FILE")

profile=${AGENT_LAB_PROFILE:-$(agent_lab_active_profile 2>/dev/null || printf '%s' invalid-state)}
profile_path="$PROFILE_DIR/$profile.env"
profile_valid=false
profile_action='none'
case $profile in
  offline|online-manual|online-automatic)
    if agent_lab_validate_profile_file "$profile_path" "$profile" >/dev/null 2>&1; then
      profile_valid=true
    else
      profile_action="restore a validated $profile_path, then select the profile again"
    fi
    ;;
  *) profile_action="select offline, online-manual, or online-automatic with AGENT_LAB_PROFILE" ;;
esac

ollama_reachable=false
ollama_response_valid=false
ollama_version=''
active_models='[]'
ollama_action="run 'agent-lab start' and inspect the Ollama log if it does not recover"
if curl --silent --fail --max-time 3 "$OLLAMA_URL/api/version" >"$tmp_dir/ollama-version.json" 2>/dev/null; then
  if ollama_version=$(jq -er '.version | strings | select(length > 0)' "$tmp_dir/ollama-version.json" 2>/dev/null); then
    ollama_reachable=true
    ollama_response_valid=true
  else
    ollama_action='restart the managed Ollama service; its version API returned malformed JSON'
  fi
fi

if [[ "$ollama_reachable" == true ]]; then
  if curl --silent --fail --max-time 3 "$OLLAMA_URL/api/ps" >"$tmp_dir/ollama-ps.json" 2>/dev/null &&
    jq -e '.models | type == "array" and all(.[]; .name | type == "string")' "$tmp_dir/ollama-ps.json" >/dev/null 2>&1; then
    active_models=$(jq -c '[.models[].name]' "$tmp_dir/ollama-ps.json")
  else
    ollama_response_valid=false
    ollama_action='restart the managed Ollama service; its process API returned malformed JSON'
  fi
fi
ollama_version_matches=false
[[ "$ollama_version" == "$expected_ollama_version" ]] && ollama_version_matches=true
if [[ "$ollama_reachable" == true && "$ollama_version_matches" != true ]]; then
  ollama_action="reinstall pinned Ollama $expected_ollama_version and restart Agent Lab"
fi

ollama_binary_matches=false
ollama_binary_sha=''
if [[ -x "$OLLAMA_BIN" ]]; then
  ollama_binary_sha=$(shasum -a 256 "$OLLAMA_BIN" | awk '{print $1}')
  [[ "$ollama_binary_sha" == "$expected_ollama_sha" ]] && ollama_binary_matches=true
fi
ollama_binary_action="reinstall pinned Ollama $expected_ollama_version at $OLLAMA_BIN"

docker_available=false
container_state='unavailable'
webui_reachable=false
webui_response_valid=false
webui_image_reference=''
webui_digest_matches=false
volume_exists=false
cache_ready=false
webui_action="start Docker Desktop, then run 'agent-lab start'"
volume_action="run 'agent-lab setup' to create $VOLUME"
cache_action="start Open WebUI online once and run the RAG setup to cache revision $expected_embedding_revision"
if command_exists docker && docker info >/dev/null 2>&1; then
  docker_available=true
  if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    volume_exists=true
  fi
  if docker inspect "$CONTAINER" >"$tmp_dir/container.json" 2>/dev/null; then
    container_state=$(jq -r '.[0].State.Status // "unknown"' "$tmp_dir/container.json")
    webui_image_reference=$(jq -r '.[0].Config.Image // ""' "$tmp_dir/container.json")
    [[ "$webui_image_reference" == *"@$expected_webui_digest" ]] && webui_digest_matches=true
    if docker exec "$CONTAINER" test -f "/app/backend/data/cache/embedding/models/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/$expected_embedding_revision/modules.json" >/dev/null 2>&1; then
      cache_ready=true
    fi
  else
    container_state='stopped-or-missing'
  fi
  if curl --silent --fail --max-time 5 "$WEBUI_URL/health" >"$tmp_dir/webui-health" 2>/dev/null; then
    webui_reachable=true
    if [[ -s "$tmp_dir/webui-health" ]]; then
      webui_response_valid=true
    else
      webui_action='restart Open WebUI; its health endpoint returned an empty response'
    fi
  fi
  if [[ "$webui_reachable" == true && "$webui_digest_matches" != true ]]; then
    webui_action="recreate Open WebUI from the pinned $expected_webui_version image digest"
  fi
fi

models='[]'
while IFS= read -r model; do
  alias=$(jq -r '.alias' <<<"$model")
  tag=$(jq -r '.tag' <<<"$model")
  expected=$(jq -r '.manifest_digest' <<<"$model")
  name=${tag%%:*}
  tag_name=${tag#*:}
  manifest="$MODEL_STORE/manifests/registry.ollama.ai/library/$name/$tag_name"
  state=missing
  actual=''
  action="run 'agent-lab models pull $alias' while online"
  if [[ -f "$manifest" ]]; then
    actual="sha256:$(shasum -a 256 "$manifest" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      state=verified
      action=none
    else
      state=digest-mismatch
      action="remove the drifted $tag artifact manually, then run 'agent-lab models pull $alias' while online"
    fi
  fi
  entry=$(jq -cn --arg alias "$alias" --arg tag "$tag" --arg state "$state" \
    --arg expected_digest "$expected" --arg actual_digest "$actual" --arg action "$action" \
    '{alias:$alias,tag:$tag,state:$state,expected_digest:$expected_digest,actual_digest:$actual_digest,action:$action}')
  models=$(jq -cn --argjson current "$models" --argjson entry "$entry" '$current + [$entry]')
done < <(jq -c '.models[] | select(.executable == true)' "$MODELS_FILE")

free_bytes=$(df -Pk "$DISK_PATH" 2>/dev/null | awk 'NR == 2 {printf "%.0f", $4 * 1024}')
[[ "$free_bytes" =~ ^[0-9]+$ ]] || free_bytes=0
disk_ok=false
(( free_bytes >= MIN_FREE_BYTES )) && disk_ok=true
disk_action="free at least $MIN_FREE_BYTES bytes on the filesystem containing $DISK_PATH"

environment_exists=false
[[ -r "$ENV_FILE" ]] && environment_exists=true
environment_action="run 'agent-lab setup' to create the private environment"

search_enabled=false
search_mode=disabled
if [[ "$profile_valid" == true ]]; then
  search_mode=$(awk -F= '$1 == "AGENT_LAB_SEARCH_MODE" {print $2; exit}' "$profile_path")
  [[ $(awk -F= '$1 == "ENABLE_WEB_SEARCH" {print $2; exit}' "$profile_path") == true ]] && search_enabled=true
fi
reranker_enabled=$(jq -r '.rag.reranking.enabled' "$MODELS_FILE")

healthy=$(jq -nr \
  --argjson profile "$profile_valid" --argjson ollama "$ollama_reachable" \
  --argjson response "$ollama_response_valid" --argjson version "$ollama_version_matches" \
  --argjson binary "$ollama_binary_matches" --argjson webui "$webui_reachable" \
  --argjson webresponse "$webui_response_valid" --argjson digest "$webui_digest_matches" \
  --argjson volume "$volume_exists" --argjson cache "$cache_ready" --argjson disk "$disk_ok" \
  --argjson environment "$environment_exists" --argjson models "$models" \
  '$profile and $ollama and $response and $version and $binary and $webui and $webresponse and $digest and $volume and $cache and $disk and $environment and all($models[]; .state == "verified")')

report=$(jq -cn \
  --argjson healthy "$healthy" \
  --arg profile "$profile" --arg profile_path "$profile_path" --argjson profile_valid "$profile_valid" --arg profile_action "$profile_action" \
  --arg ollama_endpoint "$OLLAMA_URL" --argjson ollama_reachable "$ollama_reachable" --argjson ollama_response_valid "$ollama_response_valid" --arg ollama_version "$ollama_version" --arg expected_ollama_version "$expected_ollama_version" --argjson ollama_version_matches "$ollama_version_matches" --arg ollama_action "$ollama_action" --argjson active_models "$active_models" \
  --arg ollama_binary "$OLLAMA_BIN" --arg ollama_binary_sha "$ollama_binary_sha" --arg expected_ollama_sha "$expected_ollama_sha" --argjson ollama_binary_matches "$ollama_binary_matches" --arg ollama_binary_action "$ollama_binary_action" \
  --arg webui_endpoint "$WEBUI_URL" --argjson webui_reachable "$webui_reachable" --argjson webui_response_valid "$webui_response_valid" --arg container_state "$container_state" --arg webui_version "$expected_webui_version" --arg webui_image_reference "$webui_image_reference" --arg expected_webui_digest "$expected_webui_digest" --argjson webui_digest_matches "$webui_digest_matches" --arg webui_action "$webui_action" --argjson docker_available "$docker_available" \
  --arg volume "$VOLUME" --argjson volume_exists "$volume_exists" --arg volume_action "$volume_action" \
  --arg embedding_revision "$expected_embedding_revision" --argjson cache_ready "$cache_ready" --arg cache_action "$cache_action" \
  --argjson models "$models" --arg disk_path "$DISK_PATH" --argjson free_bytes "$free_bytes" --argjson minimum_free_bytes "$MIN_FREE_BYTES" --argjson disk_ok "$disk_ok" --arg disk_action "$disk_action" \
  --argjson environment_exists "$environment_exists" --arg environment_action "$environment_action" --argjson search_enabled "$search_enabled" --arg search_mode "$search_mode" --argjson reranker_enabled "$reranker_enabled" \
  '{schema_version:1,healthy:$healthy,profile:{selected:$profile,path:$profile_path,valid:$profile_valid,action:$profile_action},ollama:{endpoint:$ollama_endpoint,reachable:$ollama_reachable,response_valid:$ollama_response_valid,version:$ollama_version,expected_version:$expected_ollama_version,version_matches:$ollama_version_matches,action:$ollama_action,active_models:$active_models,binary:{path:$ollama_binary,sha256:$ollama_binary_sha,expected_sha256:$expected_ollama_sha,matches:$ollama_binary_matches,action:$ollama_binary_action}},open_webui:{endpoint:$webui_endpoint,reachable:$webui_reachable,response_valid:$webui_response_valid,container_state:$container_state,version:$webui_version,image_reference:$webui_image_reference,expected_digest:$expected_webui_digest,digest_matches:$webui_digest_matches,docker_available:$docker_available,action:$webui_action},volume:{name:$volume,exists:$volume_exists,action:$volume_action},embedding_cache:{revision:$embedding_revision,ready:$cache_ready,action:$cache_action},models:$models,disk:{path:$disk_path,free_bytes:$free_bytes,minimum_free_bytes:$minimum_free_bytes,ok:$disk_ok,action:$disk_action},environment:{exists:$environment_exists,action:$environment_action},optional_features:{rag:true,reranker:$reranker_enabled,web_search:$search_enabled,web_search_mode:$search_mode}}')

if [[ "$json" == true ]]; then
  printf '%s\n' "$report"
  exit 0
fi

jq -r '
  "PROFILE         \(.profile.selected) (\(if .profile.valid then "valid" else "INVALID" end))",
  "OLLAMA         \(if .ollama.reachable then .ollama.version else "unavailable" end) expected=\(.ollama.expected_version) active=\(if (.ollama.active_models|length)==0 then "none" else (.ollama.active_models|join(",")) end)",
  "OLLAMA_BINARY  \(if .ollama.binary.matches then "verified" else "DRIFT" end)",
  "OPEN_WEBUI     \(if .open_webui.reachable then "reachable" else "unavailable" end) container=\(.open_webui.container_state) version=\(.open_webui.version) digest=\(if .open_webui.digest_matches then "verified" else "DRIFT" end)",
  "VOLUME         \(.volume.name) \(if .volume.exists then "present" else "MISSING" end)",
  "EMBEDDING      \(.embedding_cache.revision) \(if .embedding_cache.ready then "cached" else "NOT READY" end)",
  (.models[] | "MODEL           \(.alias) -> \(.tag) \(.state)"),
  "DISK            \(.disk.free_bytes) bytes free (minimum \(.disk.minimum_free_bytes))",
  "OPTIONAL        rag=enabled reranker=\(.optional_features.reranker) web_search=\(.optional_features.web_search) mode=\(.optional_features.web_search_mode)",
  "OVERALL         \(if .healthy then "healthy" else "attention-required" end)"
' <<<"$report"

jq -r '
  [
    (if .profile.valid then empty else .profile.action end),
    (if (.ollama.reachable and .ollama.response_valid and .ollama.version_matches) then empty else .ollama.action end),
    (if .ollama.binary.matches then empty else .ollama.binary.action end),
    (if (.open_webui.reachable and .open_webui.response_valid and .open_webui.digest_matches) then empty else .open_webui.action end),
    (if .volume.exists then empty else .volume.action end),
    (if .embedding_cache.ready then empty else .embedding_cache.action end),
    (.models[] | select(.state != "verified") | .action),
    (if .disk.ok then empty else .disk.action end),
    (if .environment.exists then empty else .environment.action end)
  ] | unique[] | "ACTION          " + .
' <<<"$report"
