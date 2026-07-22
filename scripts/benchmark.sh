#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

readonly ROOT="$(repository_root "$SCRIPT_DIR")"
readonly API='http://127.0.0.1:11434'
readonly MODELS_FILE="$ROOT/config/models.json"
readonly COMPONENTS_FILE="$ROOT/config/components.json"
readonly DEFAULT_PROMPT='Explain in concise numbered steps how to verify a local service is healthy, private, and recoverable. Include exactly one sentence per step.'
RUN_DIR=
OUTPUT=
SAMPLES='[]'
INTERRUPTED=false
MUTATED=false

usage() {
  cat <<'EOF'
Usage:
  agent-lab benchmark [--runs N] [--models TAGS] [--ambient NOTE] [--output FILE] [--dry-run]
  agent-lab benchmark --validate FILE
  agent-lab benchmark --compare BASELINE.json CANDIDATE.json

TAGS is a comma-separated subset of qwen3.5:4b,qwen3.5:9b,gemma4:12b.
Results default to the ignored .agent-lab/results directory.
EOF
}

median_jq='def median: sort | length as $n | if $n == 0 then null elif ($n % 2) == 1 then .[($n/2|floor)] else ((.[($n/2)-1] + .[$n/2]) / 2) end;'

validate_result() {
  local file=$1
  jq -e '
    .schema_version == 1 and
    (.kind == "agent-lab-native-benchmark" or .kind == "agent-lab-native-benchmark-plan") and
    (.host | type == "object") and (.components | type == "object") and
    (.model_manifests | type == "object") and (.configuration.runs | type == "number") and
    (.samples | type == "array") and (.summary | type == "array")
  ' "$file" >/dev/null
}

compare_results() {
  local baseline=$1 candidate=$2
  validate_result "$baseline" || die "invalid baseline benchmark: $baseline" || return 1
  validate_result "$candidate" || die "invalid candidate benchmark: $candidate" || return 1
  jq -e '.kind == "agent-lab-native-benchmark" and .status == "pass" and
    (.samples | length > 0) and (.summary | length > 0)' "$baseline" >/dev/null ||
    die 'benchmark comparison rejected: baseline is not a completed passing result' || return 2
  jq -e '.kind == "agent-lab-native-benchmark" and .status == "pass" and
    (.samples | length > 0) and (.summary | length > 0)' "$candidate" >/dev/null ||
    die 'benchmark comparison rejected: candidate is not a completed passing result' || return 2
  [[ $(jq -S -c '.model_manifests' "$baseline") == "$(jq -S -c '.model_manifests' "$candidate")" ]] ||
    die 'benchmark comparison rejected: model manifest digests differ' || return 2
  [[ $(jq -S -c '.components' "$baseline") == "$(jq -S -c '.components' "$candidate")" ]] ||
    die 'benchmark comparison rejected: component versions differ' || return 2
  [[ $(jq -S -c '.configuration | {runs,models,profile,prompt,num_predict,num_ctx,max_concurrency}' "$baseline") == \
     "$(jq -S -c '.configuration | {runs,models,profile,prompt,num_predict,num_ctx,max_concurrency}' "$candidate")" ]] ||
    die 'benchmark comparison rejected: benchmark configurations differ' || return 2
  [[ $(jq -r '.host.hardware_model + ":" + (.host.memory_bytes|tostring)' "$baseline") == \
     "$(jq -r '.host.hardware_model + ":" + (.host.memory_bytes|tostring)' "$candidate")" ]] ||
    die 'benchmark comparison rejected: host hardware differs' || return 2
  comparison=$(jq -n --slurpfile base "$baseline" --slurpfile candidate "$candidate" '
    [$base[0].summary[] as $b | $candidate[0].summary[] |
      select(.model == $b.model) |
      {model, baseline_tokens_per_second:$b.median_tokens_per_second,
       candidate_tokens_per_second:.median_tokens_per_second,
       tokens_per_second_change_percent:(if $b.median_tokens_per_second == 0 then null else ((.median_tokens_per_second-$b.median_tokens_per_second)/$b.median_tokens_per_second*100) end),
       baseline_total_latency_ms:$b.median_total_latency_ms,
       candidate_total_latency_ms:.median_total_latency_ms}]
  ')
  [[ $(jq 'length' <<<"$comparison") -gt 0 ]] ||
    die 'benchmark comparison rejected: no matching completed model summaries' || return 2
  printf '%s\n' "$comparison"
}

unload_all() {
  local model
  command -v curl >/dev/null 2>&1 || return 0
  for model in qwen3.5:4b qwen3.5:9b gemma4:12b; do
    curl --silent --max-time 15 -H 'Content-Type: application/json' \
      --data "$(jq -cn --arg model "$model" '{model:$model,keep_alive:0}')" \
      "$API/api/generate" >/dev/null 2>&1 || true
  done
}

cleanup() {
  [[ $MUTATED != true ]] || unload_all
  [[ -z $RUN_DIR ]] || rm -rf -- "$RUN_DIR"
  if [[ $INTERRUPTED == true && -n $OUTPUT ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    jq -n --arg completed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson samples "$SAMPLES" \
      '{schema_version:1,kind:"agent-lab-native-benchmark",status:"interrupted",completed_at:$completed_at,samples:$samples}' > "$OUTPUT.interrupted.json"
  fi
}
trap cleanup EXIT
trap 'INTERRUPTED=true; exit 130' INT TERM HUP

runs=3
models_csv='qwen3.5:4b,qwen3.5:9b,gemma4:12b'
ambient='normal indoor conditions; connected to power status recorded in host metadata'
dry_run=false
mode=run
validate_file=
compare_a=
compare_b=

while (($#)); do
  case $1 in
    --runs) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; runs=$2; shift 2 ;;
    --models) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; models_csv=$2; shift 2 ;;
    --ambient) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; ambient=$2; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; OUTPUT=$2; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --validate) [[ $# -eq 2 ]] || { usage >&2; exit 64; }; mode=validate; validate_file=$2; shift 2 ;;
    --compare) [[ $# -eq 3 ]] || { usage >&2; exit 64; }; mode=compare; compare_a=$2; compare_b=$3; shift 3 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown benchmark option: $1"; exit 64 ;;
  esac
done

case $mode in
  validate) validate_result "$validate_file"; printf 'PASS: valid benchmark result: %s\n' "$validate_file"; exit 0 ;;
  compare) compare_results "$compare_a" "$compare_b"; exit $? ;;
esac

[[ $runs =~ ^[1-9][0-9]*$ && $runs -le 20 ]] || die '--runs must be between 1 and 20' || exit 64
IFS=',' read -r -a models <<<"$models_csv"
for model in "${models[@]}"; do
  case $model in qwen3.5:4b|qwen3.5:9b|gemma4:12b) ;; *) die "unsupported benchmark model: $model"; exit 64 ;; esac
done

require_command jq
require_command curl
require_command shasum
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'native benchmark requires Apple Silicon macOS' || exit 1

mkdir -p "$ROOT/.agent-lab/results"
[[ -n $OUTPUT ]] || OUTPUT="$ROOT/.agent-lab/results/benchmark-$(date -u '+%Y%m%dT%H%M%SZ').json"
mkdir -p "$(dirname "$OUTPUT")"
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-benchmark.XXXXXX")

hardware_model=$(sysctl -n hw.model 2>/dev/null || printf unknown)
memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || printf 0)
cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf 'Apple Silicon')
power_source=$(pmset -g batt 2>/dev/null | head -n 1 || true)
profile=$(cat "$ROOT/.agent-lab/profile" 2>/dev/null || printf online-manual)
ollama_version=$(jq -r '.components[] | select(.id == "ollama") | .version' "$COMPONENTS_FILE")
open_webui_version=$(jq -r '.components[] | select(.id == "open-webui") | .version' "$COMPONENTS_FILE")
manifests=$(jq -c --arg models "$models_csv" '($models | split(",")) as $selected |
  [.models[] | select(.executable == true) | select(.tag as $tag | $selected | index($tag))] |
  map({key:.tag,value:.manifest_digest}) | from_entries' "$MODELS_FILE")
host=$(jq -cn --arg hardware_model "$hardware_model" --arg cpu "$cpu_brand" --argjson memory "$memory_bytes" --arg os "$(sw_vers -productVersion)" --arg power "$power_source" '{hardware_model:$hardware_model,cpu:$cpu,memory_bytes:$memory,os_version:$os,power_source:$power}')
components=$(jq -cn --arg ollama "$ollama_version" --arg webui "$open_webui_version" '{ollama:$ollama,open_webui:$webui}')

if [[ $dry_run == true ]]; then
  jq -n --argjson host "$host" --argjson components "$components" --argjson manifests "$manifests" \
    --arg profile "$profile" --arg ambient "$ambient" --argjson runs "$runs" --arg models "$models_csv" \
    '{schema_version:1,kind:"agent-lab-native-benchmark-plan",status:"dry-run",host:$host,components:$components,model_manifests:$manifests,configuration:{runs:$runs,models:($models|split(",")),profile:$profile,ambient:$ambient,prompt:"fixed v1 health/privacy/recovery prompt",num_predict:128,num_ctx:4096,max_concurrency:1},samples:[],summary:[]}' > "$OUTPUT"
  validate_result "$OUTPUT"
  printf 'PASS: benchmark dry run: %s\n' "$OUTPUT"
  exit 0
fi

"$ROOT/scripts/models.sh" verify >/dev/null
curl --fail --silent --max-time 3 "$API/api/version" >/dev/null || die 'managed Ollama is unavailable' || exit 1
ollama_version=$(curl --fail --silent "$API/api/version" | jq -r '.version')
components=$(jq -cn --arg ollama "$ollama_version" --arg webui "$open_webui_version" '{ollama:$ollama,open_webui:$webui}')
MUTATED=true

previous_model='none'
sample_index=0
for ((iteration=1; iteration<=runs; iteration++)); do
  shuffled=$(printf '%s\n' "${models[@]}" | awk 'BEGIN{srand()} {print rand(), $0}' | sort -n | cut -d' ' -f2-)
  while IFS= read -r model; do
    [[ -n $model ]] || continue
    sample_index=$((sample_index + 1))
    unload_all
    for _ in {1..40}; do
      [[ $(curl --fail --silent "$API/api/ps" | jq '.models | length') -eq 0 ]] && break
      sleep 0.25
    done
    response_file="$RUN_DIR/response-$sample_index.json"
    body=$(jq -cn --arg model "$model" --arg prompt "$DEFAULT_PROMPT" '{model:$model,messages:[{role:"user",content:$prompt}],stream:false,think:false,keep_alive:0,options:{temperature:0,seed:42,num_predict:128,num_ctx:4096}}')
    curl --fail --silent --show-error --max-time 300 -H 'Content-Type: application/json' --data "$body" "$API/api/chat" > "$response_file" &
    request_pid=$!
    peak_rss_kb=0
    while kill -0 "$request_pid" 2>/dev/null; do
      rss_kb=$(ps -axo rss=,command= | awk '/[o]llama/ {sum += $1} END {print sum+0}')
      ((rss_kb > peak_rss_kb)) && peak_rss_kb=$rss_kb
      sleep 0.1
    done
    if wait "$request_pid" && jq -e '.done == true and .eval_count > 0 and .eval_duration > 0' "$response_file" >/dev/null 2>&1; then
      status=pass
      failure=null
    else
      status=fail
      failure='request or response validation failed'
    fi
    memory_free=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/System-wide memory free percentage/ {gsub(/%/, "", $2); print $2; exit}')
    [[ $memory_free =~ ^[0-9]+$ ]] || memory_free=null
    if [[ $status == pass ]]; then
      sample=$(jq -c --arg model "$model" --arg from "$previous_model" --argjson iteration "$iteration" \
        --argjson peak_rss_bytes "$((peak_rss_kb * 1024))" --argjson memory_free_percent "$memory_free" '
        . as $r | (($r.total_duration-$r.load_duration-$r.prompt_eval_duration) | if . > 0 then . else $r.eval_duration end) as $generation_duration |
        {model:$model,switch_from:$from,iteration:$iteration,status:"pass",failure:null,
          prompt_tokens:$r.prompt_eval_count,output_tokens:$r.eval_count,
          cold_load_ms:($r.load_duration/1000000),
          estimated_ttft_ms:(($r.load_duration+$r.prompt_eval_duration+($generation_duration/$r.eval_count))/1000000),
          tokens_per_second:($r.eval_count/($generation_duration/1000000000)),
          total_latency_ms:($r.total_duration/1000000),switch_latency_ms:($r.total_duration/1000000),
          peak_ollama_rss_bytes:$peak_rss_bytes,system_memory_free_percent:$memory_free_percent}
        ' "$response_file")
    else
      sample=$(jq -cn --arg model "$model" --arg from "$previous_model" --arg failure "$failure" \
        --argjson iteration "$iteration" --argjson peak_rss_bytes "$((peak_rss_kb * 1024))" \
        --argjson memory_free_percent "$memory_free" \
        '{model:$model,switch_from:$from,iteration:$iteration,status:"fail",failure:$failure,
          prompt_tokens:null,output_tokens:null,cold_load_ms:null,estimated_ttft_ms:null,
          tokens_per_second:null,total_latency_ms:null,switch_latency_ms:null,
          peak_ollama_rss_bytes:$peak_rss_bytes,system_memory_free_percent:$memory_free_percent}')
    fi
    SAMPLES=$(jq -c --argjson sample "$sample" '. + [$sample]' <<<"$SAMPLES")
    previous_model=$model
  done <<<"$shuffled"
done

summary=$(jq -c "$median_jq
  group_by(.model) | map(. as \$rows | ([.[] | select(.status == \"pass\")]) as \$passed | {
    model:.[0].model,runs:length,failures:([.[]|select(.status != \"pass\")]|length),
    failure_rate:(([.[]|select(.status != \"pass\")]|length)/length),
    median_tokens_per_second:([\$passed[].tokens_per_second]|median),
    min_tokens_per_second:([\$passed[].tokens_per_second] | if length == 0 then null else min end),
    max_tokens_per_second:([\$passed[].tokens_per_second] | if length == 0 then null else max end),
    throughput_spread_percent:([\$passed[].tokens_per_second] | if length == 0 then null else ((max-min)/(median)*100) end),
    median_cold_load_ms:([\$passed[].cold_load_ms]|median),median_estimated_ttft_ms:([\$passed[].estimated_ttft_ms]|median),
    median_total_latency_ms:([\$passed[].total_latency_ms]|median),peak_ollama_rss_bytes:([.[].peak_ollama_rss_bytes]|max),
    minimum_system_memory_free_percent:([.[].system_memory_free_percent|select(. != null)] | if length == 0 then null else min end),
    sustained_throughput_change_percent:(if (\$passed|length) < 2 then null else ((\$passed[-1].tokens_per_second-\$passed[0].tokens_per_second)/\$passed[0].tokens_per_second*100) end)
  })" <<<"$SAMPLES")

jq -n --arg completed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson host "$host" --argjson components "$components" \
  --argjson manifests "$manifests" --arg profile "$profile" --arg ambient "$ambient" --argjson runs "$runs" \
  --argjson samples "$SAMPLES" --argjson summary "$summary" \
  --arg models "$models_csv" \
  '{schema_version:1,kind:"agent-lab-native-benchmark",status:(if ([ $samples[].status ]|all(. == "pass")) then "pass" else "fail" end),completed_at:$completed_at,host:$host,components:$components,model_manifests:$manifests,configuration:{runs:$runs,models:($models|split(",")),profile:$profile,ambient:$ambient,prompt:"fixed v1 health/privacy/recovery prompt",num_predict:128,num_ctx:4096,max_concurrency:1,order:"randomized per iteration"},samples:$samples,summary:$summary}' > "$OUTPUT"
validate_result "$OUTPUT"
[[ $(jq -r '.status' "$OUTPUT") == pass ]] || die "benchmark completed with failures: $OUTPUT" || exit 1
printf 'PASS: native benchmark: %s\n' "$OUTPUT"
