#!/usr/bin/env bash
# Multi-backend comparative benchmark for Agent Lab (P10-T06).
# Serializes heavy backends, unloads between alias runs, writes comparable JSON
# plus a short markdown summary under .agent-lab/results/.
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"
# shellcheck source=lib/backends.sh
. "$SCRIPT_DIR/lib/backends.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
agent_lab_backends_init "$SCRIPT_DIR"

readonly MODELS_FILE="${AGENT_LAB_MODELS_FILE:-$REPO_ROOT/config/models.json}"
readonly BACKENDS_FILE="${AGENT_LAB_BACKENDS_FILE:-$REPO_ROOT/config/backends.json}"
readonly COMPONENTS_FILE="${AGENT_LAB_COMPONENTS_FILE:-$REPO_ROOT/config/components.json}"
readonly RESULTS_DIR="${AGENT_LAB_RESULTS_DIR:-$REPO_ROOT/.agent-lab/results}"
readonly VISION_IMAGE="${AGENT_LAB_VISION_IMAGE:-$REPO_ROOT/evals/fixtures/model-qualification/vision-card.svg.png}"
readonly SCHEMA_VERSION=1
readonly DEFAULT_RUNS=3
readonly DEFAULT_PROMPT='Write a concise numbered list of exactly twenty short facts about local-only AI software. Keep each line under twelve words.'
readonly WARMUP_PROMPT='Reply with exactly READY'
readonly VISION_PROMPT='Describe the shape, the exact hex or common color name, and the exact text code on the card. Be brief.'
readonly MAX_TOKENS=256

dry_run=false
smoke=false
skip_start=false
run_count=$DEFAULT_RUNS
backends_filter=
aliases_filter=
compare_path=
output_path=
markdown_path=
pid_file=
partial_file=
interrupt_cleanup_done=false
started_backends=()

usage() {
  cat <<'EOF'
Usage: agent-lab benchmark-backends [options]

Cross-backend matrix: ready/startable backends × executable alias pins ×
fixed prompts (thinking/tools off). Gemma vision is a separate case on
vision-capable backends. One heavy server at a time; unload between runs.

Options:
  --dry-run              Validate catalogs and emit schema-valid stub (no inference)
  --smoke                Tiny live sample: one ready backend, one alias, one timed run
  --runs N               Timed text samples per cell after warm-up (default: 3)
  --backends LIST        Comma-separated backend ids (default: all with executable pins)
  --aliases LIST         Comma-separated role aliases (default: all executable)
  --skip-start           Only measure backends already ready; do not start/stop
  --compare PATH         Refuse compare when digests/revisions or schema mismatch
  --output PATH          Result JSON (default: .agent-lab/results/benchmark-backends-<ts>.json)
  --markdown PATH        Summary markdown (default: same stem as JSON with .md)
  -h, --help             Show this help

Metrics reuse P8 concepts where applicable: cold load, TTFT, decode tok/s,
prompt tok/s, total latency, peak memory, failure rate. Optional switch cost
is recorded when changing backends.
EOF
}

cleanup() {
  local id
  if [[ $interrupt_cleanup_done == true ]]; then
    return 0
  fi
  interrupt_cleanup_done=true
  if [[ -n ${pid_file:-} && -f ${pid_file:-} ]]; then
    rm -f -- "$pid_file"
  fi
  if [[ -n ${partial_file:-} && -f ${partial_file:-} ]]; then
    rm -f -- "$partial_file"
  fi
  # Best-effort: stop backends we started (not Ollama LaunchAgent unless we
  # brought it up in this process — tracked in started_backends).
  if [[ $dry_run == false && $skip_start == false && ${#started_backends[@]} -gt 0 ]]; then
    for id in "${started_backends[@]}"; do
      [[ -n $id ]] || continue
      case $id in
        mlx_lm|mlx_vlm|llama_cpp)
          agent_lab_backend_stop "$id" >/dev/null 2>&1 || true
          ;;
      esac
    done
  fi
}
trap cleanup EXIT HUP INT TERM

median_of() {
  awk '
    NF { a[++n] = $1 + 0 }
    END {
      if (n == 0) { print "null"; exit }
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
      if (n % 2) print a[int((n + 1) / 2)]
      else print (a[n / 2] + a[n / 2 + 1]) / 2
    }'
}

stdev_of() {
  awk '
    NF { a[++n] = $1 + 0; s += $1 }
    END {
      if (n < 2) { print 0; exit }
      m = s / n
      for (i = 1; i <= n; i++) d += (a[i] - m) * (a[i] - m)
      print sqrt(d / (n - 1))
    }'
}

now_iso() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

epoch_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

filter_matrix_json() {
  local matrix=$1
  local filtered=$matrix
  if [[ -n $backends_filter ]]; then
    local jq_backends
    jq_backends=$(printf '%s' "$backends_filter" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s -c .)
    filtered=$(jq -c --argjson want "$jq_backends" '[.[] | select(.backend as $b | $want | index($b))]' <<<"$filtered")
  fi
  if [[ -n $aliases_filter ]]; then
    local jq_aliases
    jq_aliases=$(printf '%s' "$aliases_filter" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R . | jq -s -c .)
    filtered=$(jq -c --argjson want "$jq_aliases" '[.[] | select(.alias as $a | $want | index($a))]' <<<"$filtered")
  fi
  printf '%s\n' "$filtered"
}

memory_snapshot() {
  local backend_id=${1:-}
  local free_pct pressure rss_bytes=0
  free_pct=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2); print $2+0; exit}')
  free_pct=${free_pct:-null}
  pressure=$(memory_pressure 2>/dev/null | awk -F': ' '/Pages free/{print $0; exit}' || true)
  case $backend_id in
    ollama)
      if pgrep -x ollama >/dev/null 2>&1; then
        rss_bytes=$(pgrep -x ollama | while read -r pid; do ps -o rss= -p "$pid"; done | awk '{s+=$1} END{print (s+0)*1024}')
      fi
      ;;
    mlx_lm|mlx_vlm|llama_cpp)
      local pid
      pid=$(agent_lab_read_pid "$backend_id" 2>/dev/null || true)
      if agent_lab_pid_alive "${pid:-}"; then
        rss_bytes=$(ps -o rss= -p "$pid" | awk '{print ($1+0)*1024}')
      fi
      ;;
    lm_studio)
      if pgrep -if 'LM Studio|lms ' >/dev/null 2>&1; then
        rss_bytes=$(pgrep -if 'LM Studio|lms ' | while read -r pid; do ps -o rss= -p "$pid" 2>/dev/null; done | awk '{s+=$1} END{print (s+0)*1024}')
      fi
      ;;
  esac
  rss_bytes=${rss_bytes:-0}
  jq -nc --argjson free "$free_pct" --argjson rss "$rss_bytes" --arg backend "$backend_id" --arg pressure "$pressure" \
    '{backend:$backend,system_memory_free_percent:$free,process_rss_bytes:$rss,memory_pressure_note:$pressure}'
}

pin_fingerprint() {
  # Stable compare key: backend, alias, artifact_id, digest, revision.
  jq -c '
    [.matrix[] | {
      backend, alias, case,
      artifact_id, digest, revision
    }] | sort_by(.backend,.alias,.case)
  ' "$1"
}

validate_result_schema() {
  local path=$1
  jq -e --argjson schema "$SCHEMA_VERSION" '
    .schema_version == $schema
    and (.host | type == "object")
    and (.backends | type == "array")
    and (.matrix | type == "array")
    and (.run | type == "object")
    and (.metrics | type == "object")
    and (.metrics.cells | type == "array")
    and (.summary_markdown_path | type == "string")
  ' "$path" >/dev/null
}

compare_results() {
  local left=$1 right=$2
  validate_result_schema "$left" || die "left result failed schema validation: $left"
  validate_result_schema "$right" || die "right result failed schema validation: $right"
  local left_fp right_fp
  left_fp=$(pin_fingerprint "$left")
  right_fp=$(pin_fingerprint "$right")
  if [[ $left_fp != "$right_fp" ]]; then
    die "refusing to compare mismatched digests/revisions (or matrix membership)"
  fi
  info "digest/revision match; comparison allowed"
  jq -n --slurpfile a "$left" --slurpfile b "$right" \
    '{left:$a[0].run.started_at,right:$b[0].run.started_at,digest_match:true}'
}

build_catalog_matrix_json() {
  # All executable backend×alias cells from catalogs, plus vision rows.
  jq -c '
    [
      .models[]
      | select(.executable == true)
      | . as $m
      | ($m.backends // {})
      | to_entries[]
      | select(.value.status == "executable")
      | {
          backend: .key,
          alias: $m.alias,
          case: "text",
          artifact_id: .value.artifact_id,
          digest: .value.digest,
          revision: .value.revision,
          vision_capable: (
            ($m.capabilities.vision // false)
            and (.key == "ollama" or .key == "mlx_vlm" or .key == "lm_studio" or .key == "llama_cpp")
          )
        }
    ] as $text
    | $text + [
        $text[]
        | select(.vision_capable == true and .alias == "gemma-12b")
        | . + {case: "vision"}
      ]
  ' "$MODELS_FILE"
}

openai_base_url() {
  local id=$1
  agent_lab_backend_field "$id" '.openai_base_url'
}

resolve_openai_model_id() {
  local backend=$1 alias=$2
  case $backend in
    ollama)
      jq -er --arg alias "$alias" '
        .models[] | select(.alias == $alias and .executable == true)
        | .backends.ollama.artifact_id // .tag
      ' "$MODELS_FILE"
      ;;
    mlx_lm|mlx_vlm)
      agent_lab_backend_mlx_model_path "$backend" "$alias"
      ;;
    llama_cpp)
      printf '%s\n' "${AGENT_LAB_LLAMA_CPP_MODEL:-}"
      ;;
    lm_studio)
      jq -er --arg alias "$alias" '
        .models[] | select(.alias == $alias and .executable == true)
        | .backends.lm_studio.artifact_id // empty
      ' "$MODELS_FILE"
      ;;
    *)
      die "no model id resolver for backend $backend"
      ;;
  esac
}

unload_ollama_model() {
  local tag=$1
  local attempt wait
  for attempt in 1 2 3; do
    curl --silent --show-error --fail --max-time 60 \
      -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg model "$tag" '{model:$model,keep_alive:0}')" \
      "http://127.0.0.1:11434/api/generate" >/dev/null 2>&1 || true
    for wait in {1..80}; do
      if [[ $(curl --silent --fail --max-time 2 "http://127.0.0.1:11434/api/ps" 2>/dev/null |
        jq --arg tag "$tag" '[.models[] | select(.name==$tag or .model==$tag)] | length' || printf '0') -eq 0 ]]; then
        return 0
      fi
      sleep 0.25
    done
  done
  warn "timed out unloading ollama model: $tag"
  return 0
}

ensure_backend_for_alias() {
  local backend=$1 alias=$2
  local state
  state=$(agent_lab_backend_probe "$backend")
  if [[ $skip_start == true ]]; then
    [[ $state == running ]] || die "backend '$backend' is not ready and --skip-start was set (state=$state)"
    return 0
  fi
  case $backend in
    ollama)
      if [[ $state != running ]]; then
        agent_lab_backend_start ollama
        started_backends+=("ollama")
      fi
      ;;
    mlx_lm|mlx_vlm)
      # One model per server process — always (re)start with the target alias.
      if [[ $state == running ]]; then
        agent_lab_backend_stop "$backend" || true
      fi
      AGENT_LAB_BACKEND_MODEL_ALIAS=$alias agent_lab_backend_start "$backend"
      started_backends+=("$backend")
      ;;
    llama_cpp)
      [[ -n ${AGENT_LAB_LLAMA_CPP_MODEL:-} && -f ${AGENT_LAB_LLAMA_CPP_MODEL:-} ]] ||
        die "llama_cpp requires AGENT_LAB_LLAMA_CPP_MODEL pointing at a local .gguf"
      if [[ $state == running ]]; then
        agent_lab_backend_stop llama_cpp || true
      fi
      agent_lab_backend_start llama_cpp
      started_backends+=("llama_cpp")
      ;;
    lm_studio)
      [[ $state == running ]] ||
        die "lm_studio is detect-only; start LM Studio manually before benchmarking"
      ;;
    *)
      die "unsupported backend for live benchmark: $backend"
      ;;
  esac
}

stop_backend_if_started() {
  local backend=$1
  [[ $skip_start == true ]] && return 0
  case $backend in
    mlx_lm|mlx_vlm|llama_cpp)
      agent_lab_backend_stop "$backend" || warn "failed to stop $backend after cell"
      ;;
    ollama)
      # Leave LaunchAgent running; unload models instead.
      ;;
  esac
}

stream_openai_metrics() {
  # Args: base_url model_id prompt out_json [image_b64_or_empty]
  local base=$1 model=$2 prompt=$3 out=$4
  local image_b64=${5:-}
  local started total_ms first_ms=-1 success=false
  local tmp body
  tmp=$(mktemp)
  started=$(epoch_ms)

  if [[ -n $image_b64 ]]; then
    body=$(jq -nc \
      --arg model "$model" --arg prompt "$prompt" --arg img "$image_b64" --argjson max "$MAX_TOKENS" \
      '{
        model:$model,
        stream:true,
        stream_options:{include_usage:true},
        temperature:0,
        max_tokens:$max,
        messages:[{
          role:"user",
          content:[
            {type:"text",text:$prompt},
            {type:"image_url",image_url:{url:("data:image/png;base64,"+$img)}}
          ]
        }]
      }')
  else
    body=$(jq -nc \
      --arg model "$model" --arg prompt "$prompt" --argjson max "$MAX_TOKENS" \
      '{
        model:$model,
        stream:true,
        stream_options:{include_usage:true},
        temperature:0,
        max_tokens:$max,
        messages:[{role:"user",content:$prompt}]
      }')
  fi

  if curl --silent --show-error --fail --max-time 300 \
    -H 'Content-Type: application/json' \
    --data "$body" \
    "${base%/}/chat/completions" >"$tmp"; then
    success=true
  fi
  total_ms=$(( $(epoch_ms) - started ))

  local parsed prompt_tokens=0 completion_tokens=0
  if [[ $success == true ]]; then
    parsed=$(python3 - "$tmp" "$started" <<'PY'
import json, sys, time
path, started = sys.argv[1], int(sys.argv[2])
first = None
prompt_tokens = completion_tokens = 0
with open(path, encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        if not line.startswith('data:'):
            # Ollama may also emit NDJSON without SSE prefix on some paths; try JSON.
            if line.startswith('{'):
                payload = line
            else:
                continue
        else:
            payload = line[5:].strip()
        if payload == '[DONE]':
            continue
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue
        usage = obj.get('usage') or {}
        if usage:
            prompt_tokens = int(usage.get('prompt_tokens') or prompt_tokens or 0)
            completion_tokens = int(usage.get('completion_tokens') or completion_tokens or 0)
        choices = obj.get('choices') or []
        if choices:
            delta = choices[0].get('delta') or {}
            content = delta.get('content')
            if content and first is None:
                first = int(time.time() * 1000) - started
            msg = choices[0].get('message') or {}
            if msg.get('content') and first is None:
                first = int(time.time() * 1000) - started
print("%s %s %s" % (first if first is not None else -1, prompt_tokens, completion_tokens))
PY
)
    first_ms=$(awk '{print $1}' <<<"$parsed")
    prompt_tokens=$(awk '{print $2}' <<<"$parsed")
    completion_tokens=$(awk '{print $3}' <<<"$parsed")
  fi
  rm -f -- "$tmp"

  local decode_tps=null prompt_tps=null
  if [[ $success == true && $completion_tokens -gt 0 && $total_ms -gt 0 ]]; then
    if [[ $first_ms -gt 0 && $total_ms -gt $first_ms ]]; then
      decode_tps=$(awk -v c="$completion_tokens" -v ms="$((total_ms - first_ms))" 'BEGIN{printf "%.3f", c / (ms/1000)}')
    else
      decode_tps=$(awk -v c="$completion_tokens" -v ms="$total_ms" 'BEGIN{printf "%.3f", c / (ms/1000)}')
    fi
  fi
  if [[ $success == true && $prompt_tokens -gt 0 && $first_ms -gt 0 ]]; then
    prompt_tps=$(awk -v c="$prompt_tokens" -v ms="$first_ms" 'BEGIN{printf "%.3f", c / (ms/1000)}')
  fi

  jq -nc \
    --argjson success "$success" \
    --argjson ttft_ms "$first_ms" \
    --argjson total_ms "$total_ms" \
    --argjson prompt_tokens "$prompt_tokens" \
    --argjson completion_tokens "$completion_tokens" \
    --argjson decode_tps "${decode_tps:-null}" \
    --argjson prompt_tps "${prompt_tps:-null}" \
    '{
      success:$success,
      ttft_ms:(if $ttft_ms < 0 then null else $ttft_ms end),
      total_latency_ms:$total_ms,
      prompt_tokens:$prompt_tokens,
      completion_tokens:$completion_tokens,
      decode_tokens_per_sec:$decode_tps,
      prompt_tokens_per_sec:$prompt_tps
    }' >"$out"
  [[ $success == true ]]
}

stream_ollama_native_metrics() {
  # Prefer native chat for ollama text (richer token counters); think/tools off.
  local tag=$1 prompt=$2 out=$3
  local started first_ms=-1 total_ms eval_count=0 prompt_eval_count=0 success=false
  local tmp parsed
  tmp=$(mktemp)
  started=$(epoch_ms)
  if curl --silent --show-error --fail --max-time 300 \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg model "$tag" --arg prompt "$prompt" --argjson max "$MAX_TOKENS" \
      '{model:$model,messages:[{role:"user",content:$prompt}],stream:true,think:false,keep_alive:"5m",options:{temperature:0,seed:42,num_ctx:4096,num_predict:$max}}')" \
    "http://127.0.0.1:11434/api/chat" >"$tmp"; then
    success=true
  fi
  total_ms=$(( $(epoch_ms) - started ))
  if [[ $success == true ]]; then
    parsed=$(python3 - "$tmp" "$started" <<'PY'
import json, sys, time
path, started = sys.argv[1], int(sys.argv[2])
first = None
eval_count = prompt_eval = 0
with open(path, encoding='utf-8') as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = obj.get('message') or {}
        if first is None and msg.get('content'):
            first = int(time.time() * 1000) - started
        if obj.get('done'):
            eval_count = int(obj.get('eval_count') or 0)
            prompt_eval = int(obj.get('prompt_eval_count') or 0)
print("%s %s %s" % (first if first is not None else -1, eval_count, prompt_eval))
PY
)
    first_ms=$(awk '{print $1}' <<<"$parsed")
    eval_count=$(awk '{print $2}' <<<"$parsed")
    prompt_eval_count=$(awk '{print $3}' <<<"$parsed")
  fi
  rm -f -- "$tmp"
  local decode_tps=null prompt_tps=null
  if [[ $success == true && $eval_count -gt 0 && $total_ms -gt 0 ]]; then
    if [[ $first_ms -gt 0 && $total_ms -gt $first_ms ]]; then
      decode_tps=$(awk -v c="$eval_count" -v ms="$((total_ms - first_ms))" 'BEGIN{printf "%.3f", c / (ms/1000)}')
    else
      decode_tps=$(awk -v c="$eval_count" -v ms="$total_ms" 'BEGIN{printf "%.3f", c / (ms/1000)}')
    fi
  fi
  if [[ $success == true && $prompt_eval_count -gt 0 && $first_ms -gt 0 ]]; then
    prompt_tps=$(awk -v c="$prompt_eval_count" -v ms="$first_ms" 'BEGIN{printf "%.3f", c / (ms/1000)}')
  fi
  jq -nc \
    --argjson success "$success" \
    --argjson ttft_ms "$first_ms" \
    --argjson total_ms "$total_ms" \
    --argjson prompt_tokens "$prompt_eval_count" \
    --argjson completion_tokens "$eval_count" \
    --argjson decode_tps "${decode_tps:-null}" \
    --argjson prompt_tps "${prompt_tps:-null}" \
    '{
      success:$success,
      ttft_ms:(if $ttft_ms < 0 then null else $ttft_ms end),
      total_latency_ms:$total_ms,
      prompt_tokens:$prompt_tokens,
      completion_tokens:$completion_tokens,
      decode_tokens_per_sec:$decode_tps,
      prompt_tokens_per_sec:$prompt_tps
    }' >"$out"
  [[ $success == true ]]
}

run_one_request() {
  local backend=$1 model_id=$2 prompt=$3 out=$4 case_name=$5
  if [[ $case_name == vision ]]; then
    local b64
    b64=$(base64 <"$VISION_IMAGE" | tr -d '\n')
    stream_openai_metrics "$(openai_base_url "$backend")" "$model_id" "$prompt" "$out" "$b64"
    return $?
  fi
  if [[ $backend == ollama ]]; then
    stream_ollama_native_metrics "$model_id" "$prompt" "$out"
    return $?
  fi
  stream_openai_metrics "$(openai_base_url "$backend")" "$model_id" "$prompt" "$out"
}

summarize_samples() {
  local samples_json=$1
  local n failures ttft_med total_med decode_med prompt_med
  local ttft_sd total_sd decode_sd prompt_sd
  n=$(jq 'length' <<<"$samples_json")
  failures=$(jq '[.[] | select(.success|not)] | length' <<<"$samples_json")
  ttft_med=$(jq -r '.[].ttft_ms // empty' <<<"$samples_json" | median_of)
  total_med=$(jq -r '.[].total_latency_ms // empty' <<<"$samples_json" | median_of)
  decode_med=$(jq -r '.[].decode_tokens_per_sec // empty' <<<"$samples_json" | median_of)
  prompt_med=$(jq -r '.[].prompt_tokens_per_sec // empty' <<<"$samples_json" | median_of)
  ttft_sd=$(jq -r '.[].ttft_ms // empty' <<<"$samples_json" | stdev_of)
  total_sd=$(jq -r '.[].total_latency_ms // empty' <<<"$samples_json" | stdev_of)
  decode_sd=$(jq -r '.[].decode_tokens_per_sec // empty' <<<"$samples_json" | stdev_of)
  prompt_sd=$(jq -r '.[].prompt_tokens_per_sec // empty' <<<"$samples_json" | stdev_of)
  jq -nc \
    --argjson n "$n" --argjson failures "$failures" \
    --argjson ttft_med "${ttft_med:-null}" --argjson total_med "${total_med:-null}" \
    --argjson decode_med "${decode_med:-null}" --argjson prompt_med "${prompt_med:-null}" \
    --argjson ttft_sd "${ttft_sd:-null}" --argjson total_sd "${total_sd:-null}" \
    --argjson decode_sd "${decode_sd:-null}" --argjson prompt_sd "${prompt_sd:-null}" \
    --argjson samples "$samples_json" \
    '{
      sample_count:$n,
      failure_count:$failures,
      failure_rate:(if $n==0 then null else ($failures/$n) end),
      ttft_ms:{median:$ttft_med,stdev:$ttft_sd},
      total_latency_ms:{median:$total_med,stdev:$total_sd},
      decode_tokens_per_sec:{median:$decode_med,stdev:$decode_sd},
      prompt_tokens_per_sec:{median:$prompt_med,stdev:$prompt_sd},
      samples:$samples
    }'
}

write_markdown_summary() {
  local json_path=$1 md_path=$2
  python3 - "$json_path" "$md_path" <<'PY'
import json, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(src.read_text(encoding='utf-8'))
lines = []
lines.append('# Multi-backend benchmark summary')
lines.append('')
lines.append(f"- Schema: `{data.get('schema_version')}`")
lines.append(f"- Started: `{data.get('run', {}).get('started_at')}`")
lines.append(f"- Ended: `{data.get('run', {}).get('ended_at')}`")
lines.append(f"- Dry-run: `{data.get('dry_run')}`")
lines.append(f"- JSON: `{src}`")
lines.append('')
lines.append('| Backend | Alias | Case | Cold TTFT ms | Decode tok/s | Prompt tok/s | Total ms | Fail rate | Peak RSS MiB |')
lines.append('| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |')
for cell in data.get('metrics', {}).get('cells', []):
    timed = cell.get('timed') or {}
    cold = cell.get('cold_load') or {}
    peak = cell.get('peak_process_rss_bytes') or 0
    peak_mib = round(peak / (1024 * 1024), 1) if peak else ''
    def med(block, key):
        b = block.get(key) or {}
        v = b.get('median')
        return '' if v is None else v
    lines.append(
        '| {backend} | {alias} | {case} | {cold} | {decode} | {prompt} | {total} | {fail} | {peak} |'.format(
            backend=cell.get('backend'),
            alias=cell.get('alias'),
            case=cell.get('case'),
            cold=cold.get('ttft_ms') if cold.get('ttft_ms') is not None else '',
            decode=med(timed, 'decode_tokens_per_sec'),
            prompt=med(timed, 'prompt_tokens_per_sec'),
            total=med(timed, 'total_latency_ms'),
            fail=timed.get('failure_rate') if timed.get('failure_rate') is not None else '',
            peak=peak_mib,
        )
    )
switches = data.get('metrics', {}).get('backend_switches') or []
if switches:
    lines.append('')
    lines.append('## Backend switch cost')
    lines.append('')
    for sw in switches:
        lines.append(
            f"- `{sw.get('from')}` → `{sw.get('to')}`: {sw.get('switch_plus_first_token_ms')} ms"
        )
lines.append('')
lines.append('Thinking and tools were disabled for fair text comparison. Vision is a separate gemma case on capable backends.')
dst.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=true; shift ;;
    --smoke) smoke=true; shift ;;
    --skip-start) skip_start=true; shift ;;
    --runs)
      [[ $# -ge 2 ]] || die '--runs requires a positive integer'
      run_count=$2
      [[ $run_count =~ ^[1-9][0-9]*$ ]] || die '--runs must be a positive integer'
      shift 2
      ;;
    --backends)
      [[ $# -ge 2 ]] || die '--backends requires a comma-separated list'
      backends_filter=$2
      shift 2
      ;;
    --aliases)
      [[ $# -ge 2 ]] || die '--aliases requires a comma-separated list'
      aliases_filter=$2
      shift 2
      ;;
    --compare)
      [[ $# -ge 2 ]] || die '--compare requires a path'
      compare_path=$2
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die '--output requires a path'
      output_path=$2
      shift 2
      ;;
    --markdown)
      [[ $# -ge 2 ]] || die '--markdown requires a path'
      markdown_path=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command jq
require_command curl
require_command python3
require_command base64
[[ -r $MODELS_FILE ]] || die "models catalog missing: $MODELS_FILE"
[[ -r $BACKENDS_FILE ]] || die "backends catalog missing: $BACKENDS_FILE"
[[ -r $COMPONENTS_FILE ]] || die "components catalog missing: $COMPONENTS_FILE"
[[ -r $VISION_IMAGE ]] || die "vision fixture missing: $VISION_IMAGE"

agent_lab_backends_require_catalog "$SCRIPT_DIR"

mkdir -p "$RESULTS_DIR"
timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
output_path=${output_path:-$RESULTS_DIR/benchmark-backends-${timestamp}.json}
if [[ -z $markdown_path ]]; then
  if [[ $output_path == *.json ]]; then
    markdown_path=${output_path%.json}.md
  else
    markdown_path=${output_path}.md
  fi
fi
partial_file="${output_path}.partial"
pid_file="$RESULTS_DIR/benchmark-backends.pid"
printf '%s\n' "$$" >"$pid_file"

if [[ -n $compare_path ]]; then
  [[ -r $compare_path ]] || die "compare target is not readable: $compare_path"
fi

host_json=$(jq -nc \
  --arg brand "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf unknown)" \
  --argjson mem "$(sysctl -n hw.memsize 2>/dev/null || printf 0)" \
  --arg os "$(sw_vers -productVersion 2>/dev/null || printf unknown)" \
  --arg arch "$(uname -m)" \
  '{cpu:$brand,memory_bytes:$mem,macos:$os,arch:$arch}')
profile=$(agent_lab_active_profile 2>/dev/null || printf '%s' "${AGENT_LAB_PROFILE:-unknown}")
prompt_bytes=$(printf '%s' "$DEFAULT_PROMPT" | wc -c | tr -d ' ')

backends_meta=$(jq -c '[.backends[] | {id,name,lifecycle,port,openai_base_url,health}]' "$BACKENDS_FILE")
matrix_json=$(build_catalog_matrix_json)
matrix_json=$(filter_matrix_json "$matrix_json")

if [[ $smoke == true ]]; then
  # Prefer ollama+qwen-4b text when present; else first text cell.
  smoke_cell=$(jq -c '
    (map(select(.backend=="ollama" and .alias=="qwen-4b" and .case=="text")) | .[0])
    // (map(select(.case=="text")) | .[0])
    // .[0]
  ' <<<"$matrix_json")
  [[ $smoke_cell != null && $smoke_cell != "" ]] || die 'smoke mode: no matrix cells available'
  matrix_json=$(jq -nc --argjson c "$smoke_cell" '[$c]')
  run_count=1
fi

[[ $(jq 'length' <<<"$matrix_json") -gt 0 ]] || die 'matrix is empty after filters'

if [[ $dry_run == true ]]; then
  started_at=$(now_iso)
  jq -nc \
    --argjson schema "$SCHEMA_VERSION" \
    --argjson host "$host_json" \
    --arg profile "$profile" \
    --argjson backends "$backends_meta" \
    --argjson matrix "$matrix_json" \
    --argjson runs "$run_count" \
    --argjson prompt_bytes "$prompt_bytes" \
    --arg started "$started_at" \
    --arg md "$markdown_path" \
    --argjson smoke "$smoke" \
    '{
      schema_version:$schema,
      dry_run:true,
      host:$host,
      profile:$profile,
      backends:$backends,
      matrix:$matrix,
      run:{
        started_at:$started,
        ended_at:$started,
        run_count:$runs,
        prompt_bytes:$prompt_bytes,
        max_output_tokens:256,
        thinking:false,
        tools:false,
        serialized_backends:true,
        smoke:$smoke
      },
      metrics:{cells:[],backend_switches:[],peak_process_rss_bytes:0,min_system_memory_free_percent:null},
      summary_markdown_path:$md,
      notes:"dry-run only; no inference performed"
    }' >"$partial_file"
  validate_result_schema "$partial_file"
  mv "$partial_file" "$output_path"
  partial_file=
  write_markdown_summary "$output_path" "$markdown_path"
  if [[ -n $compare_path ]]; then
    compare_results "$output_path" "$compare_path"
  fi
  printf 'PASS: benchmark-backends dry-run wrote %s and %s\n' "$output_path" "$markdown_path"
  exit 0
fi

# Live path.
started_at=$(now_iso)
cells='[]'
switches='[]'
peak_rss=0
min_free=100
failures_total=0
requests_total=0
prev_backend=

# Group by backend for serialization.
backend_order=$(jq -r '[.[].backend] | unique | .[]' <<<"$matrix_json")

while IFS= read -r backend; do
  [[ -n $backend ]] || continue
  readiness=$(agent_lab_backend_readiness "$backend" 2>/dev/null || printf 'not-ready')
  # Skip missing binaries / detect-only peers that are not running unless filtered explicitly.
  if [[ $skip_start == true ]]; then
    state=$(agent_lab_backend_probe "$backend")
    if [[ $state != running ]]; then
      warn "skipping backend $backend (not ready; state=$state readiness=$readiness)"
      continue
    fi
  else
    case $backend in
      lm_studio)
        state=$(agent_lab_backend_probe lm_studio)
        if [[ $state != running ]]; then
          warn "skipping lm_studio (detect-only and not running)"
          continue
        fi
        ;;
      llama_cpp)
        if ! agent_lab_llama_cpp_binary >/dev/null; then
          warn 'skipping llama_cpp (binary missing)'
          continue
        fi
        if [[ -z ${AGENT_LAB_LLAMA_CPP_MODEL:-} || ! -f ${AGENT_LAB_LLAMA_CPP_MODEL:-} ]]; then
          warn 'skipping llama_cpp (AGENT_LAB_LLAMA_CPP_MODEL not set)'
          continue
        fi
        ;;
      mlx_lm|mlx_vlm)
        if ! agent_lab_mlx_venv_ready; then
          warn "skipping $backend (MLX venv not ready)"
          continue
        fi
        ;;
      ollama) ;;
      *)
        warn "skipping unknown/unhandled backend $backend"
        continue
        ;;
    esac
  fi

  if [[ -n $prev_backend && $prev_backend != "$backend" ]]; then
    stop_backend_if_started "$prev_backend"
  fi

  cells_for_backend=$(jq -c --arg b "$backend" '[.[] | select(.backend==$b)]' <<<"$matrix_json")
  while IFS= read -r cell; do
    [[ -n $cell ]] || continue
    alias=$(jq -r '.alias' <<<"$cell")
    case_name=$(jq -r '.case' <<<"$cell")

    info "benchmark-backends: $backend / $alias / $case_name"
    ensure_backend_for_alias "$backend" "$alias"

    model_id=$(resolve_openai_model_id "$backend" "$alias")
    [[ -n $model_id ]] || die "could not resolve model id for $backend/$alias"

    if [[ $backend == ollama ]]; then
      unload_ollama_model "$model_id"
    fi

    # Optional switch cost: first successful request after backend change.
    if [[ -n $prev_backend && $prev_backend != "$backend" ]]; then
      switch_out=$(mktemp)
      switch_started=$(epoch_ms)
      if run_one_request "$backend" "$model_id" "$WARMUP_PROMPT" "$switch_out" text; then
        :
      else
        failures_total=$((failures_total + 1))
      fi
      requests_total=$((requests_total + 1))
      switch_ms=$(( $(epoch_ms) - switch_started ))
      switches=$(jq -c --arg from "$prev_backend" --arg to "$backend" --argjson ms "$switch_ms" \
        '. + [{from:$from,to:$to,switch_plus_first_token_ms:$ms}]' <<<"$switches")
      rm -f -- "$switch_out"
    fi

    mem_before=$(memory_snapshot "$backend")
    cold_out=$(mktemp)
    if [[ $case_name == vision ]]; then
      run_one_request "$backend" "$model_id" "$VISION_PROMPT" "$cold_out" vision || failures_total=$((failures_total + 1))
    else
      run_one_request "$backend" "$model_id" "$WARMUP_PROMPT" "$cold_out" text || failures_total=$((failures_total + 1))
    fi
    requests_total=$((requests_total + 1))
    cold_json=$(cat "$cold_out")
    rm -f -- "$cold_out"
    mem_after_cold=$(memory_snapshot "$backend")

    # Discarded warm-up for text cells (vision uses cold as the load).
    if [[ $case_name == text ]]; then
      warm_out=$(mktemp)
      run_one_request "$backend" "$model_id" "$WARMUP_PROMPT" "$warm_out" text || true
      requests_total=$((requests_total + 1))
      rm -f -- "$warm_out"
    fi

    samples='[]'
    cell_peak=0
    n=1
    while [[ $n -le $run_count ]]; do
      sample_out=$(mktemp)
      mem_mid=$(memory_snapshot "$backend")
      rss=$(jq -r '.process_rss_bytes // 0' <<<"$mem_mid")
      free=$(jq -r '.system_memory_free_percent // 100' <<<"$mem_mid")
      if [[ $rss -gt $peak_rss ]]; then peak_rss=$rss; fi
      if [[ $rss -gt $cell_peak ]]; then cell_peak=$rss; fi
      awk -v f="$free" -v m="$min_free" 'BEGIN{exit !(f < m)}' && min_free=$free

      prompt=$DEFAULT_PROMPT
      [[ $case_name == vision ]] && prompt=$VISION_PROMPT
      if run_one_request "$backend" "$model_id" "$prompt" "$sample_out" "$case_name"; then
        sample=$(cat "$sample_out")
      else
        failures_total=$((failures_total + 1))
        sample=$(jq -nc '{success:false,ttft_ms:null,total_latency_ms:null,prompt_tokens:0,completion_tokens:0,decode_tokens_per_sec:null,prompt_tokens_per_sec:null}')
      fi
      requests_total=$((requests_total + 1))
      samples=$(jq -c --argjson s "$sample" --argjson mem "$mem_mid" '. + [$s + {memory:$mem}]' <<<"$samples")
      rm -f -- "$sample_out"
      n=$((n + 1))
    done

    timed=$(summarize_samples "$samples")
    cells=$(jq -c \
      --argjson cell "$cell" \
      --argjson cold "$cold_json" \
      --argjson before "$mem_before" \
      --argjson after "$mem_after_cold" \
      --argjson timed "$timed" \
      --argjson peak "$cell_peak" \
      --arg model_id "$model_id" \
      '. + [$cell + {
        model_id:$model_id,
        cold_load:$cold,
        memory_before:$before,
        memory_after_cold:$after,
        timed:$timed,
        peak_process_rss_bytes:$peak
      }]' <<<"$cells")

    if [[ $backend == ollama ]]; then
      unload_ollama_model "$model_id"
    fi
  done < <(jq -c '.[]' <<<"$cells_for_backend")

  prev_backend=$backend
done <<<"$backend_order"

# Final unload/stop of last managed backend we may have started.
if [[ -n $prev_backend ]]; then
  if [[ $prev_backend == ollama ]]; then
    while IFS= read -r tag; do
      [[ -n $tag ]] || continue
      unload_ollama_model "$tag"
    done < <(jq -r '.models[] | select(.executable==true) | .backends.ollama.artifact_id // .tag' "$MODELS_FILE")
  else
    stop_backend_if_started "$prev_backend"
  fi
fi

ended_at=$(now_iso)
jq -nc \
  --argjson schema "$SCHEMA_VERSION" \
  --argjson host "$host_json" \
  --arg profile "$profile" \
  --argjson backends "$backends_meta" \
  --argjson matrix "$matrix_json" \
  --argjson runs "$run_count" \
  --argjson prompt_bytes "$prompt_bytes" \
  --arg started "$started_at" \
  --arg ended "$ended_at" \
  --arg md "$markdown_path" \
  --argjson smoke "$smoke" \
  --argjson cells "$cells" \
  --argjson switches "$switches" \
  --argjson peak_rss "$peak_rss" \
  --argjson min_free "$min_free" \
  --argjson failures "$failures_total" \
  --argjson requests "$requests_total" \
  '{
    schema_version:$schema,
    dry_run:false,
    host:$host,
    profile:$profile,
    backends:$backends,
    matrix:$matrix,
    run:{
      started_at:$started,
      ended_at:$ended,
      run_count:$runs,
      prompt_bytes:$prompt_bytes,
      max_output_tokens:256,
      thinking:false,
      tools:false,
      serialized_backends:true,
      smoke:$smoke,
      requests_total:$requests,
      failures_total:$failures
    },
    metrics:{
      cells:$cells,
      backend_switches:$switches,
      peak_process_rss_bytes:$peak_rss,
      min_system_memory_free_percent:$min_free
    },
    summary_markdown_path:$md,
    notes:"Comparable cross-backend cells; refuse --compare across mismatched digests/revisions"
  }' >"$partial_file"

validate_result_schema "$partial_file"
mv "$partial_file" "$output_path"
partial_file=
rm -f -- "$pid_file"
pid_file=
write_markdown_summary "$output_path" "$markdown_path"

if [[ -n $compare_path ]]; then
  compare_results "$output_path" "$compare_path"
fi

printf 'PASS: benchmark-backends wrote %s and %s (failures=%s requests=%s)\n' \
  "$output_path" "$markdown_path" "$failures_total" "$requests_total"
