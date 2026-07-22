#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CATALOG="$ROOT/config/mlx/models.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

jq -e '
  .schema_version == 1 and
  (.models | length) == 2 and
  (all(.models[];
    (.revision | test("^[0-9a-f]{40}$")) and
    (.artifact_bytes == ([.files[].bytes] | add)) and
    all(.files[]; (.sha256 | test("^[0-9a-f]{64}$"))))) and
  ([.models[].backend] | sort) == ["chat","vision"] and
  (.models[] | select(.backend == "vision") | .capabilities.vision) == true
' "$CATALOG" >/dev/null || fail 'MLX model catalog is not immutable and internally consistent'

grep -Fxq 'mlx-lm==0.31.3' "$ROOT/config/mlx/requirements.txt" || fail 'MLX-LM is not pinned'
grep -Fxq 'mlx-vlm==0.6.6' "$ROOT/config/mlx/requirements.txt" || fail 'MLX-VLM is not pinned'
grep -Fxq 'huggingface-hub[hf_xet]==1.24.0' "$ROOT/config/mlx/requirements.txt" || fail 'Hugging Face Hub is not pinned'

for backend in lm vlm; do
  template="$ROOT/config/mlx/ai.agent-lab.mlx-$backend.plist.template"
  plutil -lint "$template" >/dev/null || fail "invalid $backend launch template"
  grep -q '<string>127.0.0.1</string>' "$template" || fail "$backend is not loopback-only"
  grep -A1 -q '<key>HF_HUB_OFFLINE</key>' "$template" || fail "$backend does not force offline model loading"
done

temporary_home=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-mlx-static.XXXXXX")
trap 'rm -rf -- "$temporary_home"' EXIT HUP INT TERM
HOME="$temporary_home" python3 "$ROOT/scripts/mlx-models.py" list >/dev/null ||
  fail 'MLX model catalog tool cannot inspect an empty cache safely'

printf '%s\n' 'PASS: pinned, loopback-only, mutually switched MLX configuration'
