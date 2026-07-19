#!/usr/bin/env bash
# Native hardware benchmark for Agent Lab approved Ollama models.
# Writes ignored results under .agent-lab/results/. Local loopback only.
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/profile.sh
. "$SCRIPT_DIR/lib/profile.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
readonly MODELS_FILE="${AGENT_LAB_MODELS_FILE:-$REPO_ROOT/config/models.json}"
readonly COMPONENTS_FILE="${AGENT_LAB_COMPONENTS_FILE:-$REPO_ROOT/config/components.json}"
readonly RESULTS_DIR="${AGENT_LAB_RESULTS_DIR:-$REPO_ROOT/.agent-lab/results}"
readonly OLLAMA_URL="${AGENT_LAB_OLLAMA_URL:-http://127.0.0.1:11434}"
readonly OLLAMA_BIN="${AGENT_LAB_OLLAMA_BIN:-/opt/homebrew/opt/ollama/bin/ollama}"
readonly SCHEMA_VERSION=1
readonly DEFAULT_RUNS=3
readonly DEFAULT_PROMPT='Write a concise numbered list of exactly twenty short facts about local-only AI software. Keep each line under twelve words.'
readonly WARMUP_PROMPT='Reply with exactly READY'
readonly CONCURRENCY_PROMPT='Reply with exactly CONCURRENT-OK'

dry_run=false
run_count=$DEFAULT_RUNS
concurrency_case=false
compare_path=
output_path=
pid_file=
partial_file=
interrupt_cleanup_done=false

usage() {
  cat <<'EOF'
Usage: agent-lab benchmark [options]

Options:
  --dry-run              Validate environment and emit a schema-valid stub without inference
  --runs N               Timed samples per model after warm-up (default: 3)
  --concurrency          Also run the dedicated multi-request concurrency case
  --compare PATH         Reject comparison when digests or schema mismatch
  --output PATH          Result JSON path (default: .agent-lab/results/benchmark-<timestamp>.json)
  -h, --help             Show this help

Results include host baseline, component/model digests, cold load, TTFT,
tokens/sec, memory pressure, switch time, total latency, failure rate, and
sustained-run dispersion. Concurrency is off unless --concurrency is set.
EOF
}

cleanup() {
  local tag
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
  # Best-effort unload so an interrupted run does not leave a resident model.
  if command_exists curl; then
    while IFS= read -r tag; do
      [[ -n $tag ]] || continue
      curl --silent --max-time 5 -H 'Content-Type: application/json' \
        --data "$(jq -nc --arg model "$tag" '{model:$model,keep_alive:0}')" \
        "${OLLAMA_URL}/api/generate" >/dev/null 2>&1 || true
    done < <(jq -r '.models[] | select(.executable==true) | .tag' "$MODELS_FILE" 2>/dev/null || true)
  fi
}
trap cleanup EXIT HUP INT TERM

median_of() {
  # stdin: one number per line
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

memory_snapshot() {
  local free_pct rss_bytes pressure resident_bytes
  free_pct=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2); print $2+0; exit}')
  free_pct=${free_pct:-null}
  pressure=$(memory_pressure 2>/dev/null | awk -F': ' '/Pages free/{print $0; exit}' || true)
  rss_bytes=0
  if pgrep -x ollama >/dev/null 2>&1; then
    rss_bytes=$(pgrep -x ollama | while read -r pid; do ps -o rss= -p "$pid"; done | awk '{s+=$1} END{print (s+0)*1024}')
  fi
  rss_bytes=${rss_bytes:-0}
  resident_bytes=$(curl --silent --fail --max-time 2 "${OLLAMA_URL}/api/ps" 2>/dev/null |
    jq '[.models[] | (.size_vram // .size // 0)] | add // 0' || printf '0')
  jq -nc --argjson free "$free_pct" --argjson rss "$rss_bytes" --argjson resident "$resident_bytes" --arg pressure "$pressure" \
    '{system_memory_free_percent:$free,ollama_rss_bytes:$rss,ollama_resident_bytes:$resident,memory_pressure_note:$pressure}'
}

unload_model() {
  local tag=$1
  local attempt
  # Ollama may still be finishing a prior stream; retry keep_alive:0 briefly.
  for attempt in 1 2 3; do
    curl --silent --show-error --fail --max-time 60 \
      -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg model "$tag" '{model:$model,keep_alive:0}')" \
      "${OLLAMA_URL}/api/generate" >/dev/null 2>&1 || true
    local wait
    for wait in {1..120}; do
      if [[ $(curl --silent --fail --max-time 2 "${OLLAMA_URL}/api/ps" | jq --arg tag "$tag" '[.models[] | select(.name==$tag or .model==$tag)] | length') -eq 0 ]]; then
        return 0
      fi
      sleep 0.25
    done
  done
  warn "timed out unloading model: $tag (continuing)"
  return 0
}

stream_chat_metrics() {
  # Args: tag prompt keep_alive out_json_path
  # keep_alive is an Ollama duration string such as 5m, or 0 for unload-after.
  local tag=$1 prompt=$2 keep_alive=$3 out=$4
  local started first_ms=-1 total_ms eval_count=0 prompt_eval_count=0 success=false
  local tmp parsed
  tmp=$(mktemp)
  started=$(epoch_ms)
  if curl --silent --show-error --fail --max-time 300 \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg model "$tag" --arg prompt "$prompt" --arg keep "$keep_alive" \
      '{model:$model,messages:[{role:"user",content:$prompt}],stream:true,think:false,keep_alive:(if $keep=="0" then 0 else $keep end),options:{temperature:0,seed:42,num_ctx:4096,num_predict:256}}')" \
    "${OLLAMA_URL}/api/chat" >"$tmp"; then
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
  local tokens_per_sec=null
  if [[ $success == true && $eval_count -gt 0 && $total_ms -gt 0 ]]; then
    tokens_per_sec=$(awk -v c="$eval_count" -v ms="$total_ms" 'BEGIN{printf "%.3f", c / (ms/1000)}')
  fi
  jq -nc \
    --argjson success "$success" \
    --argjson ttft_ms "$first_ms" \
    --argjson total_ms "$total_ms" \
    --argjson eval_count "$eval_count" \
    --argjson prompt_eval_count "$prompt_eval_count" \
    --argjson tokens_per_sec "${tokens_per_sec:-null}" \
    '{success:$success,ttft_ms:(if $ttft_ms < 0 then null else $ttft_ms end),total_latency_ms:$total_ms,eval_count:$eval_count,prompt_eval_count:$prompt_eval_count,tokens_per_sec:$tokens_per_sec}' >"$out"
  [[ $success == true ]]
}

summarize_samples() {
  local samples_json=$1
  local ttft_med total_med tps_med ttft_sd total_sd tps_sd failures n
  n=$(jq 'length' <<<"$samples_json")
  failures=$(jq '[.[] | select(.success|not)] | length' <<<"$samples_json")
  ttft_med=$(jq -r '.[].ttft_ms // empty' <<<"$samples_json" | median_of)
  total_med=$(jq -r '.[].total_latency_ms // empty' <<<"$samples_json" | median_of)
  tps_med=$(jq -r '.[].tokens_per_sec // empty' <<<"$samples_json" | median_of)
  ttft_sd=$(jq -r '.[].ttft_ms // empty' <<<"$samples_json" | stdev_of)
  total_sd=$(jq -r '.[].total_latency_ms // empty' <<<"$samples_json" | stdev_of)
  tps_sd=$(jq -r '.[].tokens_per_sec // empty' <<<"$samples_json" | stdev_of)
  jq -nc \
    --argjson n "$n" \
    --argjson failures "$failures" \
    --argjson ttft_med "${ttft_med:-null}" \
    --argjson total_med "${total_med:-null}" \
    --argjson tps_med "${tps_med:-null}" \
    --argjson ttft_sd "${ttft_sd:-null}" \
    --argjson total_sd "${total_sd:-null}" \
    --argjson tps_sd "${tps_sd:-null}" \
    --argjson samples "$samples_json" \
    '{
      sample_count:$n,
      failure_count:$failures,
      failure_rate:(if $n==0 then null else ($failures/$n) end),
      ttft_ms:{median:$ttft_med,stdev:$ttft_sd},
      total_latency_ms:{median:$total_med,stdev:$total_sd},
      tokens_per_sec:{median:$tps_med,stdev:$tps_sd},
      samples:$samples
    }'
}

validate_result_schema() {
  local path=$1
  jq -e --argjson schema "$SCHEMA_VERSION" '
    .schema_version == $schema
    and (.host | type == "object")
    and (.components | type == "object")
    and (.models | type == "array")
    and (.profile | type == "string")
    and (.run | type == "object")
    and (.metrics | type == "object")
    and (.recommendations | type == "object")
  ' "$path" >/dev/null
}

compare_results() {
  local left=$1 right=$2
  validate_result_schema "$left" || die "left result failed schema validation: $left"
  validate_result_schema "$right" || die "right result failed schema validation: $right"
  local left_digests right_digests
  left_digests=$(jq -c '{ollama:(.components.ollama.executable_sha256 // .components.ollama.version), models:[.models[] | {alias,tag,manifest_digest}] | sort_by(.alias)}' "$left")
  right_digests=$(jq -c '{ollama:(.components.ollama.executable_sha256 // .components.ollama.version), models:[.models[] | {alias,tag,manifest_digest}] | sort_by(.alias)}' "$right")
  if [[ $left_digests != "$right_digests" ]]; then
    die "refusing to compare mismatched component/model digests"
  fi
  info "digest match; comparison allowed"
  jq -n --slurpfile a "$left" --slurpfile b "$right" \
    '{left:$a[0].run.started_at,right:$b[0].run.started_at,digest_match:true}'
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=true; shift ;;
    --runs)
      [[ $# -ge 2 ]] || die '--runs requires a positive integer'
      run_count=$2
      [[ $run_count =~ ^[1-9][0-9]*$ ]] || die '--runs must be a positive integer'
      shift 2
      ;;
    --concurrency) concurrency_case=true; shift ;;
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
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command jq
require_command curl
require_command python3
require_command shasum
[[ -r $MODELS_FILE ]] || die "models catalog missing: $MODELS_FILE"
[[ -r $COMPONENTS_FILE ]] || die "components catalog missing: $COMPONENTS_FILE"

mkdir -p "$RESULTS_DIR"
timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
output_path=${output_path:-$RESULTS_DIR/benchmark-${timestamp}.json}
partial_file="${output_path}.partial"
pid_file="$RESULTS_DIR/benchmark.pid"
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
ambient_json=$(memory_snapshot)
profile=$(agent_lab_active_profile 2>/dev/null || printf '%s' "${AGENT_LAB_PROFILE:-unknown}")
ollama_version=$(jq -r '.components[] | select(.id=="ollama") | .version' "$COMPONENTS_FILE")
ollama_sha=$(jq -r '.components[] | select(.id=="ollama") | .artifact.executable_sha256' "$COMPONENTS_FILE")
webui_version=$(jq -r '.components[] | select(.id=="open-webui") | .version' "$COMPONENTS_FILE")
webui_digest=$(jq -r '.components[] | select(.id=="open-webui") | .artifact.index_digest' "$COMPONENTS_FILE")
prompt_bytes=$(printf '%s' "$DEFAULT_PROMPT" | wc -c | tr -d ' ')
models_json=$(jq -c '[.models[] | select(.executable==true) | {alias,tag,manifest_digest,artifact_bytes,capabilities}]' "$MODELS_FILE")

if [[ $dry_run == true ]]; then
  jq -nc \
    --argjson schema "$SCHEMA_VERSION" \
    --argjson host "$host_json" \
    --argjson ambient "$ambient_json" \
    --arg profile "$profile" \
    --argjson models "$models_json" \
    --arg ollama_version "$ollama_version" \
    --arg ollama_sha "$ollama_sha" \
    --arg webui_version "$webui_version" \
    --arg webui_digest "$webui_digest" \
    --argjson runs "$run_count" \
    --argjson prompt_bytes "$prompt_bytes" \
    --arg started "$(now_iso)" \
    '{
      schema_version:$schema,
      dry_run:true,
      host:$host,
      ambient:$ambient,
      profile:$profile,
      components:{
        ollama:{version:$ollama_version,executable_sha256:$ollama_sha},
        open_webui:{version:$webui_version,index_digest:$webui_digest}
      },
      models:$models,
      run:{started_at:$started,ended_at:$started,run_count:$runs,prompt_bytes:$prompt_bytes,max_output_tokens:256,warmup:true,randomized_order:true,concurrency:false},
      metrics:{models:{},switches:[],concurrency:null,sustained:null},
      recommendations:{default_chat_alias:"qwen-9b",keep_alive:"5m",notes:"dry-run only; no inference performed"}
    }' >"$partial_file"
  validate_result_schema "$partial_file"
  mv "$partial_file" "$output_path"
  partial_file=
  if [[ -n $compare_path ]]; then
    compare_results "$output_path" "$compare_path"
  fi
  printf 'PASS: benchmark dry-run wrote %s\n' "$output_path"
  exit 0
fi

require_http_endpoint "${OLLAMA_URL}/api/version" 'Ollama'
[[ -x $OLLAMA_BIN ]] || die "Ollama binary missing: $OLLAMA_BIN"

model_tags=()
while IFS= read -r tag; do
  [[ -n $tag ]] || continue
  model_tags+=("$tag")
done < <(jq -r '.models[] | select(.executable==true) | .tag' "$MODELS_FILE")
[[ ${#model_tags[@]} -gt 0 ]] || die 'no executable models in catalog'

# Fisher-Yates shuffle for model order.
i=$(( ${#model_tags[@]} - 1 ))
while [[ $i -gt 0 ]]; do
  j=$((RANDOM % (i + 1)))
  tmp=${model_tags[i]}
  model_tags[i]=${model_tags[j]}
  model_tags[j]=$tmp
  i=$((i - 1))
done

info "benchmark order: ${model_tags[*]}"
metrics_models='{}'
switches='[]'
failures_total=0
requests_total=0
started_at=$(now_iso)
peak_rss=0
peak_resident=0
min_free=100

for tag in "${model_tags[@]}"; do
  alias=$(jq -r --arg tag "$tag" '.models[] | select(.tag==$tag) | .alias' "$MODELS_FILE")
  info "benchmarking $alias ($tag)"
  unload_model "$tag"

  cold_out=$(mktemp)
  mem_before=$(memory_snapshot)
  if stream_chat_metrics "$tag" "$WARMUP_PROMPT" '5m' "$cold_out"; then
    :
  else
    failures_total=$((failures_total + 1))
  fi
  requests_total=$((requests_total + 1))
  mem_after_cold=$(memory_snapshot)
  cold_json=$(cat "$cold_out")
  rm -f -- "$cold_out"

  # Explicit warm-up (discarded) then timed samples.
  warm_out=$(mktemp)
  stream_chat_metrics "$tag" "$WARMUP_PROMPT" '5m' "$warm_out" || true
  requests_total=$((requests_total + 1))
  rm -f -- "$warm_out"

  samples='[]'
  n=1
  while [[ $n -le $run_count ]]; do
    sample_out=$(mktemp)
    mem_mid=$(memory_snapshot)
    rss=$(jq -r '.ollama_rss_bytes' <<<"$mem_mid")
    resident=$(jq -r '.ollama_resident_bytes // 0' <<<"$mem_mid")
    free=$(jq -r '.system_memory_free_percent // 100' <<<"$mem_mid")
    if [[ $rss -gt $peak_rss ]]; then
      peak_rss=$rss
    fi
    if [[ $resident -gt $peak_resident ]]; then
      peak_resident=$resident
    fi
    awk -v f="$free" -v m="$min_free" 'BEGIN{exit !(f < m)}' && min_free=$free
    if stream_chat_metrics "$tag" "$DEFAULT_PROMPT" '5m' "$sample_out"; then
      sample=$(cat "$sample_out")
    else
      failures_total=$((failures_total + 1))
      sample=$(jq -nc '{success:false,ttft_ms:null,total_latency_ms:null,eval_count:0,prompt_eval_count:0,tokens_per_sec:null}')
    fi
    requests_total=$((requests_total + 1))
    samples=$(jq -c --argjson s "$sample" --argjson mem "$mem_mid" '. + [$s + {memory:$mem}]' <<<"$samples")
    rm -f -- "$sample_out"
    n=$((n + 1))
  done

  summary=$(summarize_samples "$samples")
  metrics_models=$(jq -c --arg alias "$alias" --arg tag "$tag" --argjson cold "$cold_json" \
    --argjson before "$mem_before" --argjson after "$mem_after_cold" --argjson summary "$summary" \
    '.[$alias] = {
      tag:$tag,
      cold_load:$cold,
      memory_before:$before,
      memory_after_cold:$after,
      timed:$summary
    }' <<<"$metrics_models")
done

# Serial switch timing across the randomized order.
prev=
for tag in "${model_tags[@]}"; do
  if [[ -n $prev ]]; then
    unload_model "$prev" || true
  fi
  switch_out=$(mktemp)
  switch_started=$(epoch_ms)
  stream_chat_metrics "$tag" "$WARMUP_PROMPT" '5m' "$switch_out" || failures_total=$((failures_total + 1))
  requests_total=$((requests_total + 1))
  switch_ms=$(( $(epoch_ms) - switch_started ))
  switches=$(jq -c --arg from "${prev:-none}" --arg to "$tag" --argjson ms "$switch_ms" \
    '. + [{from:$from,to:$to,switch_plus_first_token_ms:$ms}]' <<<"$switches")
  rm -f -- "$switch_out"
  prev=$tag
done

concurrency_json=null
if [[ $concurrency_case == true ]]; then
  info 'running dedicated concurrency case'
  default_alias=$(jq -r '.defaults.chat' "$MODELS_FILE")
  default_tag=$(jq -r --arg alias "$default_alias" '.models[] | select(.alias==$alias) | .tag' "$MODELS_FILE")
  unload_model "$default_tag"
  warm_c=$(mktemp)
  stream_chat_metrics "$default_tag" "$WARMUP_PROMPT" '5m' "$warm_c" || true
  rm -f -- "$warm_c"
  c1=$(mktemp)
  c2=$(mktemp)
  stream_chat_metrics "$default_tag" "$CONCURRENCY_PROMPT" '5m' "$c1" &
  p1=$!
  stream_chat_metrics "$default_tag" "$CONCURRENCY_PROMPT" '5m' "$c2" &
  p2=$!
  wait "$p1" || true
  wait "$p2" || true
  loaded=$(curl --silent --fail "${OLLAMA_URL}/api/ps" | jq '.models|length')
  concurrency_json=$(jq -nc --slurpfile a "$c1" --slurpfile b "$c2" --argjson loaded "$loaded" \
    '{same_model:true,loaded_model_count:$loaded,request_a:$a[0],request_b:$b[0]}')
  rm -f -- "$c1" "$c2"
fi

# Sustained thermal/throttling proxy: three back-to-back runs on default chat.
default_alias=$(jq -r '.defaults.chat' "$MODELS_FILE")
default_tag=$(jq -r --arg alias "$default_alias" '.models[] | select(.alias==$alias) | .tag' "$MODELS_FILE")
sustained='[]'
n=1
while [[ $n -le 3 ]]; do
  s_out=$(mktemp)
  stream_chat_metrics "$default_tag" "$DEFAULT_PROMPT" '5m' "$s_out" || true
  requests_total=$((requests_total + 1))
  sustained=$(jq -c --argjson s "$(cat "$s_out")" '. + [$s]' <<<"$sustained")
  rm -f -- "$s_out"
  n=$((n + 1))
done
sustained_summary=$(summarize_samples "$sustained")

# Final unload of all approved models.
for tag in "${model_tags[@]}"; do
  unload_model "$tag" || true
done

ended_at=$(now_iso)
critical_pressure=false
awk -v f="$min_free" 'BEGIN{exit !(f < 15)}' && critical_pressure=true

# Keep-alive recommendation: 5m is acceptable when free memory stayed above 20%
# after largest model samples; otherwise prefer shorter keep-alive.
keep_alive_rec='5m'
awk -v f="$min_free" 'BEGIN{exit !(f < 25)}' && keep_alive_rec='2m'
awk -v f="$min_free" 'BEGIN{exit !(f < 15)}' && keep_alive_rec='0'

jq -nc \
  --argjson schema "$SCHEMA_VERSION" \
  --argjson host "$host_json" \
  --argjson ambient "$ambient_json" \
  --arg profile "$profile" \
  --argjson models "$models_json" \
  --arg ollama_version "$ollama_version" \
  --arg ollama_sha "$ollama_sha" \
  --arg webui_version "$webui_version" \
  --arg webui_digest "$webui_digest" \
  --argjson runs "$run_count" \
  --argjson prompt_bytes "$prompt_bytes" \
  --arg started "$started_at" \
  --arg ended "$ended_at" \
  --argjson metrics_models "$metrics_models" \
  --argjson switches "$switches" \
  --argjson concurrency "$concurrency_json" \
  --argjson sustained "$sustained_summary" \
  --argjson peak_rss "$peak_rss" \
  --argjson peak_resident "$peak_resident" \
  --argjson min_free "$min_free" \
  --argjson failures "$failures_total" \
  --argjson requests "$requests_total" \
  --argjson critical "$critical_pressure" \
  --arg keep "$keep_alive_rec" \
  --arg default_alias "$default_alias" \
  --argjson concurrency_enabled "$concurrency_case" \
  '{
    schema_version:$schema,
    dry_run:false,
    host:$host,
    ambient:$ambient,
    profile:$profile,
    components:{
      ollama:{version:$ollama_version,executable_sha256:$ollama_sha},
      open_webui:{version:$webui_version,index_digest:$webui_digest}
    },
    models:$models,
    run:{
      started_at:$started,
      ended_at:$ended,
      run_count:$runs,
      prompt_bytes:$prompt_bytes,
      max_output_tokens:256,
      warmup:true,
      randomized_order:true,
      concurrency:$concurrency_enabled,
      requests_total:$requests,
      failures_total:$failures
    },
    metrics:{
      models:$metrics_models,
      switches:$switches,
      concurrency:$concurrency,
      sustained:$sustained,
      peak_ollama_rss_bytes:$peak_rss,
      peak_ollama_resident_bytes:$peak_resident,
      min_system_memory_free_percent:$min_free,
      critical_memory_pressure:$critical
    },
    recommendations:{
      default_chat_alias:$default_alias,
      keep_alive:$keep,
      notes:(if $critical then "critical memory pressure observed; prefer keep_alive 0 or 2m and serial model use" else "single-model residency with keep-alive is acceptable on this sample" end)
    }
  }' >"$partial_file"

validate_result_schema "$partial_file"
mv "$partial_file" "$output_path"
partial_file=
rm -f -- "$pid_file"
pid_file=

if [[ -n $compare_path ]]; then
  compare_results "$output_path" "$compare_path"
fi

printf 'PASS: benchmark wrote %s (keep_alive=%s critical_pressure=%s)\n' \
  "$output_path" "$keep_alive_rec" "$critical_pressure"
