#!/usr/bin/env bash
# Shared inference-backend helpers for Agent Lab (P10-T04).
# Source after scripts/lib/common.sh. Does not start backends on load.

agent_lab_backends_init() {
  local start=${1:-}
  if [[ -z "${AGENT_LAB_REPO_ROOT:-}" ]]; then
    if [[ -n "$start" ]]; then
      AGENT_LAB_REPO_ROOT="$(repository_root "$start")"
    else
      AGENT_LAB_REPO_ROOT="$(repository_root)"
    fi
  fi
  AGENT_LAB_BACKENDS_FILE="${AGENT_LAB_BACKENDS_FILE:-$AGENT_LAB_REPO_ROOT/config/backends.json}"
  AGENT_LAB_MODELS_FILE="${AGENT_LAB_MODELS_FILE:-$AGENT_LAB_REPO_ROOT/config/models.json}"
  AGENT_LAB_COMPONENTS_FILE="${AGENT_LAB_COMPONENTS_FILE:-$AGENT_LAB_REPO_ROOT/config/components.json}"
  AGENT_LAB_MLX_VENV="${AGENT_LAB_MLX_VENV:-$AGENT_LAB_REPO_ROOT/.agent-lab/venvs/mlx}"
  AGENT_LAB_MLX_LM_WRAPPER="${AGENT_LAB_MLX_LM_WRAPPER:-$AGENT_LAB_REPO_ROOT/config/mlx/run-mlx-lm.sh}"
  AGENT_LAB_MLX_VLM_WRAPPER="${AGENT_LAB_MLX_VLM_WRAPPER:-$AGENT_LAB_REPO_ROOT/config/mlx/run-mlx-vlm.sh}"
  AGENT_LAB_STATE_DIR="${AGENT_LAB_STATE_DIR:-$HOME/.agent-lab/state}"
  AGENT_LAB_RUN_DIR="${AGENT_LAB_RUN_DIR:-$HOME/.agent-lab/run}"
  AGENT_LAB_LOG_DIR="${AGENT_LAB_LOG_DIR:-$HOME/.agent-lab/logs}"
  AGENT_LAB_ACTIVE_BACKEND_FILE="${AGENT_LAB_ACTIVE_BACKEND_FILE:-$AGENT_LAB_STATE_DIR/active-backend}"
  AGENT_LAB_OLLAMA_BIN="${AGENT_LAB_OLLAMA_BIN:-/opt/homebrew/opt/ollama/bin/ollama}"
  AGENT_LAB_OLLAMA_PLIST_TEMPLATE="${AGENT_LAB_OLLAMA_PLIST_TEMPLATE:-$AGENT_LAB_REPO_ROOT/config/ollama/ai.agent-lab.ollama.plist.template}"
  AGENT_LAB_OLLAMA_LAUNCH_LABEL="${AGENT_LAB_OLLAMA_LAUNCH_LABEL:-ai.agent-lab.ollama}"
  AGENT_LAB_OLLAMA_LAUNCH_DOMAIN="${AGENT_LAB_OLLAMA_LAUNCH_DOMAIN:-gui/$(id -u)}"
  AGENT_LAB_OLLAMA_LAUNCH_SERVICE="${AGENT_LAB_OLLAMA_LAUNCH_DOMAIN}/${AGENT_LAB_OLLAMA_LAUNCH_LABEL}"
  AGENT_LAB_OLLAMA_INSTALLED_PLIST="${AGENT_LAB_OLLAMA_INSTALLED_PLIST:-$HOME/Library/LaunchAgents/${AGENT_LAB_OLLAMA_LAUNCH_LABEL}.plist}"
  AGENT_LAB_HF_HOME="${AGENT_LAB_HF_HOME:-${HF_HOME:-$HOME/.cache/huggingface}}"
}

agent_lab_backends_require_catalog() {
  agent_lab_backends_init "$@"
  require_command jq
  [[ -r "$AGENT_LAB_BACKENDS_FILE" ]] || die "backend catalog is not readable: $AGENT_LAB_BACKENDS_FILE"
  [[ -r "$AGENT_LAB_MODELS_FILE" ]] || die "model catalog is not readable: $AGENT_LAB_MODELS_FILE"
  jq -e '.backends | type == "array"' "$AGENT_LAB_BACKENDS_FILE" >/dev/null ||
    die "backend catalog is malformed: $AGENT_LAB_BACKENDS_FILE"
}

agent_lab_backend_ids() {
  jq -r '.backends[].id' "$AGENT_LAB_BACKENDS_FILE"
}

agent_lab_backend_exists() {
  local id=$1
  jq -e --arg id "$id" '.backends[] | select(.id == $id)' "$AGENT_LAB_BACKENDS_FILE" >/dev/null
}

agent_lab_backend_json() {
  local id=$1
  jq -ce --arg id "$id" '.backends[] | select(.id == $id)' "$AGENT_LAB_BACKENDS_FILE"
}

agent_lab_backend_field() {
  local id=$1
  local filter=$2
  jq -er --arg id "$id" ".backends[] | select(.id == \$id) | $filter" "$AGENT_LAB_BACKENDS_FILE"
}

agent_lab_backend_host_port() {
  local id=$1
  local bind host port
  bind=$(agent_lab_backend_field "$id" '.bind')
  host=${bind%:*}
  port=${bind##*:}
  printf '%s %s\n' "$host" "$port"
}

agent_lab_backend_health_url() {
  local id=$1
  agent_lab_backend_field "$id" '.health.url'
}

agent_lab_backend_default_alias() {
  local id=$1
  case $id in
    mlx_lm)
      jq -er '.defaults.chat // "qwen-4b"' "$AGENT_LAB_MODELS_FILE"
      ;;
    mlx_vlm)
      jq -er '.defaults.vision // "gemma-12b"' "$AGENT_LAB_MODELS_FILE"
      ;;
    *)
      printf '%s\n' "${AGENT_LAB_BACKEND_MODEL_ALIAS:-}"
      ;;
  esac
}

# Resolve HF snapshot path for an executable backend×alias pin.
agent_lab_backend_mlx_model_path() {
  local backend_id=$1
  local alias=$2
  local artifact revision repo_dir snap
  artifact=$(jq -er --arg alias "$alias" --arg backend "$backend_id" '
    .models[] | select(.alias == $alias and .executable == true)
    | .backends[$backend] | select(.status == "executable")
    | .artifact_id
  ' "$AGENT_LAB_MODELS_FILE") || {
    die "no executable $backend_id pin for alias '$alias'"
    return 1
  }
  revision=$(jq -er --arg alias "$alias" --arg backend "$backend_id" '
    .models[] | select(.alias == $alias and .executable == true)
    | .backends[$backend] | select(.status == "executable")
    | .revision
  ' "$AGENT_LAB_MODELS_FILE") || return 1
  repo_dir=$(printf '%s' "$artifact" | sed 's|/|--|g')
  snap="$AGENT_LAB_HF_HOME/hub/models--${repo_dir}/snapshots/${revision}"
  [[ -d "$snap" ]] || {
    die "missing local HF snapshot for $alias ($backend_id): $snap (install weights while online)"
    return 1
  }
  printf '%s\n' "$snap"
}

agent_lab_mlx_python() {
  local py="$AGENT_LAB_MLX_VENV/bin/python"
  [[ -x "$py" ]] || {
    die "MLX venv python missing: $py (create .agent-lab/venvs/mlx with mlx-lm / mlx-vlm)"
    return 1
  }
  printf '%s\n' "$py"
}

agent_lab_mlx_venv_ready() {
  # Avoid importing MLX (needs Metal); check managed entrypoints only.
  [[ -x "$AGENT_LAB_MLX_VENV/bin/python" ]] || return 1
  [[ -x "$AGENT_LAB_MLX_VENV/bin/mlx_lm.server" ]] || return 1
  [[ -x "$AGENT_LAB_MLX_VENV/bin/mlx_vlm.server" ]] || return 1
}

agent_lab_http_ok() {
  local url=$1
  local timeout=${2:-3}
  command_exists curl || return 1
  curl --silent --fail --max-time "$timeout" "$url" >/dev/null 2>&1
}

agent_lab_port_listening() {
  local host=$1
  local port=$2
  ! port_is_available "$port" "$host"
}

agent_lab_pidfile() {
  local id=$1
  printf '%s/%s.pid\n' "$AGENT_LAB_RUN_DIR" "$id"
}

agent_lab_read_pid() {
  local pidfile
  pidfile=$(agent_lab_pidfile "$1")
  [[ -f "$pidfile" ]] || return 1
  tr -d '[:space:]' <"$pidfile"
}

agent_lab_pid_alive() {
  local pid=$1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

agent_lab_write_pid() {
  local id=$1
  local pid=$2
  mkdir -p "$AGENT_LAB_RUN_DIR"
  printf '%s\n' "$pid" >"$(agent_lab_pidfile "$id")"
}

agent_lab_clear_pid() {
  local id=$1
  rm -f -- "$(agent_lab_pidfile "$id")"
}

# --- Ollama LaunchAgent (same path as scripts/start.sh / stop.sh) ---

agent_lab_ollama_render_plist() {
  local destination=$1
  local escaped_home=${HOME//&/\\&}
  escaped_home=${escaped_home//|/\\|}
  sed "s|__AGENT_LAB_HOME__|$escaped_home|g" "$AGENT_LAB_OLLAMA_PLIST_TEMPLATE" >"$destination"
}

agent_lab_ollama_installed_matches() {
  local expected
  [[ -f "$AGENT_LAB_OLLAMA_INSTALLED_PLIST" ]] || return 1
  expected=$(mktemp "${TMPDIR:-/tmp}/agent-lab-ollama-plist.XXXXXX")
  agent_lab_ollama_render_plist "$expected"
  if cmp -s "$expected" "$AGENT_LAB_OLLAMA_INSTALLED_PLIST"; then
    rm -f -- "$expected"
    return 0
  fi
  rm -f -- "$expected"
  return 1
}

agent_lab_ollama_service_loaded() {
  launchctl print "$AGENT_LAB_OLLAMA_LAUNCH_SERVICE" >/dev/null 2>&1
}

agent_lab_ollama_managed_pid() {
  launchctl print "$AGENT_LAB_OLLAMA_LAUNCH_SERVICE" 2>/dev/null |
    awk '$1 == "pid" && $2 == "=" { gsub(/;/, "", $3); print $3; exit }'
}

agent_lab_probe_ollama() {
  local host port url version expected
  read -r host port <<<"$(agent_lab_backend_host_port ollama)"
  url=$(agent_lab_backend_health_url ollama)
  if ! agent_lab_http_ok "$url" 2; then
    if agent_lab_port_listening "$host" "$port"; then
      printf '%s\n' 'unhealthy'
    elif [[ -f "$AGENT_LAB_OLLAMA_INSTALLED_PLIST" ]] && agent_lab_ollama_service_loaded; then
      printf '%s\n' 'starting'
    else
      printf '%s\n' 'stopped'
    fi
    return 0
  fi
  version=$(curl --silent --fail --max-time 2 "$url" 2>/dev/null | jq -er '.version' 2>/dev/null || true)
  expected=$(jq -r '.components[] | select(.id == "ollama") | .version' "$AGENT_LAB_COMPONENTS_FILE" 2>/dev/null || true)
  if [[ -n "$expected" && -n "$version" && "$version" != "$expected" ]]; then
    printf '%s\n' 'unhealthy'
  else
    printf '%s\n' 'running'
  fi
}

agent_lab_probe_openai_backend() {
  local id=$1
  local host port url
  read -r host port <<<"$(agent_lab_backend_host_port "$id")"
  url=$(agent_lab_backend_health_url "$id")
  if agent_lab_http_ok "$url" 3; then
    printf '%s\n' 'running'
    return 0
  fi
  if agent_lab_port_listening "$host" "$port"; then
    printf '%s\n' 'unhealthy'
    return 0
  fi
  printf '%s\n' 'stopped'
}

agent_lab_llama_cpp_binary() {
  if command_exists llama-server; then
    command -v llama-server
    return 0
  fi
  if command_exists llama-cli; then
    command -v llama-cli
    return 0
  fi
  return 1
}

agent_lab_probe_mlx_lm() {
  local state
  state=$(agent_lab_probe_openai_backend mlx_lm)
  if [[ "$state" == stopped ]] && ! agent_lab_mlx_venv_ready; then
    printf '%s\n' 'missing'
    return 0
  fi
  printf '%s\n' "$state"
}

agent_lab_probe_mlx_vlm() {
  local state
  state=$(agent_lab_probe_openai_backend mlx_vlm)
  if [[ "$state" == stopped ]] && ! agent_lab_mlx_venv_ready; then
    printf '%s\n' 'missing'
    return 0
  fi
  printf '%s\n' "$state"
}

agent_lab_probe_llama_cpp() {
  local state
  if ! agent_lab_llama_cpp_binary >/dev/null; then
    printf '%s\n' 'missing'
    return 0
  fi
  state=$(agent_lab_probe_openai_backend llama_cpp)
  printf '%s\n' "$state"
}

agent_lab_probe_lm_studio() {
  # Detect-only: never report missing for absent app; just running/stopped.
  agent_lab_probe_openai_backend lm_studio
}

agent_lab_backend_probe() {
  local id=$1
  case $id in
    ollama) agent_lab_probe_ollama ;;
    mlx_lm) agent_lab_probe_mlx_lm ;;
    mlx_vlm) agent_lab_probe_mlx_vlm ;;
    llama_cpp) agent_lab_probe_llama_cpp ;;
    lm_studio) agent_lab_probe_lm_studio ;;
    *) die "unknown backend id: $id"; return 1 ;;
  esac
}

agent_lab_backend_readiness() {
  # ready | not-ready | missing | detect-only
  local id=$1
  local state lifecycle
  state=$(agent_lab_backend_probe "$id")
  lifecycle=$(agent_lab_backend_field "$id" '.lifecycle')
  case $state in
    running) printf '%s\n' 'ready' ;;
    missing) printf '%s\n' 'missing' ;;
    *)
      if [[ "$lifecycle" == detect ]]; then
        printf '%s\n' 'detect-only'
      else
        printf '%s\n' 'not-ready'
      fi
      ;;
  esac
}

agent_lab_backend_status_row() {
  local id=$1
  local name lifecycle port bind openai state readiness note
  name=$(agent_lab_backend_field "$id" '.name')
  lifecycle=$(agent_lab_backend_field "$id" '.lifecycle')
  port=$(agent_lab_backend_field "$id" '.port')
  bind=$(agent_lab_backend_field "$id" '.bind')
  openai=$(agent_lab_backend_field "$id" '.openai_base_url')
  state=$(agent_lab_backend_probe "$id")
  readiness=$(agent_lab_backend_readiness "$id")
  note=
  case $id in
    mlx_lm|mlx_vlm)
      if agent_lab_mlx_venv_ready; then
        note="venv=$AGENT_LAB_MLX_VENV"
      else
        note="venv_missing=$AGENT_LAB_MLX_VENV"
      fi
      ;;
    llama_cpp)
      if agent_lab_llama_cpp_binary >/dev/null; then
        note="binary=$(agent_lab_llama_cpp_binary)"
      else
        note='binary=missing; see config/llama.cpp/README.md'
      fi
      ;;
    lm_studio)
      note='detect-only; Agent Lab does not launch LM Studio'
      ;;
    ollama)
      if [[ -f "$AGENT_LAB_OLLAMA_INSTALLED_PLIST" ]]; then
        note='launch_agent=installed'
      else
        note='launch_agent=not_installed'
      fi
      ;;
  esac
  jq -cn \
    --arg id "$id" --arg name "$name" --arg lifecycle "$lifecycle" \
    --argjson port "$port" --arg bind "$bind" --arg openai_base_url "$openai" \
    --arg state "$state" --arg readiness "$readiness" --arg note "$note" \
    '{id:$id,name:$name,lifecycle:$lifecycle,port:$port,bind:$bind,openai_base_url:$openai_base_url,state:$state,readiness:$readiness,note:$note}'
}

agent_lab_backend_status_all_json() {
  local id active default_backend
  local rows='[]'
  default_backend=$(jq -er '.default_backend' "$AGENT_LAB_BACKENDS_FILE")
  active=$(agent_lab_backend_active)
  while IFS= read -r id; do
    rows=$(jq -cn --argjson rows "$rows" --argjson row "$(agent_lab_backend_status_row "$id")" \
      '$rows + [$row]')
  done < <(agent_lab_backend_ids)
  jq -cn \
    --argjson backends "$rows" \
    --arg active_backend "$active" \
    --arg default_backend "$default_backend" \
    '{schema_version:1,active_backend:$active_backend,default_backend:$default_backend,backends:$backends}'
}

agent_lab_backend_active() {
  local file=${AGENT_LAB_ACTIVE_BACKEND_FILE:-}
  local env_val=${AGENT_LAB_INFERENCE_BACKEND:-}
  if [[ -n "$env_val" ]]; then
    printf '%s\n' "$env_val"
    return 0
  fi
  if [[ -n "$file" && -r "$file" ]]; then
    tr -d '[:space:]' <"$file"
    return 0
  fi
  jq -er '.default_backend' "$AGENT_LAB_BACKENDS_FILE" 2>/dev/null || printf '%s\n' ollama
}

agent_lab_backend_use() {
  local id=$1
  local skip_webui=${2:-false}
  agent_lab_backend_exists "$id" || die "unknown backend id: $id"
  mkdir -p "$AGENT_LAB_STATE_DIR"
  printf '%s\n' "$id" >"$AGENT_LAB_ACTIVE_BACKEND_FILE"
  info "recorded active backend '$id' in $AGENT_LAB_ACTIVE_BACKEND_FILE"
  # Client rewiring (WebUI / LLM CLI / Aider) — scripts/lib/inference.sh (P10-T05).
  if declare -F agent_lab_inference_apply >/dev/null 2>&1; then
    agent_lab_inference_apply "$id" "$skip_webui"
  elif [[ -r "${AGENT_LAB_REPO_ROOT:-}/scripts/lib/inference.sh" ]]; then
    # shellcheck source=inference.sh
    . "$AGENT_LAB_REPO_ROOT/scripts/lib/inference.sh"
    agent_lab_inference_apply "$id" "$skip_webui"
  else
    warn "inference apply helpers missing; recorded active backend only"
  fi
}

# Heavy backends that compete for unified memory on 24 GiB hosts.
AGENT_LAB_HEAVY_BACKENDS=${AGENT_LAB_HEAVY_BACKENDS:-ollama mlx_lm mlx_vlm llama_cpp lm_studio}

agent_lab_backend_is_heavy() {
  local id=$1 peer
  for peer in $AGENT_LAB_HEAVY_BACKENDS; do
    [[ "$peer" == "$id" ]] && return 0
  done
  return 1
}

agent_lab_backend_stop_managed_peers() {
  local starting=$1
  local peer state
  for peer in mlx_lm mlx_vlm llama_cpp; do
    [[ "$peer" == "$starting" ]] && continue
    state=$(agent_lab_backend_probe "$peer")
    case $state in
      running|unhealthy|starting)
        warn "single-heavy-server: stopping managed peer '$peer' before starting '$starting'"
        agent_lab_backend_stop "$peer" || warn "failed to stop peer '$peer'"
        ;;
    esac
  done
  for peer in ollama lm_studio; do
    [[ "$peer" == "$starting" ]] && continue
    state=$(agent_lab_backend_probe "$peer")
    if [[ "$state" == running ]]; then
      warn "single-heavy-server: '$peer' is running; stop it before loading a large model on '$starting' (24 GiB hosts)"
    fi
  done
}

agent_lab_backend_wait_health() {
  local id=$1
  local attempts=${2:-60}
  local interval=${3:-0.5}
  local attempt state
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    state=$(agent_lab_backend_probe "$id")
    [[ "$state" == running ]] && return 0
    sleep "$interval"
  done
  die "backend '$id' did not become healthy; inspect $AGENT_LAB_LOG_DIR/${id}.stderr.log"
}

agent_lab_backend_start_ollama() {
  local host port
  read -r host port <<<"$(agent_lab_backend_host_port ollama)"
  require_command launchctl
  require_command curl
  [[ -x "$AGENT_LAB_OLLAMA_BIN" ]] || die "missing pinned Ollama at $AGENT_LAB_OLLAMA_BIN"
  [[ -f "$AGENT_LAB_OLLAMA_INSTALLED_PLIST" ]] ||
    die "Ollama launch agent is not installed; run 'agent-lab start --install-launch-agent'"
  agent_lab_ollama_installed_matches ||
    die "installed Ollama launch agent differs from Agent Lab template; inspect $AGENT_LAB_OLLAMA_INSTALLED_PLIST"

  if [[ "$(agent_lab_probe_ollama)" == running ]]; then
    info "ollama already running at $(agent_lab_backend_health_url ollama)"
    return 0
  fi

  if agent_lab_ollama_service_loaded; then
    launchctl kickstart -k "$AGENT_LAB_OLLAMA_LAUNCH_SERVICE"
  else
    if ! port_is_available "$port" "$host"; then
      die "occupied port: $host:$port; stop the unrelated service before starting ollama"
    fi
    launchctl bootstrap "$AGENT_LAB_OLLAMA_LAUNCH_DOMAIN" "$AGENT_LAB_OLLAMA_INSTALLED_PLIST"
  fi
  agent_lab_backend_wait_health ollama 40 0.25
  info "ollama ready at $(agent_lab_backend_health_url ollama)"
}

agent_lab_backend_stop_ollama() {
  require_command launchctl
  if [[ ! -e "$AGENT_LAB_OLLAMA_INSTALLED_PLIST" ]]; then
    info 'ollama launch agent is not installed; nothing to stop'
    return 0
  fi
  local expected
  expected=$(mktemp "${TMPDIR:-/tmp}/agent-lab-ollama-plist.XXXXXX")
  agent_lab_ollama_render_plist "$expected"
  cmp -s "$expected" "$AGENT_LAB_OLLAMA_INSTALLED_PLIST" || {
    rm -f -- "$expected"
    die "refusing to stop an unverified launch agent at $AGENT_LAB_OLLAMA_INSTALLED_PLIST"
  }
  rm -f -- "$expected"
  if ! agent_lab_ollama_service_loaded; then
    info 'ollama launch agent is already stopped'
    return 0
  fi
  launchctl bootout "$AGENT_LAB_OLLAMA_LAUNCH_SERVICE"
  info 'stopped Agent Lab-managed ollama launch agent'
}

agent_lab_backend_start_mlx() {
  local id=$1
  local wrapper alias model host port py pidfile logfile_out logfile_err
  case $id in
    mlx_lm) wrapper=$AGENT_LAB_MLX_LM_WRAPPER ;;
    mlx_vlm) wrapper=$AGENT_LAB_MLX_VLM_WRAPPER ;;
    *) die "not an mlx backend: $id"; return 1 ;;
  esac
  [[ -x "$wrapper" || -f "$wrapper" ]] || die "missing mlx launch wrapper: $wrapper"
  chmod +x "$wrapper" 2>/dev/null || true
  py=$(agent_lab_mlx_python) || return 1
  alias=${AGENT_LAB_BACKEND_MODEL_ALIAS:-$(agent_lab_backend_default_alias "$id")}
  [[ -n "$alias" ]] || die "no model alias for $id; set AGENT_LAB_BACKEND_MODEL_ALIAS"
  model=$(agent_lab_backend_mlx_model_path "$id" "$alias") || return 1
  read -r host port <<<"$(agent_lab_backend_host_port "$id")"

  if [[ "$(agent_lab_backend_probe "$id")" == running ]]; then
    info "$id already running at $(agent_lab_backend_health_url "$id")"
    return 0
  fi
  if ! port_is_available "$port" "$host"; then
    die "occupied port: $host:$port; stop the conflicting listener before starting $id"
  fi

  mkdir -p "$AGENT_LAB_RUN_DIR" "$AGENT_LAB_LOG_DIR"
  pidfile=$(agent_lab_pidfile "$id")
  logfile_out="$AGENT_LAB_LOG_DIR/${id}.stdout.log"
  logfile_err="$AGENT_LAB_LOG_DIR/${id}.stderr.log"

  info "starting $id with alias=$alias model=$model on $host:$port"
  (
    export AGENT_LAB_MLX_PYTHON="$py"
    export AGENT_LAB_MLX_MODEL="$model"
    export AGENT_LAB_MLX_HOST="$host"
    export AGENT_LAB_MLX_PORT="$port"
    export HF_HUB_OFFLINE=1
    export TRANSFORMERS_OFFLINE=1
    exec "$wrapper"
  ) >>"$logfile_out" 2>>"$logfile_err" &
  agent_lab_write_pid "$id" $!
  agent_lab_backend_wait_health "$id" 240 0.5
  info "$id ready at $(agent_lab_backend_health_url "$id") (pid $(agent_lab_read_pid "$id"))"
}

agent_lab_backend_stop_pid_managed() {
  local id=$1
  local pid host port
  read -r host port <<<"$(agent_lab_backend_host_port "$id")"
  pid=$(agent_lab_read_pid "$id" 2>/dev/null || true)
  if agent_lab_pid_alive "${pid:-}"; then
    info "stopping $id (pid $pid)"
    kill "$pid" 2>/dev/null || true
    local attempt
    for attempt in {1..40}; do
      agent_lab_pid_alive "$pid" || break
      sleep 0.25
    done
    if agent_lab_pid_alive "$pid"; then
      warn "$id did not exit; sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  agent_lab_clear_pid "$id"

  # Also stop any orphan listener we own on the catalog port (best-effort).
  if command_exists lsof && agent_lab_port_listening "$host" "$port"; then
    local orphan
    orphan=$(lsof -nP -t -iTCP@"$host":"$port" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)
    if [[ -n "$orphan" ]]; then
      local cmd
      cmd=$(ps -p "$orphan" -o args= 2>/dev/null || true)
      case $cmd in
        *mlx_lm.server*|*mlx_vlm.server*|*llama-server*|*run-mlx-lm*|*run-mlx-vlm*)
          warn "stopping orphan listener pid $orphan on $host:$port"
          kill "$orphan" 2>/dev/null || true
          sleep 0.5
          kill -9 "$orphan" 2>/dev/null || true
          ;;
      esac
    fi
  fi
  info "$id stopped"
}

agent_lab_backend_start_llama_cpp() {
  local bin host port model
  bin=$(agent_lab_llama_cpp_binary) ||
    die "llama_cpp binary missing; install llama-server or see config/llama.cpp/README.md"
  model=${AGENT_LAB_LLAMA_CPP_MODEL:-}
  [[ -n "$model" && -f "$model" ]] ||
    die "set AGENT_LAB_LLAMA_CPP_MODEL to a local .gguf path before starting llama_cpp"
  read -r host port <<<"$(agent_lab_backend_host_port llama_cpp)"
  if [[ "$(agent_lab_probe_llama_cpp)" == running ]]; then
    info "llama_cpp already running"
    return 0
  fi
  if ! port_is_available "$port" "$host"; then
    die "occupied port: $host:$port"
  fi
  case $(basename "$bin") in
    llama-server) ;;
    *) die "refusing to start with $bin; install llama-server for OpenAI-compatible serve" ;;
  esac
  mkdir -p "$AGENT_LAB_RUN_DIR" "$AGENT_LAB_LOG_DIR"
  info "starting llama_cpp with $model on $host:$port"
  (
    exec "$bin" --host "$host" --port "$port" -m "$model"
  ) >>"$AGENT_LAB_LOG_DIR/llama_cpp.stdout.log" 2>>"$AGENT_LAB_LOG_DIR/llama_cpp.stderr.log" &
  agent_lab_write_pid llama_cpp $!
  agent_lab_backend_wait_health llama_cpp 60 0.5
  info "llama_cpp ready at $(agent_lab_backend_health_url llama_cpp)"
}

agent_lab_backend_start() {
  local id=$1
  local keep_others=${2:-false}
  agent_lab_backend_exists "$id" || die "unknown backend id: $id"
  case $id in
    lm_studio)
      die "lm_studio is detect-only; start the LM Studio app manually, then re-run status"
      ;;
  esac
  if [[ "$keep_others" != true ]] && agent_lab_backend_is_heavy "$id"; then
    agent_lab_backend_stop_managed_peers "$id"
  fi
  case $id in
    ollama) agent_lab_backend_start_ollama ;;
    mlx_lm|mlx_vlm) agent_lab_backend_start_mlx "$id" ;;
    llama_cpp) agent_lab_backend_start_llama_cpp ;;
    *) die "start not implemented for $id" ;;
  esac
}

agent_lab_backend_stop() {
  local id=$1
  agent_lab_backend_exists "$id" || die "unknown backend id: $id"
  case $id in
    ollama) agent_lab_backend_stop_ollama ;;
    mlx_lm|mlx_vlm|llama_cpp) agent_lab_backend_stop_pid_managed "$id" ;;
    lm_studio)
      die "lm_studio is detect-only; quit the LM Studio app manually"
      ;;
    *) die "stop not implemented for $id" ;;
  esac
}

agent_lab_backend_list() {
  local id active
  active=$(agent_lab_backend_active)
  printf '%-12s %-10s %-6s %s\n' 'ID' 'LIFECYCLE' 'PORT' 'NAME'
  while IFS= read -r id; do
    local mark=
    [[ "$id" == "$active" ]] && mark='*'
    printf '%-12s %-10s %-6s %s%s\n' \
      "$id" \
      "$(agent_lab_backend_field "$id" '.lifecycle')" \
      "$(agent_lab_backend_field "$id" '.port')" \
      "$(agent_lab_backend_field "$id" '.name')" \
      "${mark:+ (active)}"
  done < <(agent_lab_backend_ids)
  printf '\nActive backend: %s (backend use applies WebUI / LLM CLI / Aider wiring)\n' "$active"
}

agent_lab_backend_print_status() {
  local filter_id=${1:-}
  local json=${2:-false}
  local report
  report=$(agent_lab_backend_status_all_json)
  if [[ -n "$filter_id" ]]; then
    report=$(jq -ce --arg id "$filter_id" '
      . as $root
      | ($root.backends[] | select(.id == $id)) as $b
      | $root + {backends:[$b]}
    ' <<<"$report") || die "unknown backend id: $filter_id"
  fi
  if [[ "$json" == true ]]; then
    printf '%s\n' "$report"
    return 0
  fi
  jq -r '
    "ACTIVE         \(.active_backend) (default \(.default_backend))",
    (.backends[] |
      "BACKEND        \(.id) state=\(.state) readiness=\(.readiness) port=\(.port) lifecycle=\(.lifecycle)" +
      (if .note != "" then " — " + .note else "" end)
    )
  ' <<<"$report"
}

# Compact JSON array for status.sh / doctor.sh (no start side effects).
agent_lab_backends_summary_json() {
  agent_lab_backends_require_catalog
  agent_lab_backend_status_all_json
}
