#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly TEMPLATE="${ROOT}/.env.example"
readonly PLACEHOLDER='replace-with-generated-64-character-hex-secret'
readonly ADMIN_PLACEHOLDER='replace-with-generated-32-character-hex-password'

usage() {
  cat <<'EOF'
Usage: config/open-webui/generate-env.sh [--output PATH]

Create a private Open WebUI environment file from .env.example. The default
output is the repository's ignored .env file. Existing files are not replaced.
EOF
}

output="${ROOT}/.env"
case $# in
  0) ;;
  1)
    case $1 in
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  2)
    [[ $1 == --output ]] || { usage >&2; exit 64; }
    output=$2
    ;;
  *) usage >&2; exit 64 ;;
esac

[[ -r "$TEMPLATE" ]] || {
  printf 'ERROR: environment template is not readable: %s\n' "$TEMPLATE" >&2
  exit 1
}
[[ ! -e "$output" ]] || {
  printf 'ERROR: refusing to overwrite existing environment file: %s\n' "$output" >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: openssl is required to generate WEBUI_SECRET_KEY' >&2
  exit 1
}

output_dir=$(dirname "$output")
[[ -d "$output_dir" ]] || {
  printf 'ERROR: output directory does not exist: %s\n' "$output_dir" >&2
  exit 1
}

umask 077
temporary=$(mktemp "${output}.tmp.XXXXXX")
cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

secret=$(openssl rand -hex 32)
admin_password=$(openssl rand -hex 16)
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ $line == "WEBUI_SECRET_KEY=${PLACEHOLDER}" ]]; then
    printf 'WEBUI_SECRET_KEY=%s\n' "$secret"
  elif [[ $line == "WEBUI_ADMIN_PASSWORD=${ADMIN_PLACEHOLDER}" ]]; then
    printf 'WEBUI_ADMIN_PASSWORD=%s\n' "$admin_password"
  else
    printf '%s\n' "$line"
  fi
done < "$TEMPLATE" > "$temporary"

chmod 600 "$temporary"
mv "$temporary" "$output"
trap - EXIT HUP INT TERM
printf 'Created private environment file: %s\n' "$output"
