#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

readonly ROOT="$(repository_root "$SCRIPT_DIR")"
readonly WEBUI_URL='http://127.0.0.1:3000'
readonly OLLAMA_URL='http://127.0.0.1:11434'
previous_profile=
profile_applied=false
boundary_confirmed=false
full=false
quick=false
results_file=

usage() {
  cat <<'EOF'
Usage: agent-lab offline verify (--config-only | --boundary-confirmed) [--quick | --full]

--config-only verifies offline configuration and local denial paths without
claiming a physical zero-egress boundary.

--boundary-confirmed records the operator's attestation that a user-controlled
outbound boundary is active and proves the WebUI container cannot reach a fixed
external probe. Before using it, turn off Wi-Fi and disconnect Ethernet, or use
reviewed LuLu rules that block outbound traffic for Docker Desktop and Ollama
while preserving loopback/container-to-host traffic. Agent Lab never changes
pf, LuLu, or interface state itself.
EOF
}

cleanup() {
  if [[ $profile_applied == true && -n $previous_profile ]]; then
    "$ROOT/config/open-webui/apply-profile.sh" "$previous_profile" >/dev/null 2>&1 ||
      printf 'WARNING: failed to restore profile %s; run config/open-webui/apply-profile.sh %s\n' "$previous_profile" "$previous_profile" >&2
  fi
}
trap cleanup EXIT HUP INT TERM

mode=
while (($#)); do
  case $1 in
    --config-only|--boundary-confirmed)
      [[ -z $mode ]] || { usage >&2; die 'choose exactly one boundary mode'; exit 64; }
      mode=$1
      [[ $1 == --boundary-confirmed ]] && boundary_confirmed=true
      shift ;;
    --quick) quick=true; shift ;;
    --full) full=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown offline verification option: $1"; exit 64 ;;
  esac
done
[[ -n $mode ]] || { usage >&2; exit 64; }
[[ $quick != true || $full != true ]] || die 'choose --quick or --full, not both' || exit 64

require_command curl
require_command jq
require_command docker
[[ -f "$ROOT/.env" ]] || die 'run bin/agent-lab setup first' || exit 1
"$ROOT/scripts/models.sh" verify >/dev/null || die 'approved model cache is incomplete' || exit 1
"$ROOT/config/open-webui/verify-embedding-cache.sh" >/dev/null || exit 1
previous_profile=$(agent_lab_active_profile)
"$ROOT/config/open-webui/apply-profile.sh" offline >/dev/null
profile_applied=true

if [[ ${AGENT_LAB_OFFLINE_TEST_HOLD:-0} == 1 ]]; then
  while :; do sleep 1; done
fi

container_id=$(docker compose --project-directory "$ROOT" --env-file "$ROOT/.env" -f "$ROOT/compose.yaml" ps --quiet open-webui)
[[ -n $container_id ]] || die 'Open WebUI container is not running' || exit 1
[[ $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | sed -n 's/^OFFLINE_MODE=//p') == true ]] ||
  die 'Open WebUI was not recreated with OFFLINE_MODE=true' || exit 1
[[ $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | sed -n 's/^RAG_EMBEDDING_MODEL_AUTO_UPDATE=//p') == false ]] ||
  die 'embedding auto-update remains enabled' || exit 1

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "$ROOT/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$ROOT/.env")
auth=$(curl --fail --silent --show-error --max-time 30 -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
  "$WEBUI_URL/api/v1/auths/signin") || die 'Open WebUI sign-in failed' || exit 1
token=$(jq -er '.token' <<<"$auth") || die 'Open WebUI sign-in returned no token' || exit 1
config=$(curl --fail --silent --show-error -H "Authorization: Bearer ${token}" "$WEBUI_URL/api/v1/retrieval/config")
jq -e '.web.ENABLE_WEB_SEARCH == false and .web.WEB_SEARCH_ENGINE == ""' <<<"$config" >/dev/null ||
  die 'search remains enabled in the offline profile' || exit 1

search_code=$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${token}" --data '{"queries":["must not leave host"]}' \
  "$WEBUI_URL/api/v1/retrieval/process/web/search")
[[ $search_code == 403 ]] || die "offline search was not denied locally (HTTP $search_code)" || exit 1
if AGENT_LAB_PROFILE=offline "$ROOT/scripts/models.sh" pull --yes qwen-4b >/dev/null 2>&1; then
  die 'offline profile allowed a model pull'
  exit 1
fi

models=$(curl --fail --silent --show-error -H "Authorization: Bearer ${token}" "$WEBUI_URL/ollama/api/tags" | jq -c '[.models[].model] | sort')
[[ $models == '["gemma4:12b","qwen3.5:4b","qwen3.5:9b"]' ]] ||
  die "offline model presentation drifted: $models" || exit 1
before_models=$(curl --fail --silent --show-error "$OLLAMA_URL/api/tags" | jq -c '[.models[].name] | sort')
missing_code=$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${token}" --data '{"model":"remote/not-configured:cloud","messages":[{"role":"user","content":"hello"}],"stream":false}' \
  "$WEBUI_URL/ollama/api/chat")
[[ $missing_code == 400 || $missing_code == 404 ]] || die 'remote model selection did not fail locally' || exit 1
after_models=$(curl --fail --silent --show-error "$OLLAMA_URL/api/tags" | jq -c '[.models[].name] | sort')
[[ $after_models == "$before_models" ]] || die 'denied remote selection changed the local model store' || exit 1

if [[ $full == true ]]; then
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
    "$ROOT/tests/smoke/test-webui.sh"
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
    "$ROOT/tests/smoke/test-llm-cli.sh"
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost \
    "$ROOT/tests/smoke/test-aider.sh"
  "$ROOT/tests/integration/test-rag.sh"
  # P2-T03 owns the destructive isolated-server lifecycle suite. Here the
  # managed server must remain up for WebUI, so exercise live model switching
  # without attempting to bind a second Ollama to the same port.
  for model in qwen3.5:4b qwen3.5:9b gemma4:12b; do
    switch_response=$(curl --fail --silent --show-error --max-time 240 \
      -H 'Content-Type: application/json' \
      --data "$(jq -cn --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply exactly SWITCH-OK"}],stream:false,think:false,keep_alive:"5m",options:{temperature:0,num_predict:32,num_ctx:4096}}')" \
      "$OLLAMA_URL/api/chat")
    [[ $(jq -r '.message.content' <<<"$switch_response" | tr -d '[:space:]') == SWITCH-OK ]] ||
      die "offline model switch failed for $model" || exit 1
    loaded=$(curl --fail --silent --show-error "$OLLAMA_URL/api/ps")
    [[ $(jq '.models | length' <<<"$loaded") -eq 1 ]] ||
      die "offline model switch loaded more than one model for $model" || exit 1
    [[ $(jq -r '.models[0].name' <<<"$loaded") == "$model" ]] ||
      die "offline active model does not match $model" || exit 1
  done
  curl --fail --silent --show-error --max-time 30 -H 'Content-Type: application/json' \
    --data '{"model":"gemma4:12b","keep_alive":0}' "$OLLAMA_URL/api/generate" >/dev/null
else
  text=$(curl --fail --silent --show-error --max-time 120 -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${token}" --data '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Reply exactly OFFLINE-LOCAL-OK"}],"stream":false,"think":false,"keep_alive":0}' \
    "$WEBUI_URL/ollama/api/chat")
  [[ $(jq -r '.message.content' <<<"$text") == *OFFLINE-LOCAL-OK* ]] || die 'offline local chat failed' || exit 1
fi

boundary='configuration_only'
if [[ $boundary_confirmed == true ]]; then
  docker exec "$container_id" sh -c 'command -v curl >/dev/null && curl --fail --silent --max-time 5 http://127.0.0.1:8080/health >/dev/null' ||
    die 'boundary probe preflight failed inside Open WebUI; cannot interpret an outbound failure' || exit 1
  set +e
  docker exec "$container_id" curl --fail --silent --show-error --max-time 5 https://example.com >/dev/null 2>&1
  outbound_status=$?
  set -e
  if [[ $outbound_status -eq 0 ]]; then
    die 'outbound boundary is not active: Open WebUI reached example.com'
    exit 1
  fi
  case $outbound_status in
    5|6|7|28|35|52|56|60) ;;
    *) die "outbound probe failed ambiguously with curl/docker status $outbound_status"; exit 1 ;;
  esac
  boundary='user_attested_boundary_webui_probe_passed'
else
  printf '%s\n' 'NOTICE: configuration-only pass; no physical/LuLu zero-egress claim was made.'
fi

mkdir -p "$ROOT/.agent-lab/results"
results_file="$ROOT/.agent-lab/results/offline-latest.json"
"$ROOT/config/open-webui/apply-profile.sh" "$previous_profile" >/dev/null
[[ $(agent_lab_active_profile) == "$previous_profile" ]] ||
  die "failed to verify restoration of profile $previous_profile" || exit 1
profile_applied=false
jq -n --arg boundary "$boundary" --arg previous_profile "$previous_profile" \
  --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{status:"pass",timestamp:$timestamp,boundary:$boundary,profile_during_test:"offline",restored_profile:$previous_profile,remote_attempts:{search:"denied",model_pull:"denied",remote_model:"denied"},core:{models:"verified",embedding_cache:"verified",chat:"verified"}}' > "$results_file"
printf 'PASS: offline verification (%s); restored profile %s\n' "$boundary" "$previous_profile"
