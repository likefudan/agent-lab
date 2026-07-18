#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
readonly MODELS_FILE="${AGENT_LAB_MODELS_FILE:-${REPO_ROOT}/config/models.json}"
readonly MODEL_STORE="${AGENT_LAB_MODEL_STORE:-${OLLAMA_MODELS:-${HOME}/.ollama/models}}"
readonly MANIFEST_ROOT="${MODEL_STORE}/manifests/registry.ollama.ai/library"
readonly BLOB_ROOT="${MODEL_STORE}/blobs"
readonly DISK_SAFETY_BYTES=$((2 * 1024 * 1024 * 1024))

usage() {
  cat <<'EOF'
Usage:
  agent-lab models list
  agent-lab models verify [ALIAS]
  agent-lab models pull [--yes] ALIAS

Only executable aliases from config/models.json may be pulled. Pull is disabled
when AGENT_LAB_PROFILE=offline or AGENT_LAB_OFFLINE=1.
EOF
}

require_catalog() {
  require_command jq
  [[ -r "$MODELS_FILE" ]] || die "model catalog is not readable: $MODELS_FILE"
  jq -e '.models | type == "array"' "$MODELS_FILE" >/dev/null ||
    die "model catalog has no models array: $MODELS_FILE"
}

model_json() {
  local alias=$1
  jq -ce --arg alias "$alias" '.models[] | select(.alias == $alias and .executable == true)' "$MODELS_FILE" |
    head -n 1
}

require_model_json() {
  local alias=$1
  local selected
  selected=$(model_json "$alias") || true
  [[ -n "$selected" ]] || die "unknown or non-executable model alias: $alias"
  printf '%s\n' "$selected"
}

manifest_path_for_tag() {
  local tag=$1
  local model_name tag_name
  [[ "$tag" =~ ^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$ ]] ||
    die "unsupported Ollama tag shape in catalog: $tag" || return 1
  model_name=${tag%%:*}
  tag_name=${tag#*:}
  printf '%s/%s/%s\n' "$MANIFEST_ROOT" "$model_name" "$tag_name"
}

digest_file() {
  shasum -a 256 "$1" | awk '{print "sha256:" $1}'
}

blob_path_for_digest() {
  local digest=$1
  printf '%s/%s\n' "$BLOB_ROOT" "${digest/:/-}"
}

verify_model_object() {
  local model=$1
  local alias tag expected_manifest manifest actual_manifest
  local blob_digest blob_size blob_path actual_blob
  alias=$(jq -r '.alias' <<<"$model")
  tag=$(jq -r '.tag' <<<"$model")
  expected_manifest=$(jq -r '.manifest_digest' <<<"$model")
  manifest=$(manifest_path_for_tag "$tag")

  [[ -f "$manifest" ]] || {
    error "unavailable model: $alias ($tag); local manifest is missing"
    return 1
  }
  actual_manifest=$(digest_file "$manifest")
  [[ "$actual_manifest" == "$expected_manifest" ]] || {
    error "manifest digest mismatch for $alias: expected $expected_manifest, got $actual_manifest"
    return 1
  }

  while IFS=$'\t' read -r blob_digest blob_size; do
    [[ -n "$blob_digest" ]] || continue
    blob_path=$(blob_path_for_digest "$blob_digest")
    [[ -f "$blob_path" ]] || {
      error "missing model blob for $alias: $blob_digest"
      return 1
    }
    actual_blob=$(wc -c <"$blob_path" | tr -d ' ')
    [[ "$actual_blob" == "$blob_size" ]] || {
      error "model blob size mismatch for $alias: $blob_digest expected $blob_size, got $actual_blob"
      return 1
    }
    [[ "$(digest_file "$blob_path")" == "$blob_digest" ]] || {
      error "model blob digest mismatch for $alias: $blob_digest"
      return 1
    }
  done < <(jq -r '.blobs[] | [.digest, (.size | tostring)] | @tsv' <<<"$model")

  printf 'verified %s -> %s (%s)\n' "$alias" "$tag" "$expected_manifest"
}

list_models() {
  local row alias tag status manifest expected actual
  printf 'ALIAS\tTAG\tLOCAL STATUS\n'
  while IFS= read -r row; do
    alias=$(jq -r '.alias' <<<"$row")
    tag=$(jq -r '.tag' <<<"$row")
    expected=$(jq -r '.manifest_digest' <<<"$row")
    manifest=$(manifest_path_for_tag "$tag")
    status=missing
    if [[ -f "$manifest" ]]; then
      actual=$(digest_file "$manifest")
      if [[ "$actual" == "$expected" ]]; then
        status=verified
      else
        status=digest-mismatch
      fi
    fi
    printf '%s\t%s\t%s\n' "$alias" "$tag" "$status"
  done < <(jq -c '.models[] | select(.executable == true)' "$MODELS_FILE")
}

verify_models() {
  local alias=${1:-}
  local model failures=0 count=0
  if [[ -n "$alias" ]]; then
    model=$(require_model_json "$alias")
    verify_model_object "$model"
    return
  fi

  while IFS= read -r model; do
    count=$((count + 1))
    verify_model_object "$model" || failures=$((failures + 1))
  done < <(jq -c '.models[] | select(.executable == true)' "$MODELS_FILE")
  [[ "$count" -gt 0 ]] || die 'model catalog contains no executable models'
  [[ "$failures" -eq 0 ]] || die "$failures approved model verification check(s) failed"
}

available_bytes() {
  if [[ -n "${AGENT_LAB_AVAILABLE_BYTES:-}" ]]; then
    printf '%s\n' "$AGENT_LAB_AVAILABLE_BYTES"
    return
  fi
  df -Pk "${MODEL_STORE%/models}" | awk 'NR == 2 { print $4 * 1024 }'
}

pull_model() {
  local assume_yes=$1
  local alias=$2
  local model tag expected_bytes required_bytes free_bytes

  case "${AGENT_LAB_PROFILE:-}" in
    offline) die 'model pulls are prohibited by the offline profile' || return 1 ;;
  esac
  [[ "${AGENT_LAB_OFFLINE:-0}" != 1 ]] ||
    die 'model pulls are prohibited while AGENT_LAB_OFFLINE=1' || return 1

  model=$(require_model_json "$alias")
  tag=$(jq -r '.tag' <<<"$model")
  if verify_model_object "$model" >/dev/null 2>&1; then
    printf 'already verified %s -> %s\n' "$alias" "$tag"
    return 0
  fi

  expected_bytes=$(jq -r '.artifact_bytes' <<<"$model")
  required_bytes=$((expected_bytes + DISK_SAFETY_BYTES))
  free_bytes=$(available_bytes)
  [[ "$free_bytes" =~ ^[0-9]+$ ]] || die 'could not determine available disk space' || return 1
  (( free_bytes >= required_bytes )) || {
    die "insufficient disk space for $alias: need at least $required_bytes bytes, have $free_bytes"
    return 1
  }

  if [[ "$assume_yes" != true ]]; then
    confirm "Pull $alias ($tag), approximately $expected_bytes bytes?" no ||
      die 'model pull was not confirmed' || return 1
  fi

  require_command ollama
  ollama pull "$tag"
  verify_model_object "$model" || {
    error "pulled artifact for $alias did not match the approved catalog; it was preserved for inspection"
    return 1
  }
}

require_catalog
require_command shasum

[[ $# -gt 0 ]] || { usage >&2; exit 64; }
subcommand=$1
shift

case "$subcommand" in
  list)
    [[ $# -eq 0 ]] || { usage >&2; exit 64; }
    list_models
    ;;
  verify)
    [[ $# -le 1 ]] || { usage >&2; exit 64; }
    verify_models "${1:-}"
    ;;
  pull)
    assume_yes=false
    if [[ ${1:-} == --yes ]]; then
      assume_yes=true
      shift
    fi
    [[ $# -eq 1 ]] || { usage >&2; exit 64; }
    pull_model "$assume_yes" "$1"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    die "unknown models subcommand: $subcommand"
    exit 64
    ;;
esac
