#!/usr/bin/env bash
# Run the pinned LLM CLI against Agent Lab's active-backend runtime
# (.agent-lab/llm/). Prefer this over bare `llm` so aliases and OLLAMA_HOST /
# OpenAI base URL match `agent-lab apply-inference`.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/backends.sh
source "${ROOT}/scripts/lib/backends.sh"
# shellcheck source=lib/inference.sh
source "${ROOT}/scripts/lib/inference.sh"

readonly DEFAULT_LLM_BIN="${HOME}/.local/bin/llm"
readonly LLM_BIN="${AGENT_LAB_LLM_BIN:-$DEFAULT_LLM_BIN}"
readonly RUNTIME="${ROOT}/.agent-lab/llm"

usage() {
  cat <<'EOF'
Usage: agent-lab llm [llm-args...]

Wraps the pinned Simonw LLM CLI (llm==0.31.1 + llm-ollama) with
LLM_USER_PATH=.agent-lab/llm and the active-backend environment from
apply-inference.

Examples:
  bin/agent-lab apply-inference          # refresh runtime if needed
  bin/agent-lab llm models
  bin/agent-lab llm -m qwen-4b -o think false -o num_predict 256 '世界杯是什么？'
  bin/agent-lab llm -m qwen-9b chat -o think false
  bin/agent-lab llm -m gemma-12b -o think false 'Describe this image' -a photo.png

Install (once), from docs/installation.md:
  uv tool install --from 'llm==0.31.1' llm --with 'llm-ollama==0.16.1'

Aliases: qwen-4b, qwen-9b, gemma-12b (see .agent-lab/llm/aliases.json).
Pass remaining flags through to upstream `llm` unchanged.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  usage
  exit 0
fi

if [[ ! -x "$LLM_BIN" ]]; then
  die "pinned LLM CLI missing at $LLM_BIN
Install with:
  uv tool install --from 'llm==0.31.1' llm --with 'llm-ollama==0.16.1'
Or set AGENT_LAB_LLM_BIN to that executable."
fi

agent_lab_backends_require_catalog "$ROOT"
agent_lab_inference_init "$ROOT"

if [[ ! -f "$RUNTIME/environment.env" || ! -f "$RUNTIME/aliases.json" ]]; then
  info 'LLM runtime missing; running apply-inference --skip-webui'
  agent_lab_inference_apply "$(agent_lab_backend_active)" true
fi

export LLM_USER_PATH="$RUNTIME"
# shellcheck disable=SC1091
set -a
# shellcheck source=/dev/null
source "$RUNTIME/environment.env"
set +a

exec "$LLM_BIN" "$@"
