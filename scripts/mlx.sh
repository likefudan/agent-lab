#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

readonly ROOT="$(repository_root "$SCRIPT_DIR")"
readonly RUNTIME="$ROOT/.agent-lab/mlx"
readonly VENV="$RUNTIME/venv"
readonly REQUIREMENTS="$ROOT/config/mlx/requirements.txt"
readonly MODEL_TOOL="$ROOT/scripts/mlx-models.py"
readonly LAUNCH_DOMAIN="gui/$(id -u)"
readonly CHAT_LABEL='ai.agent-lab.mlx-lm'
readonly VISION_LABEL='ai.agent-lab.mlx-vlm'
readonly CHAT_SERVICE="$LAUNCH_DOMAIN/$CHAT_LABEL"
readonly VISION_SERVICE="$LAUNCH_DOMAIN/$VISION_LABEL"
readonly CHAT_URL='http://127.0.0.1:8081/v1/models'
readonly VISION_URL='http://127.0.0.1:8082/health'

usage() {
  cat <<'EOF'
Usage: agent-lab mlx COMMAND [arguments]

Commands:
  setup                         Install the pinned MLX Python environment
  models list                   List pinned MLX model snapshots
  models verify [ALIAS]         Verify complete snapshots and file digests
  models download ALIAS         Download and verify one pinned snapshot
  start chat|vision             Start one backend and stop the other
  stop [chat|vision|all]        Stop managed MLX backends (default: all)
  status                        Show backend and model state
  health                        Check the active backend
  logs chat|vision              Tail the selected backend log

Only one large MLX backend is kept active at a time on the 24 GB target host.
EOF
}

service_loaded() {
  launchctl print "$1" >/dev/null 2>&1
}

stop_service() {
  local service=$1
  if service_loaded "$service"; then
    launchctl bootout "$service"
  fi
}

require_runtime() {
  [[ -x "$VENV/bin/mlx_lm.server" && -x "$VENV/bin/mlx_vlm.server" ]] ||
    die "MLX runtime is not installed; run 'agent-lab mlx setup'" || return 1
}

escape_sed() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

render_plist() {
  local backend=$1 model_path=$2 template destination escaped_root escaped_home escaped_model
  template="$ROOT/config/mlx/ai.agent-lab.mlx-$backend.plist.template"
  destination="$RUNTIME/ai.agent-lab.mlx-$backend.plist"
  escaped_root=$(escape_sed "$ROOT")
  escaped_home=$(escape_sed "$HOME")
  escaped_model=$(escape_sed "$model_path")
  sed -e "s|__AGENT_LAB_ROOT__|$escaped_root|g" \
      -e "s|__AGENT_LAB_HOME__|$escaped_home|g" \
      -e "s|__MODEL_PATH__|$escaped_model|g" \
      "$template" >"$destination"
  plutil -lint "$destination" >/dev/null
  printf '%s\n' "$destination"
}

wait_for_url() {
  local url=$1 log_file=$2 attempt
  for attempt in {1..120}; do
    if curl --silent --show-error --fail --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  tail -n 80 "$log_file" >&2 || true
  die "MLX backend did not become healthy at $url"
}

setup_runtime() {
  require_command uv
  mkdir -p "$RUNTIME/logs"
  if [[ ! -x "$VENV/bin/python" ]]; then
    uv venv --python 3.12 "$VENV"
  fi
  uv pip install --python "$VENV/bin/python" -r "$REQUIREMENTS"
  "$VENV/bin/python" - <<'PY'
from importlib.metadata import version
expected = {"mlx-lm": "0.31.3", "mlx-vlm": "0.6.6", "huggingface-hub": "1.24.0"}
for package, wanted in expected.items():
    actual = version(package)
    if actual != wanted:
        raise SystemExit(f"{package}: expected {wanted}, got {actual}")
print("PASS: pinned MLX runtime installed")
PY
}

model_alias_for_backend() {
  case $1 in
    lm) printf '%s\n' 'qwen-9b-mlx' ;;
    vlm) printf '%s\n' 'gemma-12b-mlx' ;;
    *) return 1 ;;
  esac
}

start_backend() {
  local backend=$1 alias model_path plist service other_service url log_file port
  require_runtime
  mkdir -p "$RUNTIME/logs"
  if [[ "$backend" == lm ]]; then
    service=$CHAT_SERVICE
    other_service=$VISION_SERVICE
    url=$CHAT_URL
    log_file="$RUNTIME/logs/mlx-lm.stderr.log"
    port=8081
  else
    service=$VISION_SERVICE
    other_service=$CHAT_SERVICE
    url=$VISION_URL
    log_file="$RUNTIME/logs/mlx-vlm.stderr.log"
    port=8082
  fi
  alias=$(model_alias_for_backend "$backend")
  "$VENV/bin/python" "$MODEL_TOOL" verify --quick "$alias" >/dev/null
  model_path=$("$VENV/bin/python" "$MODEL_TOOL" path "$alias")

  stop_service "$other_service"
  if service_loaded "$service"; then
    if curl --silent --fail --max-time 2 "$url" >/dev/null 2>&1; then
      info "$alias is already running at $url"
      return 0
    fi
    stop_service "$service"
  elif ! port_is_available "$port" 127.0.0.1; then
    die "occupied MLX port: 127.0.0.1:$port"
  fi

  plist=$(render_plist "$backend" "$model_path")
  launchctl bootstrap "$LAUNCH_DOMAIN" "$plist"
  wait_for_url "$url" "$log_file"
  info "started $alias at $url"
}

show_status() {
  require_runtime
  "$VENV/bin/python" "$MODEL_TOOL" list
  printf '\nBACKEND\tSTATE\tENDPOINT\n'
  printf 'chat\t%s\thttp://127.0.0.1:8081/v1\n' "$(service_loaded "$CHAT_SERVICE" && printf running || printf stopped)"
  printf 'vision\t%s\thttp://127.0.0.1:8082/v1\n' "$(service_loaded "$VISION_SERVICE" && printf running || printf stopped)"
}

[[ $# -gt 0 ]] || { usage >&2; exit 64; }
command_name=$1
shift

case "$command_name" in
  setup)
    [[ $# -eq 0 ]] || { usage >&2; exit 64; }
    setup_runtime
    ;;
  models)
    require_runtime
    [[ $# -gt 0 ]] || { usage >&2; exit 64; }
    model_command=$1
    shift
    case "$model_command" in
      list)
        [[ $# -eq 0 ]] || { usage >&2; exit 64; }
        "$VENV/bin/python" "$MODEL_TOOL" list
        ;;
      verify)
        [[ $# -le 1 ]] || { usage >&2; exit 64; }
        if [[ $# -eq 1 ]]; then
          "$VENV/bin/python" "$MODEL_TOOL" verify "$1"
        else
          "$VENV/bin/python" "$MODEL_TOOL" verify
        fi
        ;;
      download)
        [[ $# -eq 1 ]] || { usage >&2; exit 64; }
        active_profile=${AGENT_LAB_PROFILE:-$(agent_lab_active_profile 2>/dev/null || true)}
        [[ "$active_profile" != offline && "${AGENT_LAB_OFFLINE:-0}" != 1 ]] ||
          die 'MLX model downloads are prohibited by the offline profile'
        "$VENV/bin/python" "$MODEL_TOOL" download "$1"
        ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  start)
    [[ $# -eq 1 ]] || { usage >&2; exit 64; }
    case $1 in
      chat) start_backend lm ;;
      vision) start_backend vlm ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  stop)
    [[ $# -le 1 ]] || { usage >&2; exit 64; }
    case ${1:-all} in
      chat) stop_service "$CHAT_SERVICE" ;;
      vision) stop_service "$VISION_SERVICE" ;;
      all) stop_service "$CHAT_SERVICE"; stop_service "$VISION_SERVICE" ;;
      *) usage >&2; exit 64 ;;
    esac
    info 'stopped requested MLX backend service(s)'
    ;;
  status)
    [[ $# -eq 0 ]] || { usage >&2; exit 64; }
    show_status
    ;;
  health)
    [[ $# -eq 0 ]] || { usage >&2; exit 64; }
    if service_loaded "$CHAT_SERVICE"; then
      curl --silent --show-error --fail --max-time 5 "$CHAT_URL" >/dev/null
      info 'MLX-LM chat backend is healthy'
    elif service_loaded "$VISION_SERVICE"; then
      curl --silent --show-error --fail --max-time 5 "$VISION_URL" >/dev/null
      info 'MLX-VLM vision backend is healthy'
    else
      die "no MLX backend is active; run 'agent-lab mlx start chat' or 'agent-lab mlx start vision'"
    fi
    ;;
  logs)
    [[ $# -eq 1 ]] || { usage >&2; exit 64; }
    case $1 in
      chat) tail -n 100 "$RUNTIME/logs/mlx-lm.stderr.log" ;;
      vision) tail -n 100 "$RUNTIME/logs/mlx-vlm.stderr.log" ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 64 ;;
esac
