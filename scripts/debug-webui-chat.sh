#!/usr/bin/env bash
# Path B debug: chat through Open WebUI's Ollama proxy (not direct :11434).
# Use when UI "feel" differs from bin/agent-lab benchmark — compare think /
# num_predict / WebUI hop vs direct Ollama with the same prompt.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
readonly MODELS_FILE="${ROOT}/config/models.json"
readonly RESULTS_DIR="${ROOT}/.agent-lab/results"
readonly DEFAULT_PROMPT='世界杯是什么？'

usage() {
  cat <<'EOF'
Usage: agent-lab debug-webui-chat [options]

Path B: sign in to Open WebUI and POST /ollama/api/chat (same hop the UI uses
for the Ollama provider). Writes JSON + markdown under .agent-lab/results/.

Options:
  --prompt TEXT          User message (default: 世界杯是什么？)
  --alias ALIAS          Role alias from config/models.json (default: qwen-4b)
  --model TAG            Ollama tag override (default: resolve alias)
  --think on|off         Ollama think flag (default: off)
  --num-predict N        options.num_predict (default: 256; 0 = omit)
  --temperature F        options.temperature (default: 0)
  --num-ctx N            options.num_ctx (default: 4096)
  --keep-alive VAL       keep_alive (default: 5m)
  --runs N               Timed samples after one warm-up (default: 1)
  --compare-direct       Also hit Ollama :11434 with the same body
  --output PATH          Result JSON (default: .agent-lab/results/debug-webui-chat-<ts>.json)
  --markdown PATH        Summary markdown (default: sibling .md)
  -h, --help             Show this help

Examples:
  bin/agent-lab start
  bin/agent-lab debug-webui-chat
  bin/agent-lab debug-webui-chat --think on --compare-direct --runs 2
  bin/agent-lab debug-webui-chat --alias qwen-9b --prompt '用三句话解释世界杯'
EOF
}

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

resolve_tag() {
  local alias=$1
  jq -er --arg a "$alias" '
    .models[]
    | select(.alias == $a and .executable == true)
    | .tag
  ' "$MODELS_FILE"
}

sign_in() {
  local response
  response=$(curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" \
      '{email:$email,password:$password}')" \
    "${WEBUI_URL}/api/v1/auths/signin") || die 'Open WebUI admin sign-in failed'
  token=$(jq -er '.token' <<<"$response") || die 'Open WebUI sign-in returned no token'
}

# Open WebUI initializes in-memory Ollama routing when the catalog is fetched
# (same as the browser before the first chat).
prime_webui_ollama() {
  local tags attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    tags=$(curl --fail --silent --show-error --max-time 30 \
      -H "Authorization: Bearer ${token}" \
      "${WEBUI_URL}/ollama/api/tags") || {
      sleep 1
      continue
    }
    if jq -e --arg m "$model" '[.models[].model] | index($m) != null' <<<"$tags" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  die "Open WebUI model catalog does not include '${model}' yet"
}

build_body() {
  local model=$1 think_bool=$2
  jq -cn \
    --arg model "$model" \
    --arg prompt "$prompt" \
    --arg keep_alive "$keep_alive" \
    --argjson think "$think_bool" \
    --argjson temperature "$temperature" \
    --argjson num_ctx "$num_ctx" \
    --argjson num_predict "$num_predict" \
    '
    {
      model: $model,
      messages: [{role: "user", content: $prompt}],
      stream: false,
      think: $think,
      keep_alive: $keep_alive,
      options: (
        {temperature: $temperature, num_ctx: $num_ctx}
        + (if $num_predict > 0 then {num_predict: $num_predict} else {} end)
      )
    }
    '
}

chat_once() {
  # args: label url body out_json wall_ms_file
  local label=$1 url=$2 body=$3 out_json=$4 wall_file=$5
  local started ended http_code tmp attempt=1 max_attempts=1
  # WebUI proxy can briefly return model-not-found right after recreate.
  [[ $label == webui-warmup || $label == webui-run-* ]] && max_attempts=5
  tmp=$(mktemp "${TMPDIR:-/tmp}/agent-lab-webui-chat.XXXXXX")
  while true; do
    started=$(now_ms)
    http_code=$(curl --silent --show-error --output "$tmp" --write-out '%{http_code}' \
      --max-time 600 \
      -H 'Content-Type: application/json' \
      ${auth_header:+-H "$auth_header"} \
      --data "$body" "$url") || true
    ended=$(now_ms)
    printf '%s' "$((ended - started))" >"$wall_file"
    if [[ "$http_code" == 200 ]]; then
      break
    fi
    if [[ $attempt -lt $max_attempts && "$http_code" == 400 ]] &&
      grep -qi 'not found' "$tmp"; then
      printf 'WARN: %s got HTTP 400 model-not-found; retrying (%s/%s)\n' \
        "$label" "$attempt" "$max_attempts" >&2
      attempt=$((attempt + 1))
      sleep 1
      continue
    fi
    jq -nc \
      --arg label "$label" \
      --argjson http_code "$http_code" \
      --argjson wall_ms "$(cat "$wall_file")" \
      --arg body "$(head -c 2000 "$tmp" | tr '\n' ' ')" \
      '{label:$label,ok:false,http_code:$http_code,wall_ms:$wall_ms,error:$body}' >"$out_json"
    rm -f -- "$tmp"
    return 1
  done

  python3 - "$tmp" "$label" "$(cat "$wall_file")" "$out_json" <<'PY'
import json, sys
path, label, wall_ms, out = sys.argv[1:5]
raw = open(path, encoding="utf-8").read()
obj = json.loads(raw)
msg = obj.get("message") or {}
content = msg.get("content") or ""
thinking = msg.get("thinking") or msg.get("reasoning") or ""
eval_count = int(obj.get("eval_count") or 0)
prompt_eval_count = int(obj.get("prompt_eval_count") or 0)
eval_duration_ns = int(obj.get("eval_duration") or 0)
prompt_eval_duration_ns = int(obj.get("prompt_eval_duration") or 0)
total_duration_ns = int(obj.get("total_duration") or 0)
load_duration_ns = int(obj.get("load_duration") or 0)

def ns_to_ms(ns):
    return round(ns / 1_000_000, 3) if ns else None

decode_tps = None
if eval_count > 0 and eval_duration_ns > 0:
    decode_tps = round(eval_count / (eval_duration_ns / 1e9), 3)
prompt_tps = None
if prompt_eval_count > 0 and prompt_eval_duration_ns > 0:
    prompt_tps = round(prompt_eval_count / (prompt_eval_duration_ns / 1e9), 3)

result = {
    "label": label,
    "ok": True,
    "http_code": 200,
    "wall_ms": int(wall_ms),
    "content": content,
    "content_chars": len(content),
    "thinking_chars": len(thinking) if isinstance(thinking, str) else 0,
    "eval_count": eval_count,
    "prompt_eval_count": prompt_eval_count,
    "decode_tok_s": decode_tps,
    "prompt_tok_s": prompt_tps,
    "eval_ms": ns_to_ms(eval_duration_ns),
    "prompt_eval_ms": ns_to_ms(prompt_eval_duration_ns),
    "total_duration_ms": ns_to_ms(total_duration_ns),
    "load_duration_ms": ns_to_ms(load_duration_ns),
    "done_reason": obj.get("done_reason"),
}
open(out, "w", encoding="utf-8").write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
PY
  rm -f -- "$tmp"
}

prompt=$DEFAULT_PROMPT
alias='qwen-4b'
model=''
think='off'
num_predict=256
temperature=0
num_ctx=4096
keep_alive='5m'
runs=1
compare_direct=false
output=''
markdown=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --prompt) prompt=$2; shift 2 ;;
    --alias) alias=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --think)
      case "$2" in
        on|off) think=$2 ;;
        *) die '--think must be on or off' ;;
      esac
      shift 2
      ;;
    --num-predict) num_predict=$2; shift 2 ;;
    --temperature) temperature=$2; shift 2 ;;
    --num-ctx) num_ctx=$2; shift 2 ;;
    --keep-alive) keep_alive=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --compare-direct) compare_direct=true; shift ;;
    --output) output=$2; shift 2 ;;
    --markdown) markdown=$2; shift 2 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

need_cmd curl
need_cmd jq
need_cmd python3
[[ -f "${ROOT}/.env" ]] || die "missing ${ROOT}/.env (run bin/agent-lab setup)"
[[ -f "$MODELS_FILE" ]] || die "missing $MODELS_FILE"
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || die '--runs must be a positive integer'
[[ "$num_predict" =~ ^[0-9]+$ ]] || die '--num-predict must be a non-negative integer'

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")
[[ -n $admin_email && -n $admin_password ]] || die 'WEBUI_ADMIN_EMAIL / WEBUI_ADMIN_PASSWORD missing from .env'

if [[ -z $model ]]; then
  model=$(resolve_tag "$alias") || die "could not resolve approved alias: $alias"
fi

curl --fail --silent --max-time 5 "${WEBUI_URL}/health" >/dev/null 2>&1 ||
  die "Open WebUI not healthy at ${WEBUI_URL}/health (run: bin/agent-lab start)"
curl --fail --silent --max-time 5 "${OLLAMA_URL}/api/version" >/dev/null 2>&1 ||
  die "Ollama not reachable at ${OLLAMA_URL} (run: bin/agent-lab start)"

think_bool=false
[[ $think == on ]] && think_bool=true

mkdir -p "$RESULTS_DIR"
ts=$(date -u +%Y%m%dT%H%M%SZ)
[[ -n $output ]] || output="${RESULTS_DIR}/debug-webui-chat-${ts}.json"
[[ -n $markdown ]] || markdown="${output%.json}.md"

sign_in
prime_webui_ollama
body=$(build_body "$model" "$think_bool")

printf 'INFO: path B via %s/ollama/api/chat model=%s think=%s num_predict=%s runs=%s\n' \
  "$WEBUI_URL" "$model" "$think" "$num_predict" "$runs" >&2
printf 'INFO: prompt=%s\n' "$prompt" >&2

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-debug-webui.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

samples_json='[]'
auth_header="Authorization: Bearer ${token}"

# Warm-up through WebUI (not counted)
warm_out="${work}/warm.json"
warm_wall="${work}/warm.wall"
if chat_once webui-warmup "${WEBUI_URL}/ollama/api/chat" "$body" "$warm_out" "$warm_wall"; then
  printf 'INFO: warm-up ok wall_ms=%s decode_tok_s=%s\n' \
    "$(jq -r '.wall_ms' "$warm_out")" "$(jq -r '.decode_tok_s // "n/a"' "$warm_out")" >&2
else
  die "WebUI warm-up failed: $(jq -c . "$warm_out" 2>/dev/null || cat "$warm_out")"
fi

run_i=1
while [[ $run_i -le $runs ]]; do
  out="${work}/webui-${run_i}.json"
  wall="${work}/webui-${run_i}.wall"
  auth_header="Authorization: Bearer ${token}"
  if ! chat_once "webui-run-${run_i}" "${WEBUI_URL}/ollama/api/chat" "$body" "$out" "$wall"; then
    die "WebUI run ${run_i} failed: $(jq -c . "$out")"
  fi
  samples_json=$(jq -c --slurpfile s "$out" '. + $s' <<<"$samples_json")
  printf 'INFO: webui run %s wall_ms=%s decode_tok_s=%s chars=%s\n' \
    "$run_i" "$(jq -r '.wall_ms' "$out")" "$(jq -r '.decode_tok_s // "n/a"' "$out")" \
    "$(jq -r '.content_chars' "$out")" >&2

  if [[ $compare_direct == true ]]; then
    dout="${work}/direct-${run_i}.json"
    dwall="${work}/direct-${run_i}.wall"
    auth_header=''
    if ! chat_once "direct-run-${run_i}" "${OLLAMA_URL}/api/chat" "$body" "$dout" "$dwall"; then
      die "direct Ollama run ${run_i} failed: $(jq -c . "$dout")"
    fi
    samples_json=$(jq -c --slurpfile s "$dout" '. + $s' <<<"$samples_json")
    printf 'INFO: direct run %s wall_ms=%s decode_tok_s=%s chars=%s\n' \
      "$run_i" "$(jq -r '.wall_ms' "$dout")" "$(jq -r '.decode_tok_s // "n/a"' "$dout")" \
      "$(jq -r '.content_chars' "$dout")" >&2
  fi
  run_i=$((run_i + 1))
done

jq -nc \
  --arg schema_version '1' \
  --arg started_at "$ts" \
  --arg webui_url "$WEBUI_URL" \
  --arg ollama_url "$OLLAMA_URL" \
  --arg alias "$alias" \
  --arg model "$model" \
  --arg prompt "$prompt" \
  --arg think "$think" \
  --arg keep_alive "$keep_alive" \
  --argjson num_predict "$num_predict" \
  --argjson temperature "$temperature" \
  --argjson num_ctx "$num_ctx" \
  --argjson runs "$runs" \
  --argjson compare_direct "$compare_direct" \
  --argjson request "$body" \
  --argjson samples "$samples_json" \
  --arg markdown_path "$markdown" \
  '{
    schema_version: ($schema_version | tonumber),
    kind: "debug-webui-chat",
    path: "B",
    description: "Open WebUI /ollama/api/chat proxy (not browser UI Advanced Params)",
    started_at: $started_at,
    webui_url: $webui_url,
    ollama_url: $ollama_url,
    alias: $alias,
    model: $model,
    prompt: $prompt,
    think: $think,
    options: {num_predict: $num_predict, temperature: $temperature, num_ctx: $num_ctx},
    keep_alive: $keep_alive,
    runs: $runs,
    compare_direct: $compare_direct,
    request: $request,
    samples: $samples,
    summary_markdown_path: $markdown_path,
    notes: [
      "This exercises the WebUI→Ollama API hop with explicit think/options.",
      "Browser Advanced Params may still differ if the UI does not forward num_predict/think the same way.",
      "Use --think on vs off and --compare-direct to isolate parameter vs hop cost."
    ]
  }' >"$output"

{
  printf '# Path B debug — Open WebUI chat\n\n'
  printf -- '- Started: `%s`\n' "$ts"
  printf -- '- Model: `%s` (alias `%s`)\n' "$model" "$alias"
  printf -- '- Prompt: %s\n' "$prompt"
  printf -- '- think: `%s` · num_predict: `%s` · temperature: `%s` · num_ctx: `%s`\n' \
    "$think" "$num_predict" "$temperature" "$num_ctx"
  printf -- '- WebUI: `%s`\n' "$WEBUI_URL"
  printf -- '- JSON: `%s`\n\n' "$output"
  printf '| Label | Wall ms | Decode tok/s | Prompt tok/s | Eval tokens | Content chars | Thinking chars |\n'
  printf '| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n'
  jq -r '
    .samples[] |
    [
      .label,
      (.wall_ms // ""),
      (.decode_tok_s // ""),
      (.prompt_tok_s // ""),
      (.eval_count // ""),
      (.content_chars // ""),
      (.thinking_chars // "")
    ] | @tsv
  ' "$output" | while IFS=$'\t' read -r label wall decode prompt_tps evalc chars thinkc; do
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
      "$label" "$wall" "$decode" "$prompt_tps" "$evalc" "$chars" "$thinkc"
  done
  printf '\n## First WebUI reply (truncated)\n\n```\n'
  jq -r '
    [.samples[] | select(.label | startswith("webui-run-"))][0].content // ""
  ' "$output" | head -c 1200
  printf '\n```\n\n'
  printf 'Notes: Path B is the authenticated `/ollama/api/chat` proxy, not the browser Advanced Params panel. '
  printf 'If UI still feels slower with the same think/num_predict, inspect the live request body from browser DevTools.\n'
} >"$markdown"

printf 'PASS: wrote %s and %s\n' "$output" "$markdown"
