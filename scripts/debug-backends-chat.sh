#!/usr/bin/env bash
# Same-prompt compare across inference backends (debug companion to
# debug-webui-chat / benchmark-backends). Default prompt: 世界杯是什么？
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/backends.sh
source "${ROOT}/scripts/lib/backends.sh"

readonly RESULTS_DIR="${ROOT}/.agent-lab/results"
readonly DEFAULT_PROMPT='世界杯是什么？'
readonly MODELS_FILE="${ROOT}/config/models.json"

usage() {
  cat <<'EOF'
Usage: agent-lab debug-backends-chat [options]

Ask one prompt on each ready/startable backend×alias cell. Thinking off.
Writes JSON + markdown under .agent-lab/results/.

Options:
  --prompt TEXT          User message (default: 世界杯是什么？)
  --backends LIST        Comma-separated (default: ollama,mlx_lm,mlx_vlm)
  --aliases LIST         Comma-separated (default: qwen-4b,qwen-9b,gemma-12b)
  --max-tokens N         Completion budget (default: 256)
  --runs N               Timed samples after warm-up (default: 1)
  --skip-start           Only measure backends already ready
  --keep-ollama          Do not stop Ollama while measuring MLX (less fair on 24 GiB)
  --output PATH          Result JSON
  --markdown PATH        Summary markdown
  -h, --help             Show this help

Examples:
  bin/agent-lab debug-backends-chat
  bin/agent-lab debug-backends-chat --backends ollama,mlx_lm --aliases qwen-4b --runs 2
EOF
}

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

info() { printf 'INFO: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

prompt=$DEFAULT_PROMPT
backends_csv='ollama,mlx_lm,mlx_vlm'
aliases_csv='qwen-4b,qwen-9b,gemma-12b'
max_tokens=256
runs=1
skip_start=false
keep_ollama=false
output=''
markdown=''
ollama_was_stopped=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --prompt) prompt=$2; shift 2 ;;
    --backends) backends_csv=$2; shift 2 ;;
    --aliases) aliases_csv=$2; shift 2 ;;
    --max-tokens) max_tokens=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --skip-start) skip_start=true; shift ;;
    --keep-ollama) keep_ollama=true; shift ;;
    --output) output=$2; shift 2 ;;
    --markdown) markdown=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$runs" =~ ^[1-9][0-9]*$ ]] || die '--runs must be a positive integer'
[[ "$max_tokens" =~ ^[1-9][0-9]*$ ]] || die '--max-tokens must be a positive integer'
require_command curl jq python3
agent_lab_backends_require_catalog "$ROOT"

mkdir -p "$RESULTS_DIR"
ts=$(date -u +%Y%m%dT%H%M%SZ)
[[ -n $output ]] || output="${RESULTS_DIR}/debug-backends-chat-${ts}.json"
[[ -n $markdown ]] || markdown="${output%.json}.md"
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-debug-backends.XXXXXX")

cleanup() {
  local b
  for b in mlx_lm mlx_vlm; do
    if [[ $(agent_lab_backend_probe "$b" 2>/dev/null || printf 'stopped') == running ]]; then
      agent_lab_backend_stop "$b" >/dev/null 2>&1 || true
    fi
  done
  if [[ $ollama_was_stopped == true ]]; then
    info 'restarting ollama after MLX cells'
    agent_lab_backend_start ollama >/dev/null 2>&1 || warn 'failed to restart ollama'
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

pin_ok() {
  local backend=$1 alias=$2
  jq -e --arg b "$backend" --arg a "$alias" '
    .models[] | select(.alias == $a and .executable == true)
    | .backends[$b] | select(.status == "executable")
  ' "$MODELS_FILE" >/dev/null 2>&1
}

resolve_model_id() {
  local backend=$1 alias=$2
  case $backend in
    ollama)
      jq -er --arg a "$alias" '
        .models[] | select(.alias == $a and .executable == true)
        | .backends.ollama.artifact_id // .tag
      ' "$MODELS_FILE"
      ;;
    mlx_lm|mlx_vlm)
      agent_lab_backend_mlx_model_path "$backend" "$alias"
      ;;
    *)
      die "no model resolver for $backend"
      ;;
  esac
}

openai_base() {
  agent_lab_backend_field "$1" '.openai_base_url'
}

ensure_cell() {
  local backend=$1 alias=$2
  local state
  state=$(agent_lab_backend_probe "$backend")
  if [[ $skip_start == true ]]; then
    [[ $state == running ]] || die "backend '$backend' not ready and --skip-start set"
    return 0
  fi
  case $backend in
    ollama)
      if [[ $state != running ]]; then
        agent_lab_backend_start ollama
      fi
      ;;
    mlx_lm|mlx_vlm)
      if [[ $keep_ollama != true ]]; then
        if [[ $(agent_lab_backend_probe ollama) == running ]]; then
          info 'stopping ollama for fair MLX memory (use --keep-ollama to skip)'
          agent_lab_backend_stop ollama
          ollama_was_stopped=true
        fi
      fi
      if [[ $state == running ]]; then
        agent_lab_backend_stop "$backend" || true
      fi
      AGENT_LAB_BACKEND_MODEL_ALIAS=$alias agent_lab_backend_start "$backend"
      ;;
    *)
      die "cannot start backend $backend"
      ;;
  esac
}

unload_ollama() {
  local tag=$1
  curl --silent --show-error --fail --max-time 60 \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg model "$tag" '{model:$model,keep_alive:0}')" \
    "http://127.0.0.1:11434/api/generate" >/dev/null 2>&1 || true
}

chat_openai() {
  local label=$1 base=$2 model=$3 out=$4
  local body tmp started ended http_code
  tmp=$(mktemp "${work}/req.XXXXXX")
  body=$(jq -nc \
    --arg model "$model" --arg prompt "$prompt" --argjson max "$max_tokens" \
    '{
      model:$model,
      stream:false,
      temperature:0,
      max_tokens:$max,
      messages:[{role:"user",content:$prompt}]
    }')
  started=$(now_ms)
  http_code=$(curl --silent --show-error --output "$tmp" --write-out '%{http_code}' \
    --max-time 600 -H 'Content-Type: application/json' --data "$body" \
    "${base%/}/chat/completions") || true
  ended=$(now_ms)
  python3 - "$tmp" "$label" "$((ended - started))" "$http_code" "$out" <<'PY'
import json, sys
path, label, wall_ms, http_code, out = sys.argv[1:6]
wall_ms, http_code = int(wall_ms), int(http_code)
raw = open(path, encoding="utf-8").read()
if http_code != 200:
    open(out, "w", encoding="utf-8").write(json.dumps({
        "label": label, "ok": False, "http_code": http_code,
        "wall_ms": wall_ms, "error": raw[:2000],
    }, ensure_ascii=False) + "\n")
    raise SystemExit(1)
obj = json.loads(raw)
choices = obj.get("choices") or []
msg = (choices[0].get("message") if choices else {}) or {}
content = msg.get("content") or ""
usage = obj.get("usage") or {}
prompt_tokens = int(usage.get("prompt_tokens") or 0)
completion_tokens = int(usage.get("completion_tokens") or 0)
decode_tps = round(completion_tokens / (wall_ms / 1000), 3) if completion_tokens and wall_ms else None
open(out, "w", encoding="utf-8").write(json.dumps({
    "label": label,
    "ok": True,
    "http_code": 200,
    "wall_ms": wall_ms,
    "content": content,
    "content_chars": len(content),
    "prompt_tokens": prompt_tokens,
    "completion_tokens": completion_tokens,
    "decode_tok_s": decode_tps,
    "decode_tok_s_wall": decode_tps,
    "finish_reason": choices[0].get("finish_reason") if choices else None,
}, ensure_ascii=False, indent=2) + "\n")
PY
}

chat_ollama_native() {
  local label=$1 tag=$2 out=$3
  local body tmp started ended http_code
  tmp=$(mktemp "${work}/req.XXXXXX")
  body=$(jq -nc \
    --arg model "$tag" --arg prompt "$prompt" --argjson max "$max_tokens" \
    '{
      model:$model,
      stream:false,
      think:false,
      keep_alive:"5m",
      messages:[{role:"user",content:$prompt}],
      options:{temperature:0,num_ctx:4096,num_predict:$max}
    }')
  started=$(now_ms)
  http_code=$(curl --silent --show-error --output "$tmp" --write-out '%{http_code}' \
    --max-time 600 -H 'Content-Type: application/json' --data "$body" \
    "http://127.0.0.1:11434/api/chat") || true
  ended=$(now_ms)
  python3 - "$tmp" "$label" "$((ended - started))" "$http_code" "$out" <<'PY'
import json, sys
path, label, wall_ms, http_code, out = sys.argv[1:6]
wall_ms, http_code = int(wall_ms), int(http_code)
raw = open(path, encoding="utf-8").read()
if http_code != 200:
    open(out, "w", encoding="utf-8").write(json.dumps({
        "label": label, "ok": False, "http_code": http_code,
        "wall_ms": wall_ms, "error": raw[:2000],
    }, ensure_ascii=False) + "\n")
    raise SystemExit(1)
obj = json.loads(raw)
msg = obj.get("message") or {}
content = msg.get("content") or ""
eval_count = int(obj.get("eval_count") or 0)
prompt_eval_count = int(obj.get("prompt_eval_count") or 0)
eval_ns = int(obj.get("eval_duration") or 0)
prompt_ns = int(obj.get("prompt_eval_duration") or 0)
decode_tps = round(eval_count / (eval_ns / 1e9), 3) if eval_count and eval_ns else None
prompt_tps = round(prompt_eval_count / (prompt_ns / 1e9), 3) if prompt_eval_count and prompt_ns else None
open(out, "w", encoding="utf-8").write(json.dumps({
    "label": label,
    "ok": True,
    "http_code": 200,
    "wall_ms": wall_ms,
    "content": content,
    "content_chars": len(content),
    "prompt_tokens": prompt_eval_count,
    "completion_tokens": eval_count,
    "decode_tok_s": decode_tps,
    "prompt_tok_s": prompt_tps,
    "decode_tok_s_wall": round(eval_count / (wall_ms / 1000), 3) if eval_count and wall_ms else None,
    "done_reason": obj.get("done_reason"),
}, ensure_ascii=False, indent=2) + "\n")
PY
}

IFS=',' read -r -a backends <<<"$backends_csv"
IFS=',' read -r -a aliases <<<"$aliases_csv"

samples='[]'
cells_planned=0
cells_run=0

info "prompt=${prompt}"
info "backends=${backends_csv} aliases=${aliases_csv} max_tokens=${max_tokens} runs=${runs}"

for backend in "${backends[@]}"; do
  backend=$(printf '%s' "$backend" | tr -d '[:space:]')
  [[ -n $backend ]] || continue
  for alias in "${aliases[@]}"; do
    alias=$(printf '%s' "$alias" | tr -d '[:space:]')
    [[ -n $alias ]] || continue
    if ! pin_ok "$backend" "$alias"; then
      info "skip ${backend}/${alias} (no executable pin)"
      continue
    fi
    cells_planned=$((cells_planned + 1))
    model_id=$(resolve_model_id "$backend" "$alias") || die "resolve failed for $backend/$alias"
    info "=== ${backend} / ${alias} ==="
    ensure_cell "$backend" "$alias"

    # Warm-up
    warm="${work}/warm-${backend}-${alias}.json"
    if [[ $backend == ollama ]]; then
      chat_ollama_native "warmup" "$model_id" "$warm" || die "warmup failed for $backend/$alias"
    else
      chat_openai "warmup" "$(openai_base "$backend")" "$model_id" "$warm" ||
        die "warmup failed for $backend/$alias: $(cat "$warm")"
    fi
    info "warmup wall_ms=$(jq -r '.wall_ms' "$warm") decode=$(jq -r '.decode_tok_s // .decode_tok_s_wall // "n/a"' "$warm")"

    run_i=1
    while [[ $run_i -le $runs ]]; do
      out="${work}/${backend}-${alias}-${run_i}.json"
      if [[ $backend == ollama ]]; then
        chat_ollama_native "${backend}/${alias}/run-${run_i}" "$model_id" "$out" ||
          die "run failed: $backend/$alias #$run_i"
      else
        chat_openai "${backend}/${alias}/run-${run_i}" "$(openai_base "$backend")" "$model_id" "$out" ||
          die "run failed: $backend/$alias #$run_i: $(cat "$out")"
      fi
      samples=$(jq -c --slurpfile s "$out" \
        --arg backend "$backend" --arg alias "$alias" --arg model "$model_id" \
        '. + [($s[0] + {backend:$backend, alias:$alias, model_id:$model})]' <<<"$samples")
      info "run ${run_i} wall_ms=$(jq -r '.wall_ms' "$out") decode=$(jq -r '.decode_tok_s // .decode_tok_s_wall // "n/a"' "$out") chars=$(jq -r '.content_chars' "$out")"
      run_i=$((run_i + 1))
    done
    cells_run=$((cells_run + 1))

    if [[ $backend == ollama ]]; then
      unload_ollama "$model_id"
    elif [[ $backend == mlx_lm || $backend == mlx_vlm ]]; then
      agent_lab_backend_stop "$backend" || true
    fi
  done
done

jq -nc \
  --arg started_at "$ts" \
  --arg prompt "$prompt" \
  --arg backends "$backends_csv" \
  --arg aliases "$aliases_csv" \
  --argjson max_tokens "$max_tokens" \
  --argjson runs "$runs" \
  --argjson cells_planned "$cells_planned" \
  --argjson cells_run "$cells_run" \
  --argjson keep_ollama "$keep_ollama" \
  --argjson samples "$samples" \
  --arg markdown_path "$markdown" \
  '{
    schema_version: 1,
    kind: "debug-backends-chat",
    started_at: $started_at,
    prompt: $prompt,
    backends: $backends,
    aliases: $aliases,
    max_tokens: $max_tokens,
    runs: $runs,
    keep_ollama: $keep_ollama,
    cells_planned: $cells_planned,
    cells_run: $cells_run,
    thinking: "off",
    samples: $samples,
    summary_markdown_path: $markdown_path,
    notes: [
      "Ollama uses native /api/chat (think:false). MLX uses OpenAI /v1/chat/completions.",
      "decode_tok_s is Ollama eval_duration-based; decode_tok_s_wall is completion_tokens/wall_ms (MLX and cross-check).",
      "lm_studio / llama_cpp skipped unless listed and installed."
    ]
  }' >"$output"

{
  printf '# Backend chat compare — same prompt\n\n'
  printf -- '- Started: `%s`\n' "$ts"
  printf -- '- Prompt: %s\n' "$prompt"
  printf -- '- max_tokens: `%s` · runs: `%s` · thinking: off\n' "$max_tokens" "$runs"
  printf -- '- Cells: %s / %s\n' "$cells_run" "$cells_planned"
  printf -- '- JSON: `%s`\n\n' "$output"
  printf '| Backend | Alias | Wall ms | Decode tok/s | Wall tok/s | Tokens | Chars |\n'
  printf '| --- | --- | ---: | ---: | ---: | ---: | ---: |\n'
  jq -r '
    .samples[] |
    [
      .backend,
      .alias,
      (.wall_ms // ""),
      (.decode_tok_s // ""),
      (.decode_tok_s_wall // ""),
      (.completion_tokens // ""),
      (.content_chars // "")
    ] | @tsv
  ' "$output" | while IFS=$'\t' read -r b a wall decode wall_tps toks chars; do
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$b" "$a" "$wall" "$decode" "$wall_tps" "$toks" "$chars"
  done
  printf '\n## Reply snippets\n\n'
  jq -r '
    .samples[] |
    "### \(.backend) / \(.alias)\n\n```\n\(.content[0:400] // "")\n```\n"
  ' "$output"
} >"$markdown"

printf 'PASS: wrote %s and %s (%s cells)\n' "$output" "$markdown" "$cells_run"
