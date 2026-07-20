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
  agent-lab apply-inference [BACKEND_ID] [--skip-webui]

Rewrite day-to-day client wiring for the active (or named) inference backend:
  - ~/.agent-lab/state/inference.env   (Compose + AGENT_LAB_INFERENCE_BACKEND)
  - .agent-lab/llm/                    (LLM CLI runtime)
  - .agent-lab/aider/                  (Aider runtime)
  - Open WebUI Ollama/OpenAI providers (API update when WebUI is healthy)

Default backend remains ollama until decision 0013. Non-Ollama backends use the
OpenAI-compatible /v1 base URL only and do not fall back through Ollama.

Environment:
  AGENT_LAB_INFERENCE_APPLY_WEBUI   auto|never (default auto)
  AGENT_LAB_INFERENCE_BACKEND       overrides recorded active backend
EOF
}

fail_usage() {
  printf 'agent-lab apply-inference: %s\n\n' "$1" >&2
  usage >&2
  exit "$EX_USAGE"
}

agent_lab_backends_require_catalog "$SCRIPT_DIR"
agent_lab_inference_init "$SCRIPT_DIR"

backend_id=
skip_webui=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help|help) usage; exit 0 ;;
    --skip-webui) skip_webui=true; shift ;;
    -*) fail_usage "unknown option: $1" ;;
    *)
      [[ -z "$backend_id" ]] || fail_usage 'accepts at most one backend id'
      backend_id=$1
      shift
      ;;
  esac
done

agent_lab_inference_apply "${backend_id}" "$skip_webui"
info "active inference entry: $(agent_lab_backend_active) → $(jq -er '.openai_base_url' <<<"$(agent_lab_inference_resolve "$(agent_lab_backend_active)")")"
