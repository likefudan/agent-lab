#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-benchmark-test.XXXXXX")
trap 'rm -rf -- "$TEMP_ROOT"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

plan="$TEMP_ROOT/plan.json"
"$ROOT/scripts/benchmark.sh" --dry-run --runs 2 --models qwen3.5:4b,gemma4:12b --output "$plan" >/dev/null
"$ROOT/scripts/benchmark.sh" --validate "$plan" >/dev/null
jq -e '.status == "dry-run" and .configuration.runs == 2 and (.configuration.models|length) == 2 and
  (.model_manifests|length) == 2 and (.model_manifests | has("qwen3.5:9b") | not) and
  (.samples|length) == 0' "$plan" >/dev/null ||
  fail 'benchmark dry-run schema or plan is incorrect'

if "$ROOT/scripts/benchmark.sh" --compare "$plan" "$plan" >/dev/null 2>&1; then
  fail 'comparison accepted dry-run plans'
fi

result="$TEMP_ROOT/result.json"
jq '.kind="agent-lab-native-benchmark" | .status="pass" |
  .samples=[{model:"qwen3.5:4b",status:"pass"},{model:"gemma4:12b",status:"pass"}] |
  .summary=[
    {model:"qwen3.5:4b",median_tokens_per_second:10,median_total_latency_ms:1000},
    {model:"gemma4:12b",median_tokens_per_second:5,median_total_latency_ms:2000}
  ]' "$plan" > "$result"
same="$TEMP_ROOT/same.json"
cp "$result" "$same"
"$ROOT/scripts/benchmark.sh" --compare "$result" "$same" >/dev/null || fail 'matching completed benchmark comparison failed'
mismatch="$TEMP_ROOT/mismatch.json"
jq '.model_manifests["qwen3.5:4b"] = "sha256:mismatch"' "$result" > "$mismatch"
if "$ROOT/scripts/benchmark.sh" --compare "$result" "$mismatch" >/dev/null 2>&1; then
  fail 'comparison accepted mismatched model digests'
fi
configuration_mismatch="$TEMP_ROOT/configuration-mismatch.json"
jq '.configuration.num_ctx = 8192' "$result" > "$configuration_mismatch"
if "$ROOT/scripts/benchmark.sh" --compare "$result" "$configuration_mismatch" >/dev/null 2>&1; then
  fail 'comparison accepted mismatched benchmark configuration'
fi

if "$ROOT/scripts/benchmark.sh" --dry-run --runs 0 --output "$TEMP_ROOT/bad.json" >/dev/null 2>&1; then
  fail 'benchmark accepted zero runs'
fi

printf '%s\n' 'PASS: benchmark dry run, schema validation, and digest-safe comparison'
