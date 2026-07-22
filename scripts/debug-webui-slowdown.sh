#!/usr/bin/env bash
# Isolate which Open WebUI chat options slow the UI (same prompt, Path B-style
# POST /api/chat/completions with controlled features / background_tasks).
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WEBUI_URL="${OPEN_WEBUI_URL:-http://127.0.0.1:3000}"
readonly PROMPT="${PROMPT:-世界杯是什么？}"
readonly MODEL="${MODEL:-qwen3.5:4b}"
readonly RESULTS_DIR="${ROOT}/.agent-lab/results"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is required"; }

need curl; need jq; need python3
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup first'
curl --fail --silent --max-time 5 "${WEBUI_URL}/health" >/dev/null ||
  fail "Open WebUI not healthy (bin/agent-lab start)"

admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")
auth=$(curl --fail --silent --show-error --max-time 30 \
  -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" \
    '{email:$email,password:$password}')" \
  "${WEBUI_URL}/api/v1/auths/signin") || fail 'sign-in failed'
token=$(jq -er '.token' <<<"$auth") || fail 'no token'

mkdir -p "$RESULTS_DIR"
ts=$(date -u +%Y%m%dT%H%M%SZ)
out_json="${RESULTS_DIR}/debug-webui-slowdown-${ts}.json"
out_md="${RESULTS_DIR}/debug-webui-slowdown-${ts}.md"
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-slowdown.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

now_ms() { python3 - <<'PY'
import time; print(int(time.time()*1000))
PY
}

# Warm model once (baseline body, no background tasks)
warm_body=$(jq -cn --arg model "$MODEL" --arg prompt "$PROMPT" '{
  stream:false,
  model:$model,
  params:{think:false, temperature:0, max_tokens:256, num_ctx:4096},
  features:{voice:false,image_generation:false,code_interpreter:false,web_search:false,memory:false},
  background_tasks:{title_generation:false,tags_generation:false,follow_up_generation:false},
  messages:[{role:"user",content:$prompt}]
}')
printf 'INFO: warming %s via /api/chat/completions\n' "$MODEL" >&2
curl --fail --silent --show-error --max-time 300 \
  -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
  --data "$warm_body" "${WEBUI_URL}/api/chat/completions" >/dev/null ||
  fail 'warm-up failed'
sleep 1

run_case() {
  local name=$1 think=$2 memory=$3 title=$4 tags=$5 follow=$6 max_tokens=${7:-256}
  local body tmp started ended http_code wall
  tmp="${work}/${name}.bin"
  body=$(jq -cn \
    --arg model "$MODEL" --arg prompt "$PROMPT" \
    --argjson think "$think" --argjson memory "$memory" \
    --argjson title "$title" --argjson tags "$tags" --argjson follow "$follow" \
    --argjson max_tokens "$max_tokens" \
    '{
      stream:true,
      model:$model,
      params:{think:$think, temperature:0, max_tokens:$max_tokens, num_ctx:4096, keep_alive:"5m"},
      features:{voice:false,image_generation:false,code_interpreter:false,web_search:false,memory:$memory},
      background_tasks:{title_generation:$title, tags_generation:$tags, follow_up_generation:$follow},
      messages:[{role:"user",content:$prompt}]
    }')
  started=$(now_ms)
  http_code=$(curl --silent --show-error --output "$tmp" --write-out '%{http_code}' \
    --max-time 600 \
    -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
    --data "$body" "${WEBUI_URL}/api/chat/completions") || true
  ended=$(now_ms)
  wall=$((ended - started))
  # Give async background tasks a moment to contend for Ollama if they started.
  if [[ $title == true || $tags == true || $follow == true ]]; then
    sleep 2
  fi
  python3 - "$name" "$wall" "$http_code" "$tmp" "$think" "$memory" "$title" "$tags" "$follow" <<'PY'
import json, sys
name, wall, code, path, think, memory, title, tags, follow = sys.argv[1:10]
wall, code = int(wall), int(code)
raw = open(path, encoding="utf-8", errors="replace").read()
chars = 0
# SSE or JSON
if raw.lstrip().startswith("{"):
    try:
        obj = json.loads(raw)
        err = obj.get("detail") or obj.get("error")
        if err:
            print(json.dumps({"name":name,"ok":False,"http_code":code,"wall_ms":wall,"error":str(err)[:300]}))
            raise SystemExit
        choices = obj.get("choices") or []
        if choices:
            msg = choices[0].get("message") or {}
            chars = len(msg.get("content") or "")
    except json.JSONDecodeError:
        pass
else:
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload in ("", "[DONE]"):
            continue
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue
        for ch in obj.get("choices") or []:
            delta = ch.get("delta") or {}
            if delta.get("content"):
                chars += len(delta["content"])
            msg = ch.get("message") or {}
            if msg.get("content"):
                chars = max(chars, len(msg["content"]))
print(json.dumps({
    "name": name,
    "ok": code == 200,
    "http_code": code,
    "wall_ms": wall,
    "content_chars": chars,
    "think": think == "true",
    "memory": memory == "true",
    "title_generation": title == "true",
    "tags_generation": tags == "true",
    "follow_up_generation": follow == "true",
}, ensure_ascii=False))
PY
}

samples='[]'
# name think memory title tags follow
cases=(
  'baseline|false|false|false|false|false'
  'think_on|true|false|false|false|false'
  'memory_on|false|true|false|false|false'
  'title_only|false|false|true|false|false'
  'tags_only|false|false|false|true|false'
  'followup_only|false|false|false|false|true'
  'all_background|false|false|true|true|true'
  'worst_combo|false|true|true|true|true'
)

printf 'INFO: prompt=%s model=%s\n' "$PROMPT" "$MODEL" >&2
for spec in "${cases[@]}"; do
  IFS='|' read -r name think memory title tags follow <<<"$spec"
  printf 'INFO: case=%s think=%s memory=%s title=%s tags=%s follow=%s\n' \
    "$name" "$think" "$memory" "$title" "$tags" "$follow" >&2
  row=$(run_case "$name" "$think" "$memory" "$title" "$tags" "$follow")
  samples=$(jq -c --argjson row "$row" '. + [$row]' <<<"$samples")
  printf 'INFO:   wall_ms=%s ok=%s chars=%s\n' \
    "$(jq -r '.wall_ms' <<<"$row")" "$(jq -r '.ok' <<<"$row")" "$(jq -r '.content_chars' <<<"$row")" >&2
  # unload pressure between heavy cases
  sleep 1
done

baseline=$(jq '[.[] | select(.name=="baseline" and .ok==true)][0].wall_ms // 0' <<<"$samples")
jq -nc \
  --arg started_at "$ts" \
  --arg prompt "$PROMPT" \
  --arg model "$MODEL" \
  --argjson baseline_ms "$baseline" \
  --argjson samples "$samples" \
  --arg markdown_path "$out_md" \
  '{
    schema_version:1,
    kind:"debug-webui-slowdown",
    started_at:$started_at,
    prompt:$prompt,
    model:$model,
    baseline_wall_ms:$baseline_ms,
    samples:$samples,
    summary_markdown_path:$markdown_path,
    notes:[
      "Times are wall clock for POST /api/chat/completions stream until the HTTP body finishes.",
      "Background tasks may continue after the main stream; +2s settle wait when any background flag is true.",
      "With OLLAMA_MAX_LOADED_MODELS=1, extra task generations contend for the same model slot."
    ]
  }' >"$out_json"

{
  printf '# Open WebUI slowdown isolation\n\n'
  printf -- '- Prompt: %s\n' "$PROMPT"
  printf -- '- Model: `%s`\n' "$MODEL"
  printf -- '- Baseline wall: `%s` ms\n\n' "$baseline"
  printf '| Case | Wall ms | Δ vs baseline | Think | Memory | Title | Tags | Follow-up | OK |\n'
  printf '| --- | ---: | ---: | --- | --- | --- | --- | --- | --- |\n'
  jq -r --argjson b "$baseline" '
    .samples[] |
    [
      .name,
      .wall_ms,
      (if $b > 0 then (((.wall_ms - $b) * 100 / $b) | floor | tostring) + "%" else "n/a" end),
      .think, .memory, .title_generation, .tags_generation, .follow_up_generation, .ok
    ] | @tsv
  ' "$out_json" | while IFS=$'\t' read -r n w d th mem ti ta fo ok; do
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "$n" "$w" "$d" "$th" "$mem" "$ti" "$ta" "$fo" "$ok"
  done
  printf '\nHigher wall_ms / Δ means that flag combination is slower. Prefer the Agent Lab defaults (baseline).\n'
} >"$out_md"

printf 'PASS: wrote %s and %s\n' "$out_json" "$out_md"
# Print table to stdout for the operator
cat "$out_md"
