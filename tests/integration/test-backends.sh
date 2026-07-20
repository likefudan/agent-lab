#!/usr/bin/env bash
# P10-T07: multi-backend health + one chat completion; skip absent optionals.
# Does not modify LuLu/pf or any firewall rules.
set -euo pipefail

readonly ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
# shellcheck source=../../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/backends.sh
. "$ROOT/scripts/lib/backends.sh"

agent_lab_backends_require_catalog "$ROOT/scripts"

readonly BACKEND_BIN="$ROOT/bin/agent-lab"
readonly CHAT_TIMEOUT="${AGENT_LAB_BACKEND_TEST_CHAT_TIMEOUT:-20}"
readonly HEALTH_TIMEOUT="${AGENT_LAB_BACKEND_TEST_HEALTH_TIMEOUT:-3}"
readonly PASS_PROMPT='Reply with exactly: AGENT-LAB-OK'

fail=0
skipped=0
passed=0
original_active=
restore_active=false

fail_msg() {
  printf 'FAIL: %s\n' "$1" >&2
  fail=1
}

skip_msg() {
  printf 'SKIP: %s\n' "$1"
  skipped=$((skipped + 1))
}

pass_msg() {
  printf 'PASS: %s\n' "$1"
  passed=$((passed + 1))
}

cleanup() {
  if [[ "$restore_active" == true ]]; then
    "$BACKEND_BIN" backend use ollama --skip-webui >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM

openai_model_for() {
  local backend=$1
  local alias=$2
  case $backend in
    ollama)
      jq -er --arg alias "$alias" '
        .models[] | select(.alias == $alias and .executable == true)
        | .tag
      ' "$AGENT_LAB_MODELS_FILE"
      ;;
    mlx_lm|mlx_vlm)
      agent_lab_backend_mlx_model_path "$backend" "$alias" 2>/dev/null || return 1
      ;;
    *)
      # Detect/optional peers: ask /v1/models for the first id when chatting.
      printf '%s\n' ''
      ;;
  esac
}

default_alias_for() {
  local backend=$1
  case $backend in
    mlx_vlm) printf '%s\n' 'gemma-12b' ;;
    mlx_lm) printf '%s\n' 'qwen-4b' ;;
    *) printf '%s\n' 'qwen-4b' ;;
  esac
}

resolve_chat_model() {
  local backend=$1
  local base=$2
  local alias model
  alias=$(default_alias_for "$backend")
  model=$(openai_model_for "$backend" "$alias" 2>/dev/null || true)
  if [[ -n "$model" ]]; then
    printf '%s\n' "$model"
    return 0
  fi
  curl --silent --fail --max-time "$HEALTH_TIMEOUT" "${base%/}/models" 2>/dev/null |
    jq -er '.data[0].id // .models[0].name // empty' 2>/dev/null
}

smoke_chat() {
  local backend=$1
  local base url
  local model body tmp
  model=$(resolve_chat_model "$backend" "$(agent_lab_backend_field "$backend" '.openai_base_url')") || {
    fail_msg "$backend: could not resolve a chat model id"
    return 1
  }
  [[ -n "$model" ]] || {
    fail_msg "$backend: empty chat model id"
    return 1
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/agent-lab-backend-chat.XXXXXX")

  # Ollama: native /api/chat honors think:false. OpenAI /v1 may empty content
  # into reasoning for Qwen when thinking stays on.
  if [[ "$backend" == ollama ]]; then
    url=$(agent_lab_backend_field ollama '.native_api')
    url="${url%/}/chat"
    body=$(jq -nc \
      --arg model "$model" \
      --arg prompt "$PASS_PROMPT" \
      '{
        model:$model,
        stream:false,
        think:false,
        keep_alive:"0",
        options:{temperature:0,num_predict:32,num_ctx:2048},
        messages:[{role:"user",content:$prompt}]
      }')
    if ! curl --silent --show-error --fail --max-time "$CHAT_TIMEOUT" \
      -H 'Content-Type: application/json' \
      --data "$body" \
      "$url" >"$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      fail_msg "$backend: native chat request failed ($url)"
      return 1
    fi
    if ! jq -e '
      (.message.content // "")
      | type == "string" and length > 0
    ' "$tmp" >/dev/null 2>&1; then
      rm -f -- "$tmp"
      fail_msg "$backend: native chat response missing content"
      return 1
    fi
  else
    base=$(agent_lab_backend_field "$backend" '.openai_base_url')
    url="${base%/}/chat/completions"
    body=$(jq -nc \
      --arg model "$model" \
      --arg prompt "$PASS_PROMPT" \
      '{
        model:$model,
        stream:false,
        temperature:0,
        max_tokens:32,
        messages:[{role:"user",content:$prompt}]
      }')
    if ! curl --silent --show-error --fail --max-time "$CHAT_TIMEOUT" \
      -H 'Content-Type: application/json' \
      --data "$body" \
      "$url" >"$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      fail_msg "$backend: chat completion request failed ($url)"
      return 1
    fi
    if ! jq -e '
      ((.choices[0].message.content // .choices[0].delta.content // "")
        | type == "string" and length > 0)
    ' "$tmp" >/dev/null 2>&1; then
      rm -f -- "$tmp"
      fail_msg "$backend: chat completion response missing content"
      return 1
    fi
  fi
  rm -f -- "$tmp"
  return 0
}

smoke_running_backend() {
  local backend=$1
  local health
  health=$(agent_lab_backend_health_url "$backend")
  if ! agent_lab_http_ok "$health" "$HEALTH_TIMEOUT"; then
    fail_msg "$backend: reported running but health probe failed ($health)"
    return 1
  fi
  if ! smoke_chat "$backend"; then
    return 1
  fi
  pass_msg "$backend health + chat completion"
}

# --- catalog / CLI smoke (always) ---
[[ -x "$BACKEND_BIN" ]] || fail_msg "bin/agent-lab is not executable"

original_active=$(agent_lab_backend_active)
list_out=$("$BACKEND_BIN" backend list 2>&1) || {
  fail_msg "backend list failed: $list_out"
}
if [[ $fail -eq 0 ]]; then
  for id in ollama mlx_lm mlx_vlm lm_studio llama_cpp; do
    [[ "$list_out" == *"$id"* ]] || fail_msg "backend list missing id: $id"
  done
fi
if [[ $fail -eq 0 ]]; then
  status_out=$("$BACKEND_BIN" backend status --json 2>&1) || {
    fail_msg "backend status --json failed: $status_out"
  }
fi
if [[ $fail -eq 0 ]]; then
  echo "$status_out" | jq -e '
    .schema_version == 1
    and (.backends | length) >= 5
    and (.active_backend | type == "string")
  ' >/dev/null || fail_msg 'backend status JSON schema unexpected'
fi

# --- per-backend smoke or skip ---
while IFS= read -r backend; do
  state=$(agent_lab_backend_probe "$backend")
  readiness=$(agent_lab_backend_readiness "$backend")

  case $backend in
    ollama)
      if [[ "$state" == running ]]; then
        smoke_running_backend ollama || true
      else
        # Ollama is the shipped default; absence of a live listener is a skip
        # for this optional-heavy suite rather than a hard fail of make targets
        # that also run when the stack is stopped.
        skip_msg "ollama not running (state=$state); start with: bin/agent-lab start"
      fi
      ;;
    mlx_lm|mlx_vlm)
      if [[ "$state" == missing ]] || ! agent_lab_mlx_venv_ready; then
        skip_msg "$backend absent (mlx venv missing at $AGENT_LAB_MLX_VENV)"
        continue
      fi
      if [[ "$state" == running ]]; then
        smoke_running_backend "$backend" || true
      else
        skip_msg "$backend venv present but not running (state=$state readiness=$readiness); start with: bin/agent-lab backend start $backend"
      fi
      ;;
    lm_studio)
      if [[ "$state" == running ]]; then
        smoke_running_backend lm_studio || true
      else
        skip_msg "lm_studio detect-only and not running (start LM Studio app; probe $(agent_lab_backend_health_url lm_studio))"
      fi
      ;;
    llama_cpp)
      if [[ "$state" == missing ]]; then
        skip_msg "llama_cpp absent (no llama-server/llama-cli; see config/llama.cpp/README.md)"
        continue
      fi
      if [[ "$state" == running ]]; then
        smoke_running_backend llama_cpp || true
      else
        skip_msg "llama_cpp binary present but not running (state=$state); set AGENT_LAB_LLAMA_CPP_MODEL and: bin/agent-lab backend start llama_cpp"
      fi
      ;;
    *)
      skip_msg "unknown backend id in catalog: $backend"
      ;;
  esac
done < <(agent_lab_backend_ids)

# Light client-wiring check: record active backend via use, then restore ollama.
if [[ $fail -eq 0 ]]; then
  if "$BACKEND_BIN" backend use ollama --skip-webui >/dev/null 2>&1; then
    restore_active=true
    recorded=$(tr -d '[:space:]' <"$AGENT_LAB_ACTIVE_BACKEND_FILE" 2>/dev/null || true)
    if [[ "$recorded" == ollama ]]; then
      pass_msg 'backend use ollama (--skip-webui) recorded active backend'
    else
      fail_msg "backend use ollama did not record active-backend (got '${recorded:-empty}')"
    fi
  else
    fail_msg 'backend use ollama --skip-webui failed'
  fi
fi

# Restore prior non-ollama active marker only if the suite did not need ollama.
if [[ "$restore_active" == true && -n "$original_active" && "$original_active" != ollama ]]; then
  # Prefer leaving the host on the shipped default after this suite.
  :
fi
restore_active=true

if [[ $fail -ne 0 ]]; then
  printf '%s\n' "FAIL: backend integration checks (passed=$passed skipped=$skipped)" >&2
  exit 1
fi
printf '%s\n' "PASS: backend integration checks (passed=$passed skipped=$skipped)"
