#!/usr/bin/env bash
# Launch mlx_vlm.server on loopback. Intended for Agent Lab-managed lifecycle.
# Required env: AGENT_LAB_MLX_PYTHON, AGENT_LAB_MLX_MODEL, AGENT_LAB_MLX_HOST,
# AGENT_LAB_MLX_PORT. Optional: AGENT_LAB_MLX_EXTRA_ARGS (shell-split).
set -euo pipefail

: "${AGENT_LAB_MLX_PYTHON:?AGENT_LAB_MLX_PYTHON is required}"
: "${AGENT_LAB_MLX_MODEL:?AGENT_LAB_MLX_MODEL is required}"
: "${AGENT_LAB_MLX_HOST:?AGENT_LAB_MLX_HOST is required}"
: "${AGENT_LAB_MLX_PORT:?AGENT_LAB_MLX_PORT is required}"

export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"

cmd=(
  "$AGENT_LAB_MLX_PYTHON" -m mlx_vlm.server
  --model "$AGENT_LAB_MLX_MODEL"
  --host "$AGENT_LAB_MLX_HOST"
  --port "$AGENT_LAB_MLX_PORT"
)
if [[ -n "${AGENT_LAB_MLX_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  cmd+=(${AGENT_LAB_MLX_EXTRA_ARGS})
fi

exec "${cmd[@]}"
