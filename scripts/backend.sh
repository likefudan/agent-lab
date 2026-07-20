#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/backends.sh
. "$SCRIPT_DIR/lib/backends.sh"
# shellcheck source=lib/inference.sh
. "$SCRIPT_DIR/lib/inference.sh"

readonly EX_USAGE=64

usage() {
  cat <<'EOF'
Usage:
  agent-lab backend list
  agent-lab backend status [BACKEND_ID] [--json]
  agent-lab backend start BACKEND_ID [--keep-others] [--model-alias ALIAS]
  agent-lab backend stop BACKEND_ID
  agent-lab backend use BACKEND_ID [--skip-webui]

Manage or detect OpenAI-compatible inference backends from config/backends.json.

  ollama     LaunchAgent-managed (same path as agent-lab start/stop)
  mlx_lm     Managed mlx_lm.server on catalog port (default 11435)
  mlx_vlm    Managed mlx_vlm.server on catalog port (default 11436)
  llama_cpp  Optional; missing until llama-server + GGUF are present
  lm_studio  Detect-only (do not start/stop via Agent Lab)

Starting a heavy managed backend stops other managed mlx_*/llama_cpp peers by
default (24 GiB single-heavy-server guidance). Pass --keep-others to skip.

`backend use` records the active backend and runs apply-inference (Compose env,
LLM CLI, Aider, and Open WebUI provider wiring). Default active backend is
ollama. Non-Ollama paths use OpenAI /v1 only (no Ollama fallback).

Environment:
  AGENT_LAB_BACKEND_MODEL_ALIAS   Override default alias for mlx_* start
  AGENT_LAB_LLAMA_CPP_MODEL       Local .gguf path for llama_cpp start
  AGENT_LAB_INFERENCE_BACKEND     Overrides recorded active backend when set
  AGENT_LAB_MLX_VENV              MLX venv path (default .agent-lab/venvs/mlx)
  AGENT_LAB_INFERENCE_APPLY_WEBUI auto|never (default auto)
EOF
}

fail_usage() {
  printf 'agent-lab backend: %s\n\n' "$1" >&2
  usage >&2
  exit "$EX_USAGE"
}

agent_lab_backends_require_catalog "$SCRIPT_DIR"

if [[ $# -eq 0 ]]; then
  fail_usage 'missing subcommand'
fi

subcommand=$1
shift

case $subcommand in
  -h|--help|help)
    usage
    exit 0
    ;;
  list)
    [[ $# -eq 0 ]] || fail_usage 'list accepts no arguments'
    agent_lab_backend_list
    ;;
  status)
    json=false
    filter_id=
    while [[ $# -gt 0 ]]; do
      case $1 in
        --json) json=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) fail_usage "unknown status option: $1" ;;
        *)
          [[ -z "$filter_id" ]] || fail_usage 'status accepts at most one backend id'
          filter_id=$1
          shift
          ;;
      esac
    done
    agent_lab_backend_print_status "$filter_id" "$json"
    ;;
  start)
    keep_others=false
    model_alias=
    backend_id=
    while [[ $# -gt 0 ]]; do
      case $1 in
        --keep-others) keep_others=true; shift ;;
        --model-alias)
          [[ $# -ge 2 ]] || fail_usage '--model-alias requires a value'
          model_alias=$2
          shift 2
          ;;
        -h|--help) usage; exit 0 ;;
        -*) fail_usage "unknown start option: $1" ;;
        *)
          [[ -z "$backend_id" ]] || fail_usage 'start accepts one backend id'
          backend_id=$1
          shift
          ;;
      esac
    done
    [[ -n "$backend_id" ]] || fail_usage 'start requires a backend id'
    if [[ -n "$model_alias" ]]; then
      export AGENT_LAB_BACKEND_MODEL_ALIAS="$model_alias"
    fi
    agent_lab_backend_start "$backend_id" "$keep_others"
    ;;
  stop)
    [[ $# -eq 1 ]] || fail_usage 'stop requires exactly one backend id'
    case $1 in
      -h|--help) usage; exit 0 ;;
    esac
    agent_lab_backend_stop "$1"
    ;;
  use)
    backend_id=
    skip_webui=false
    while [[ $# -gt 0 ]]; do
      case $1 in
        --skip-webui) skip_webui=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) fail_usage "unknown use option: $1" ;;
        *)
          [[ -z "$backend_id" ]] || fail_usage 'use accepts one backend id'
          backend_id=$1
          shift
          ;;
      esac
    done
    [[ -n "$backend_id" ]] || fail_usage 'use requires exactly one backend id'
    agent_lab_backend_use "$backend_id" "$skip_webui"
    ;;
  *)
    fail_usage "unknown subcommand: $subcommand"
    ;;
esac
