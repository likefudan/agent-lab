#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CLI="$ROOT/bin/agent-lab"
readonly IMAGE="$ROOT/tests/fixtures/rag/vision-card.png"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  "$CLI" mlx start chat >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

python3 "$ROOT/scripts/mlx-models.py" verify --quick qwen-9b-mlx >/dev/null
python3 "$ROOT/scripts/mlx-models.py" verify --quick gemma-12b-mlx >/dev/null

"$CLI" mlx start chat >/dev/null
chat=$(curl --fail --silent --show-error --max-time 180 \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"Reply with exactly MLX-LM-OK"}],"temperature":0,"max_tokens":32,"stream":false}' \
  http://127.0.0.1:8081/v1/chat/completions | jq -er '.choices[0].message.content')
[[ $chat == 'MLX-LM-OK' ]] || fail "unexpected MLX-LM response: $chat"

code_repair=$(curl --fail --silent --show-error --max-time 180 \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"Repair this Python function. Return only the corrected code, without a Markdown fence:\n\ndef add(a, b):\n    return a - b"}],"temperature":0,"max_tokens":128,"stream":false}' \
  http://127.0.0.1:8081/v1/chat/completions | jq -er '.choices[0].message.content')
[[ $code_repair == *'return a + b'* ]] || fail "MLX-LM did not repair the code: $code_repair"

tool_call=$(curl --fail --silent --show-error --max-time 180 \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"What is the weather in Paris? Use the tool."}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"required","temperature":0,"max_tokens":128,"stream":false}' \
  http://127.0.0.1:8081/v1/chat/completions)
jq -e '.choices[0].finish_reason == "tool_calls" and
  .choices[0].message.tool_calls[0].function.name == "get_weather" and
  (.choices[0].message.tool_calls[0].function.arguments | fromjson | .city == "Paris")' \
  <<<"$tool_call" >/dev/null || fail 'MLX-LM did not return the required function call'

"$CLI" mlx start vision >/dev/null
status_output=$("$CLI" mlx status)
[[ $status_output == *$'chat\tstopped'* && $status_output == *$'vision\trunning'* ]] ||
  fail 'starting vision did not stop the chat backend'

image_data=$(base64 <"$IMAGE" | tr -d '\n')
vision_model=$(python3 "$ROOT/scripts/mlx-models.py" path gemma-12b-mlx)
request=$(jq -cn --arg image "data:image/png;base64,$image_data" --arg model "$vision_model" '{
  model:$model,messages:[{role:"user",content:[
    {type:"text",text:"Read the large code shown in this image. Reply with only that code."},
    {type:"image_url",image_url:{url:$image}}]}],
  temperature:0,max_tokens:64,stream:false}')
vision=$(curl --fail --silent --show-error --max-time 180 \
  -H 'Content-Type: application/json' --data "$request" \
  http://127.0.0.1:8082/v1/chat/completions | jq -er '.choices[0].message.content')
[[ $vision == *'PIXEL-6158'* ]] || fail "Gemma did not read the image code: $vision"

printf '%s\n' 'PASS: MLX-LM text/code/tools, exclusive backend switching, and MLX-VLM image input'
