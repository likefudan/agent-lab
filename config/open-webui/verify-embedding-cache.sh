#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER="${OPEN_WEBUI_CONTAINER:-agent-lab-open-webui-1}"
readonly REVISION='1110a243fdf4706b3f48f1d95db1a4f5529b4d41'
readonly MODEL_ROOT='/app/backend/data/cache/embedding/models/models--sentence-transformers--all-MiniLM-L6-v2'

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'FAIL: Docker CLI is required' >&2
  exit 1
}

docker exec "$CONTAINER" test -f "${MODEL_ROOT}/snapshots/${REVISION}/modules.json" || {
  printf 'FAIL: pinned embedding snapshot %s is not cached\n' "$REVISION" >&2
  exit 1
}

printf 'PASS: embedding snapshot %s is cached locally\n' "$REVISION"
