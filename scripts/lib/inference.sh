#!/usr/bin/env bash
# Active-backend client wiring for Open WebUI, LLM CLI, and Aider (P10-T05).
# Source after scripts/lib/common.sh and scripts/lib/backends.sh.

agent_lab_inference_init() {
  agent_lab_backends_init "$@"
  AGENT_LAB_INFERENCE_ENV_FILE="${AGENT_LAB_INFERENCE_ENV_FILE:-$AGENT_LAB_STATE_DIR/inference.env}"
  AGENT_LAB_LLM_RUNTIME_DIR="${AGENT_LAB_LLM_RUNTIME_DIR:-$AGENT_LAB_REPO_ROOT/.agent-lab/llm}"
  AGENT_LAB_AIDER_RUNTIME_DIR="${AGENT_LAB_AIDER_RUNTIME_DIR:-$AGENT_LAB_REPO_ROOT/.agent-lab/aider}"
  AGENT_LAB_LLM_SEED_DIR="${AGENT_LAB_LLM_SEED_DIR:-$AGENT_LAB_REPO_ROOT/config/llm}"
  AGENT_LAB_AIDER_SEED_DIR="${AGENT_LAB_AIDER_SEED_DIR:-$AGENT_LAB_REPO_ROOT/config/aider}"
  AGENT_LAB_WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
  AGENT_LAB_INFERENCE_APPLY_WEBUI="${AGENT_LAB_INFERENCE_APPLY_WEBUI:-auto}"
}

# Rewrite loopback host URLs so containers can reach host-published servers.
agent_lab_inference_dockerize_url() {
  local url=$1
  printf '%s\n' "${url//127.0.0.1/host.docker.internal}"
}

agent_lab_inference_executable_aliases() {
  local backend_id=$1
  jq -r --arg backend "$backend_id" '
    .models[]
    | select(.executable == true)
    | select((.backends[$backend] | type) == "object")
    | select(.backends[$backend].status == "executable")
    | .alias
  ' "$AGENT_LAB_MODELS_FILE"
}

# Resolve the model id a client should send to the active backend.
agent_lab_inference_model_id() {
  local backend_id=$1
  local alias=$2
  local status artifact revision repo_dir snap
  status=$(jq -er --arg alias "$alias" --arg backend "$backend_id" '
    .models[] | select(.alias == $alias and .executable == true)
    | .backends[$backend].status
  ' "$AGENT_LAB_MODELS_FILE") || return 1
  [[ "$status" == executable ]] || return 1
  case $backend_id in
    ollama)
      jq -er --arg alias "$alias" --arg backend "$backend_id" '
        .models[] | select(.alias == $alias and .executable == true)
        | .backends[$backend].artifact_id // .tag
      ' "$AGENT_LAB_MODELS_FILE"
      ;;
    mlx_lm|mlx_vlm)
      artifact=$(jq -er --arg alias "$alias" --arg backend "$backend_id" '
        .models[] | select(.alias == $alias and .executable == true)
        | .backends[$backend].artifact_id
      ' "$AGENT_LAB_MODELS_FILE") || return 1
      revision=$(jq -er --arg alias "$alias" --arg backend "$backend_id" '
        .models[] | select(.alias == $alias and .executable == true)
        | .backends[$backend].revision
      ' "$AGENT_LAB_MODELS_FILE") || return 1
      repo_dir=$(printf '%s' "$artifact" | sed 's|/|--|g')
      snap="$AGENT_LAB_HF_HOME/hub/models--${repo_dir}/snapshots/${revision}"
      if [[ -d "$snap" ]]; then
        printf '%s\n' "$snap"
      else
        # Prefer snapshot when present; otherwise advertise the HF id for /v1 clients.
        printf '%s\n' "$artifact"
      fi
      ;;
    lm_studio|llama_cpp)
      artifact=$(jq -er --arg alias "$alias" --arg backend "$backend_id" '
        .models[] | select(.alias == $alias and .executable == true)
        | .backends[$backend].artifact_id
      ' "$AGENT_LAB_MODELS_FILE") || return 1
      [[ "$artifact" != null && -n "$artifact" ]] || return 1
      printf '%s\n' "$artifact"
      ;;
    *)
      return 1
      ;;
  esac
}

agent_lab_inference_default_alias() {
  local backend_id=$1
  local role alias
  for role in coding chat fast vision; do
    alias=$(jq -er --arg role "$role" '.defaults[$role] // empty' "$AGENT_LAB_MODELS_FILE") || true
    [[ -n "$alias" ]] || continue
    if agent_lab_inference_model_id "$backend_id" "$alias" >/dev/null 2>&1; then
      printf '%s\n' "$alias"
      return 0
    fi
  done
  alias=$(agent_lab_inference_executable_aliases "$backend_id" | head -n 1 || true)
  [[ -n "$alias" ]] || return 0
  printf '%s\n' "$alias"
}

agent_lab_inference_model_ids_json() {
  local backend_id=$1
  local alias model_id
  local ids='[]'
  while IFS= read -r alias; do
    [[ -n "$alias" ]] || continue
    model_id=$(agent_lab_inference_model_id "$backend_id" "$alias") || continue
    ids=$(jq -cn --argjson ids "$ids" --arg id "$model_id" '$ids + [$id]')
  done < <(agent_lab_inference_executable_aliases "$backend_id")
  printf '%s\n' "$ids"
}

agent_lab_inference_resolve() {
  local backend_id=${1:-}
  local openai_base docker_openai bind host port default_alias default_model_id model_ids
  agent_lab_inference_init
  [[ -n "$backend_id" ]] || backend_id=$(agent_lab_backend_active)
  agent_lab_backend_exists "$backend_id" || die "unknown backend id: $backend_id"
  openai_base=$(agent_lab_backend_field "$backend_id" '.openai_base_url')
  docker_openai=$(agent_lab_inference_dockerize_url "$openai_base")
  read -r host port <<<"$(agent_lab_backend_host_port "$backend_id")"
  bind=$(agent_lab_backend_field "$backend_id" '.bind')
  default_alias=$(agent_lab_inference_default_alias "$backend_id" 2>/dev/null || true)
  default_model_id=
  model_ids='[]'
  if [[ -n "$default_alias" ]]; then
    default_model_id=$(agent_lab_inference_model_id "$backend_id" "$default_alias")
    model_ids=$(agent_lab_inference_model_ids_json "$backend_id")
  fi
  jq -cn \
    --arg backend_id "$backend_id" \
    --arg openai_base_url "$openai_base" \
    --arg docker_openai_base_url "$docker_openai" \
    --arg bind "$bind" \
    --arg host "$host" \
    --argjson port "$port" \
    --arg default_alias "${default_alias:-}" \
    --arg default_model_id "${default_model_id:-}" \
    --argjson model_ids "$model_ids" \
    --argjson use_ollama_native "$([[ "$backend_id" == ollama ]] && echo true || echo false)" \
    '{
      backend_id:$backend_id,
      openai_base_url:$openai_base_url,
      docker_openai_base_url:$docker_openai_base_url,
      bind:$bind,
      host:$host,
      port:$port,
      default_alias:$default_alias,
      default_model_id:$default_model_id,
      model_ids:$model_ids,
      use_ollama_native:$use_ollama_native
    }'
}

agent_lab_inference_write_env_file() {
  local resolved=$1
  local dest=${2:-$AGENT_LAB_INFERENCE_ENV_FILE}
  local backend_id openai_base docker_openai model_ids ollama_configs openai_configs
  local enable_ollama enable_openai ollama_base openai_urls openai_keys
  backend_id=$(jq -er '.backend_id' <<<"$resolved")
  openai_base=$(jq -er '.openai_base_url' <<<"$resolved")
  docker_openai=$(jq -er '.docker_openai_base_url' <<<"$resolved")
  model_ids=$(jq -c '.model_ids' <<<"$resolved")
  mkdir -p "$(dirname "$dest")"

  if jq -e '.use_ollama_native == true' <<<"$resolved" >/dev/null; then
    enable_ollama=true
    enable_openai=false
    ollama_base='http://host.docker.internal:11434'
    ollama_configs=$(jq -cn --argjson ids "$model_ids" \
      '{"0":{"enable":true,"connection_type":"local","model_ids":$ids}}')
    openai_urls=
    openai_keys=
    openai_configs='{}'
  else
    enable_ollama=false
    enable_openai=true
    ollama_base=
    ollama_configs='{}'
    openai_urls=$docker_openai
    openai_keys='agent-lab'
    openai_configs=$(jq -cn --argjson ids "$model_ids" \
      '{"0":{"enable":true,"connection_type":"local","model_ids":$ids}}')
  fi

  local temporary
  temporary=$(mktemp "${dest}.tmp.XXXXXX")
  cat >"$temporary" <<EOF
# Generated by agent-lab apply-inference. Do not commit.
# Active backend client wiring (decision 0011 / P10-T05).
AGENT_LAB_INFERENCE_BACKEND=${backend_id}
AGENT_LAB_OPENAI_BASE_URL=${openai_base}
AGENT_LAB_OPENAI_API_KEY=agent-lab
ENABLE_OLLAMA_API=${enable_ollama}
OLLAMA_BASE_URL=${ollama_base}
OLLAMA_API_CONFIGS=${ollama_configs}
ENABLE_OPENAI_API=${enable_openai}
OPENAI_API_BASE_URLS=${openai_urls}
OPENAI_API_KEYS=${openai_keys}
OPENAI_API_CONFIGS=${openai_configs}
EOF
  chmod 600 "$temporary"
  mv -f "$temporary" "$dest"
  info "wrote inference env: $dest (backend=$backend_id)"
}

agent_lab_inference_write_llm_runtime() {
  local resolved=$1
  local runtime=$AGENT_LAB_LLM_RUNTIME_DIR
  local backend_id openai_base default_alias default_model_id alias model_id
  local extra_yaml aliases_json
  backend_id=$(jq -er '.backend_id' <<<"$resolved")
  openai_base=$(jq -er '.openai_base_url' <<<"$resolved")
  default_alias=$(jq -er '.default_alias // empty' <<<"$resolved")
  default_model_id=$(jq -er '.default_model_id // empty' <<<"$resolved")
  mkdir -p "$runtime"
  cp "$AGENT_LAB_LLM_SEED_DIR/logs-off" "$runtime/logs-off"

  if jq -e '.use_ollama_native == true' <<<"$resolved" >/dev/null; then
    cp "$AGENT_LAB_LLM_SEED_DIR/aliases.json" "$runtime/aliases.json"
    cp "$AGENT_LAB_LLM_SEED_DIR/default_model.txt" "$runtime/default_model.txt"
    cat >"$runtime/environment.env" <<EOF
# Generated by agent-lab apply-inference for backend=ollama.
# Native Ollama only when this backend is active (decision 0011).
OLLAMA_HOST=http://127.0.0.1:11434
LLM_LOAD_PLUGINS=llm-ollama
AGENT_LAB_INFERENCE_BACKEND=ollama
AGENT_LAB_OPENAI_BASE_URL=http://127.0.0.1:11434/v1
EOF
    rm -f -- "$runtime/extra-openai-models.yaml"
  else
    # Exclude llm-ollama so non-Ollama paths cannot silently fall through.
    cat >"$runtime/environment.env" <<EOF
# Generated by agent-lab apply-inference for backend=${backend_id}.
# OpenAI-compatible /v1 only — llm-ollama is excluded (no Ollama fallback).
AGENT_LAB_INFERENCE_BACKEND=${backend_id}
AGENT_LAB_OPENAI_BASE_URL=${openai_base}
OPENAI_BASE_URL=${openai_base}
OPENAI_API_BASE=${openai_base}
OPENAI_API_KEY=agent-lab
LLM_LOAD_PLUGINS=-llm-ollama
EOF
    aliases_json='{}'
    extra_yaml=
    while IFS= read -r alias; do
      [[ -n "$alias" ]] || continue
      model_id=$(agent_lab_inference_model_id "$backend_id" "$alias") || continue
      aliases_json=$(jq -cn --argjson cur "$aliases_json" --arg a "$alias" --arg m "$model_id" \
        '$cur + {($a): $m}')
      extra_yaml+="- model_id: ${alias}"$'\n'
      extra_yaml+="  model_name: ${model_id}"$'\n'
      extra_yaml+="  api_base: ${openai_base}"$'\n'
    done < <(agent_lab_inference_executable_aliases "$backend_id")
    printf '%s\n' "$aliases_json" | jq -S . >"$runtime/aliases.json"
    if [[ -n "$extra_yaml" ]]; then
      printf '%s' "$extra_yaml" >"$runtime/extra-openai-models.yaml"
    else
      rm -f -- "$runtime/extra-openai-models.yaml"
    fi
    if [[ -n "$default_alias" ]]; then
      printf '%s\n' "$default_alias" >"$runtime/default_model.txt"
    elif [[ -n "$default_model_id" ]]; then
      printf '%s\n' "$default_model_id" >"$runtime/default_model.txt"
    else
      printf '%s\n' '' >"$runtime/default_model.txt"
    fi
  fi
  info "wrote LLM CLI runtime: $runtime"
}

agent_lab_inference_write_aider_runtime() {
  local resolved=$1
  local runtime=$AGENT_LAB_AIDER_RUNTIME_DIR
  local backend_id openai_base default_alias default_model_id model_ref
  local settings_name metadata_name
  backend_id=$(jq -er '.backend_id' <<<"$resolved")
  openai_base=$(jq -er '.openai_base_url' <<<"$resolved")
  default_alias=$(jq -er '.default_alias // empty' <<<"$resolved")
  default_model_id=$(jq -er '.default_model_id // empty' <<<"$resolved")
  mkdir -p "$runtime"
  cp "$AGENT_LAB_AIDER_SEED_DIR/aider.model.settings.yml" "$runtime/aider.model.settings.yml"
  cp "$AGENT_LAB_AIDER_SEED_DIR/aider.model.metadata.json" "$runtime/aider.model.metadata.json"

  if jq -e '.use_ollama_native == true' <<<"$resolved" >/dev/null; then
    cp "$AGENT_LAB_AIDER_SEED_DIR/aider.conf.yml" "$runtime/aider.conf.yml"
  else
    [[ -n "$default_model_id" ]] || die "no default model id for aider on backend '$backend_id'"
    model_ref="openai/${default_model_id}"
    settings_name=$(basename "$runtime/aider.model.settings.yml")
    metadata_name=$(basename "$runtime/aider.model.metadata.json")
    # Prefer /v1 for non-Ollama backends; placeholder key is local-only.
    cat >"$runtime/aider.conf.yml" <<EOF
# Generated by agent-lab apply-inference for backend=${backend_id}.
model: ${model_ref}
weak-model: ${model_ref}
openai-api-base: ${openai_base}
openai-api-key: agent-lab

edit-format: whole
model-settings-file: ${settings_name}
model-metadata-file: ${metadata_name}
show-model-warnings: false
check-model-accepts-settings: false
max-chat-history-tokens: 1024
map-tokens: 0
stream: false

git: true
gitignore: false
add-gitignore-files: false
auto-commits: false
dirty-commits: false
attribute-author: false
attribute-committer: false
attribute-commit-message-author: false
attribute-commit-message-committer: false
attribute-co-authored-by: false
auto-lint: false
auto-test: false
suggest-shell-commands: false

analytics-disable: true
check-update: false
show-release-notes: false
detect-urls: false
disable-playwright: true
cache-prompts: false
restore-chat-history: false
input-history-file: .agent-lab/aider/input.history
chat-history-file: .agent-lab/aider/chat.history.md
pretty: false
notifications: false
EOF
    # Pair settings/metadata entries with the active model id when possible.
    if [[ -n "$default_alias" ]]; then
      jq -cn --arg name "$model_ref" \
        '[{"name":$name,"edit_format":"whole","weak_model_name":$name,"use_repo_map":false,"use_temperature":0.0,"streaming":false,"extra_params":{"max_tokens":1024}}]' \
        >"$runtime/aider.model.settings.yml"
      jq -cn --arg name "$model_ref" \
        '{($name):{"max_tokens":4096,"max_input_tokens":4096,"max_output_tokens":1024,"input_cost_per_token":0,"output_cost_per_token":0,"litellm_provider":"openai","mode":"chat"}}' \
        >"$runtime/aider.model.metadata.json"
    fi
  fi
  info "wrote Aider runtime: $runtime/aider.conf.yml"
}

agent_lab_inference_webui_healthy() {
  command_exists curl || return 1
  curl --silent --fail --max-time 2 "$AGENT_LAB_WEBUI_URL/health" >/dev/null 2>&1
}

agent_lab_inference_webui_token() {
  local admin_email admin_password auth
  [[ -r "$AGENT_LAB_REPO_ROOT/.env" ]] || return 1
  admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "$AGENT_LAB_REPO_ROOT/.env")
  admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$AGENT_LAB_REPO_ROOT/.env")
  [[ -n "$admin_email" && -n "$admin_password" ]] || return 1
  auth=$(curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" \
      '{email:$email,password:$password}')" \
    "$AGENT_LAB_WEBUI_URL/api/v1/auths/signin") || return 1
  jq -er '.token' <<<"$auth"
}

agent_lab_inference_apply_webui_api() {
  local resolved=$1
  local token model_ids docker_openai ollama_body openai_body
  token=$(agent_lab_inference_webui_token) || {
    warn 'Open WebUI admin sign-in failed; wrote client files only'
    return 1
  }
  model_ids=$(jq -c '.model_ids' <<<"$resolved")
  docker_openai=$(jq -er '.docker_openai_base_url' <<<"$resolved")

  if jq -e '.use_ollama_native == true' <<<"$resolved" >/dev/null; then
    ollama_body=$(jq -cn --argjson ids "$model_ids" \
      '{ENABLE_OLLAMA_API:true,OLLAMA_BASE_URLS:["http://host.docker.internal:11434"],OLLAMA_API_CONFIGS:{"0":{"enable":true,"connection_type":"local","model_ids":$ids}}}')
    openai_body='{"ENABLE_OPENAI_API":false,"OPENAI_API_BASE_URLS":[],"OPENAI_API_KEYS":[],"OPENAI_API_CONFIGS":{}}'
  else
    ollama_body='{"ENABLE_OLLAMA_API":false,"OLLAMA_BASE_URLS":[],"OLLAMA_API_CONFIGS":{}}'
    openai_body=$(jq -cn --arg url "$docker_openai" --argjson ids "$model_ids" \
      '{ENABLE_OPENAI_API:true,OPENAI_API_BASE_URLS:[$url],OPENAI_API_KEYS:["agent-lab"],OPENAI_API_CONFIGS:{"0":{"enable":true,"connection_type":"local","model_ids":$ids}}}')
  fi

  curl --fail --silent --show-error --max-time 60 \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
    --data "$ollama_body" "$AGENT_LAB_WEBUI_URL/ollama/config/update" >/dev/null || {
    warn 'failed to update Open WebUI Ollama connection'
    return 1
  }
  curl --fail --silent --show-error --max-time 60 \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
    --data "$openai_body" "$AGENT_LAB_WEBUI_URL/openai/config/update" >/dev/null || {
    warn 'failed to update Open WebUI OpenAI connection'
    return 1
  }
  info "applied Open WebUI provider config for backend=$(jq -er '.backend_id' <<<"$resolved")"
}

# Compose helpers: pass private .env then generated inference.env (later wins).
agent_lab_inference_compose_env_args() {
  agent_lab_inference_init
  local args=()
  [[ -r "$AGENT_LAB_REPO_ROOT/.env" ]] || {
    die "private environment file is missing; run 'agent-lab setup' first"
    return 1
  }
  args+=(--env-file "$AGENT_LAB_REPO_ROOT/.env")
  if [[ -r "$AGENT_LAB_INFERENCE_ENV_FILE" ]]; then
    args+=(--env-file "$AGENT_LAB_INFERENCE_ENV_FILE")
  fi
  printf '%s\0' "${args[@]}"
}

agent_lab_inference_ensure_default_env() {
  agent_lab_inference_init
  [[ -r "$AGENT_LAB_INFERENCE_ENV_FILE" ]] && return 0
  local resolved
  resolved=$(agent_lab_inference_resolve "$(agent_lab_backend_active)")
  agent_lab_inference_write_env_file "$resolved"
}

agent_lab_inference_apply() {
  local backend_id=${1:-}
  local skip_webui=${2:-false}
  local resolved
  agent_lab_backends_require_catalog
  agent_lab_inference_init
  require_command jq
  [[ -n "$backend_id" ]] || backend_id=$(agent_lab_backend_active)
  resolved=$(agent_lab_inference_resolve "$backend_id")
  agent_lab_inference_write_env_file "$resolved"
  agent_lab_inference_write_llm_runtime "$resolved"
  agent_lab_inference_write_aider_runtime "$resolved"

  if [[ "$skip_webui" == true ]]; then
    return 0
  fi
  case $AGENT_LAB_INFERENCE_APPLY_WEBUI in
    never|false|0) return 0 ;;
  esac
  if agent_lab_inference_webui_healthy; then
    agent_lab_inference_apply_webui_api "$resolved" || true
    if [[ -x "$AGENT_LAB_REPO_ROOT/config/open-webui/apply-model-params.sh" ]]; then
      "$AGENT_LAB_REPO_ROOT/config/open-webui/apply-model-params.sh" >/dev/null ||
        warn 'Open WebUI model params apply failed; run config/open-webui/apply-model-params.sh'
    fi
  else
    info 'Open WebUI is not healthy; provider API update deferred until next start/apply'
  fi
}
