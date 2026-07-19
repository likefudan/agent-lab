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
evidence_json='[]'

usage() {
  cat <<'EOF'
Usage: agent-lab offline verify (--config-only | --boundary-confirmed) [--quick | --full]

--config-only verifies offline configuration and local denial paths without
claiming a physical zero-egress boundary.

--boundary-confirmed additionally verifies that a user-controlled outbound
boundary is active. Before using it, turn off Wi-Fi and disconnect Ethernet, or
use reviewed LuLu rules that block outbound traffic for Docker Desktop and
Ollama while preserving loopback/container-to-host traffic. Agent Lab never
changes pf, LuLu, or interface state itself.
EOF
}

print_firewall_steps() {
  cat <<'EOF'
User-approved firewall step required for --boundary-confirmed:
  1. Turn off Wi-Fi and disconnect Ethernet, OR
  2. Apply reviewed LuLu rules that block outbound traffic for Docker Desktop
     and Ollama while preserving loopback and container-to-host traffic.
Agent Lab will not change pf, LuLu, Wi-Fi, or Ethernet state.
EOF
}

record_evidence() {
  local attempt=$1
  local result=$2
  local detail=${3:-}
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  evidence_json=$(jq -c --arg attempt "$attempt" --arg result "$result" --arg detail "$detail" --arg timestamp "$timestamp" \
    '. + [{attempt:$attempt,result:$result,detail:$detail,timestamp:$timestamp}]' <<<"$evidence_json")
}

cleanup() {
  if [[ $profile_applied == true && -n $previous_profile ]]; then
    profile_applied=false
    "$ROOT/config/open-webui/apply-profile.sh" "$previous_profile" >/dev/null 2>&1 ||
      printf 'WARNING: failed to restore profile %s; run config/open-webui/apply-profile.sh %s\n' "$previous_profile" "$previous_profile" >&2
  fi
}
# EXIT performs restore. Signal traps must exit so hold loops cannot continue.
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

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

if [[ $boundary_confirmed == true ]]; then
  print_firewall_steps
fi

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
  # Bash 3.2 on macOS defers trapped signals until sleep completes and does not
  # reliably interrupt sleep, so interrupt tests use a stop file instead of SIGINT.
  mkdir -p "$ROOT/.agent-lab"
  stop_file="$ROOT/.agent-lab/offline-verify.stop"
  pid_file="$ROOT/.agent-lab/offline-verify.pid"
  rm -f -- "$stop_file"
  printf '%s\n' "$$" > "$pid_file"
  while [[ ! -f $stop_file ]]; do
    sleep 1
  done
  rm -f -- "$stop_file" "$pid_file"
  exit 130
fi

container_id=$(docker compose --project-directory "$ROOT" --env-file "$ROOT/.env" -f "$ROOT/compose.yaml" ps --quiet open-webui)
[[ -n $container_id ]] || die 'Open WebUI container is not running' || exit 1
[[ $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | sed -n 's/^OFFLINE_MODE=//p') == true ]] ||
  die 'Open WebUI was not recreated with OFFLINE_MODE=true' || exit 1
[[ $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | sed -n 's/^RAG_EMBEDDING_MODEL_AUTO_UPDATE=//p') == false ]] ||
  die 'embedding auto-update remains enabled' || exit 1
[[ $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" | sed -n 's/^ENABLE_VERSION_UPDATE_CHECK=//p') == false ]] ||
  die 'version update checks remain enabled' || exit 1
record_evidence 'version_update_check' 'disabled' 'ENABLE_VERSION_UPDATE_CHECK=false'

allow_remote=$(agent_lab_effective_profile offline | awk -F= '$1 == "AGENT_LAB_ALLOW_REMOTE_TOOLS" {print $2; exit}')
[[ $allow_remote == false ]] || die 'remote tools remain allowed in the offline profile' || exit 1
record_evidence 'remote_tools' 'disabled' 'AGENT_LAB_ALLOW_REMOTE_TOOLS=false'

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
record_evidence 'search' 'denied' "HTTP $search_code"

if AGENT_LAB_PROFILE=offline "$ROOT/scripts/models.sh" pull --yes qwen-4b >/dev/null 2>&1; then
  die 'offline profile allowed a model pull'
  exit 1
fi
record_evidence 'model_pull' 'denied' 'AGENT_LAB_PROFILE=offline'

models=$(curl --fail --silent --show-error -H "Authorization: Bearer ${token}" "$WEBUI_URL/ollama/api/tags" | jq -c '[.models[].model] | sort')
[[ $models == '["gemma4:12b","qwen3.5:4b","qwen3.5:9b"]' ]] ||
  die "offline model presentation drifted: $models" || exit 1
before_models=$(curl --fail --silent --show-error "$OLLAMA_URL/api/tags" | jq -c '[.models[].name] | sort')
missing_code=$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${token}" --data '{"model":"remote/not-configured:cloud","messages":[{"role":"user","content":"hello"}],"stream":false}' \
  "$WEBUI_URL/ollama/api/chat")
[[ $missing_code == 400 || $missing_code == 404 ]] || die 'remote model selection did not fail locally' || exit 1
record_evidence 'remote_model' 'denied' "HTTP $missing_code"
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
  # Exercise model switching on the managed Ollama (MAX_LOADED_MODELS=1). The
  # isolated lifecycle suite needs a free :11434 and is not used here.
  for tag in qwen3.5:4b qwen3.5:9b gemma4:12b; do
    switch=$(curl --fail --silent --show-error --max-time 240 -H 'Content-Type: application/json' \
      --data "$(jq -cn --arg model "$tag" '{model:$model,messages:[{role:"user",content:"Reply with exactly READY"}],stream:false,think:false,keep_alive:0,options:{temperature:0,num_predict:32,num_ctx:4096}}')" \
      "$OLLAMA_URL/api/chat") || die "offline model switch failed for $tag" || exit 1
    [[ $(jq -r '.message.content' <<<"$switch" | tr -d '[:space:]') == READY ]] ||
      die "offline model switch did not return READY for $tag" || exit 1
    loaded=$(curl --fail --silent --show-error "$OLLAMA_URL/api/ps" | jq '.models | length')
    # keep_alive:0 may already unload; never allow more than one resident model.
    [[ $loaded -le 1 ]] || die "offline model switch left $loaded models resident after $tag" || exit 1
  done
  record_evidence 'model_switching' 'verified' 'qwen3.5:4b,qwen3.5:9b,gemma4:12b against managed Ollama'
else
  text=$(curl --fail --silent --show-error --max-time 120 -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${token}" --data '{"model":"qwen3.5:4b","messages":[{"role":"user","content":"Reply exactly OFFLINE-LOCAL-OK"}],"stream":false,"think":false,"keep_alive":0}' \
    "$WEBUI_URL/ollama/api/chat")
  [[ $(jq -r '.message.content' <<<"$text") == *OFFLINE-LOCAL-OK* ]] || die 'offline local chat failed' || exit 1
fi

boundary='configuration_only'
if [[ $boundary_confirmed == true ]]; then
  egress_detail=
  if docker exec "$container_id" curl --silent --show-error --max-time 5 https://example.com >/tmp/agent-lab-offline-egress.out 2>/tmp/agent-lab-offline-egress.err; then
    record_evidence 'outbound_https' 'reachable' 'https://example.com succeeded from Open WebUI container'
    die 'outbound boundary is not active: Open WebUI reached example.com'
    exit 1
  fi
  egress_detail=$(tr '\n' ' ' </tmp/agent-lab-offline-egress.err | sed 's/[[:space:]]\+/ /g')
  record_evidence 'outbound_https' 'blocked' "${egress_detail:-curl failed}"
  rm -f /tmp/agent-lab-offline-egress.out /tmp/agent-lab-offline-egress.err

  if docker exec "$container_id" getent hosts example.com >/tmp/agent-lab-offline-dns.out 2>/tmp/agent-lab-offline-dns.err; then
    # DNS may still resolve from cache/local stub while egress is blocked; require HTTPS failure above.
    dns_detail=$(tr '\n' ' ' </tmp/agent-lab-offline-dns.out | sed 's/[[:space:]]\+/ /g')
    record_evidence 'dns_lookup' 'resolved_without_egress' "$dns_detail"
  else
    dns_detail=$(tr '\n' ' ' </tmp/agent-lab-offline-dns.err | sed 's/[[:space:]]\+/ /g')
    record_evidence 'dns_lookup' 'failed' "${dns_detail:-getent failed}"
  fi
  rm -f /tmp/agent-lab-offline-dns.out /tmp/agent-lab-offline-dns.err
  boundary='user_controlled_egress_block_verified'
else
  printf '%s\n' 'NOTICE: configuration-only pass; no physical/LuLu zero-egress claim was made.'
  record_evidence 'outbound_https' 'not_probed' 'configuration_only mode does not claim a zero-egress boundary'
fi

mkdir -p "$ROOT/.agent-lab/results"
results_file="$ROOT/.agent-lab/results/offline-latest.json"
jq -n --arg boundary "$boundary" --arg previous_profile "$previous_profile" \
  --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson evidence "$evidence_json" \
  '{
    status:"pass",
    timestamp:$timestamp,
    boundary:$boundary,
    profile_during_test:"offline",
    restored_profile:$previous_profile,
    remote_attempts:{
      search:"denied",
      model_pull:"denied",
      remote_model:"denied",
      version_update_check:"disabled",
      remote_tools:"disabled"
    },
    outbound_evidence:$evidence,
    core:{models:"verified",embedding_cache:"verified",chat:"verified"}
  }' > "$results_file"
printf 'PASS: offline verification (%s); profile will restore to %s\n' "$boundary" "$previous_profile"
