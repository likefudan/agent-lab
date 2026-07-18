#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly ENV_FILE="${ROOT}/.env"
readonly VOLUME='agent-lab-open-webui-data'

usage() {
  cat <<'EOF'
Usage: agent-lab setup [--model ALIAS]

Validate Agent Lab configuration and optionally pull one approved model alias.
Model setup is intentionally serial and asks for confirmation before download.
EOF
}

model_alias=
case $# in
  0) ;;
  1)
    case $1 in
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  2)
    [[ $1 == --model ]] || { usage >&2; exit 64; }
    model_alias=$2
    ;;
  *) usage >&2; exit 64 ;;
esac

"${SCRIPT_DIR}/validate-config.sh"

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: Docker CLI is required for Open WebUI setup' >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: Docker engine is stopped or unavailable' >&2
  exit 1
}

if [[ ! -e "$ENV_FILE" ]]; then
  "${ROOT}/config/open-webui/generate-env.sh"
else
  [[ -f "$ENV_FILE" && -r "$ENV_FILE" ]] || {
    printf 'ERROR: existing environment path is not a readable file: %s\n' "$ENV_FILE" >&2
    exit 1
  }
  printf 'Preserving existing private environment file: %s\n' "$ENV_FILE"
fi

if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  printf 'Preserving existing Open WebUI data volume: %s\n' "$VOLUME"
else
  docker volume create "$VOLUME" >/dev/null
  printf 'Created Open WebUI data volume: %s\n' "$VOLUME"
fi

if [[ -n "$model_alias" ]]; then
  "${SCRIPT_DIR}/models.sh" pull "$model_alias"
else
  printf '%s\n' 'Setup is complete. No model was requested.'
fi
