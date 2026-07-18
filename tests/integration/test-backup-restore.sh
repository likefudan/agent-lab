#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly IMAGE='ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4'
readonly TEST_CONTAINER="agent-lab-restore-test-$$"
readonly TEST_VOLUME="agent-lab-restore-test-$$"
TEMP_ROOT=
chat_id=
file_id=
token=

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sign_in() {
  local url=$1 auth
  auth=$(curl --fail --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg email "$admin_email" --arg password "$admin_password" '{email:$email,password:$password}')" \
    "$url/api/v1/auths/signin") || fail "sign-in failed at $url"
  token=$(jq -er '.token' <<<"$auth") || fail 'sign-in returned no token'
}

cleanup() {
  docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$TEST_VOLUME" >/dev/null 2>&1 || true
  if [[ -n ${chat_id:-} || -n ${file_id:-} ]]; then
    sign_in http://127.0.0.1:3000 >/dev/null 2>&1 || true
    [[ -z ${chat_id:-} ]] || curl --silent -X DELETE -H "Authorization: Bearer ${token}" \
      "http://127.0.0.1:3000/api/v1/chats/${chat_id}" >/dev/null 2>&1 || true
    [[ -z ${file_id:-} ]] || curl --silent -X DELETE -H "Authorization: Bearer ${token}" \
      "http://127.0.0.1:3000/api/v1/files/${file_id}" >/dev/null 2>&1 || true
  fi
  [[ -z ${TEMP_ROOT:-} ]] || rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || fail 'Docker CLI is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
command -v curl >/dev/null 2>&1 || fail 'curl is required'
[[ -f "${ROOT}/.env" ]] || fail 'run bin/agent-lab setup first'
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-backup-test.XXXXXX")
backup_dir="${TEMP_ROOT}/backup with spaces"
config_dir="${TEMP_ROOT}/restored config"
mkdir -p "$backup_dir" "$config_dir"
admin_email=$(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "${ROOT}/.env")
admin_password=$(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "${ROOT}/.env")
webui_secret=$(sed -n 's/^WEBUI_SECRET_KEY=//p' "${ROOT}/.env")

sign_in http://127.0.0.1:3000
marker="backup-persistence-$(date +%s)"
chat=$(curl --fail --silent --show-error -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${token}" \
  --data "$(jq -cn --arg marker "$marker" '{chat:{title:"Backup restore smoke",messages:[{id:"backup-user",role:"user",content:$marker,timestamp:0}],models:["qwen3.5:4b"],history:{messages:{},currentId:null}}}')" \
  http://127.0.0.1:3000/api/v1/chats/new)
chat_id=$(jq -er '.id' <<<"$chat") || fail 'failed to create backup test chat'
upload=$(curl --fail --silent --show-error --max-time 180 -H "Authorization: Bearer ${token}" \
  -F "file=@${ROOT}/tests/fixtures/rag/operations.md" \
  'http://127.0.0.1:3000/api/v1/files/?process=true&process_in_background=false')
file_id=$(jq -er '.id' <<<"$upload") || fail 'failed to create backup test RAG file'

backup_output=$("${ROOT}/scripts/backup.sh" --destination "$backup_dir") || fail 'live backup failed'
archive=$(sed -n 's/^Backup created: //p' <<<"$backup_output")
[[ -f $archive && -f $archive.sha256 ]] || fail 'backup archive or outer checksum is missing'
(cd "$(dirname "$archive")" && shasum -a 256 -c "$(basename "$archive").sha256" >/dev/null) ||
  fail 'outer backup checksum verification failed'

"${ROOT}/scripts/restore.sh" --archive "$archive" --target-volume "$TEST_VOLUME" \
  --config-destination "$config_dir" >/dev/null || fail 'safe restore failed'
[[ -f "$config_dir/config/components.json" && -f "$config_dir/compose.yaml" ]] ||
  fail 'versioned configuration was not restored'

docker run --detach --name "$TEST_CONTAINER" \
  -p 127.0.0.1:3001:8080 -v "$TEST_VOLUME:/app/backend/data" \
  -e "WEBUI_SECRET_KEY=$webui_secret" -e WEBUI_AUTH=true -e ENABLE_SIGNUP=false \
  -e OFFLINE_MODE=true -e RAG_EMBEDDING_MODEL_AUTO_UPDATE=false \
  -e RAG_RERANKING_MODEL_AUTO_UPDATE=false -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  "$IMAGE" >/dev/null
for _ in {1..120}; do
  curl --fail --silent --max-time 2 http://127.0.0.1:3001/health >/dev/null 2>&1 && break
  sleep 1
done
curl --fail --silent --max-time 2 http://127.0.0.1:3001/health >/dev/null || fail 'restored test instance did not become healthy'
sign_in http://127.0.0.1:3001
restored_chat=$(curl --fail --silent --show-error -H "Authorization: Bearer ${token}" \
  "http://127.0.0.1:3001/api/v1/chats/${chat_id}")
[[ $(jq -r '.chat.messages[0].content' <<<"$restored_chat") == "$marker" ]] ||
  fail 'conversation did not survive backup and restore'
query=$(jq -cn --arg collection "file-$file_id" '{collection_names:[$collection],query:"Atlas battery preservation percentage and token",k:3,hybrid:true}')
retrieval=$(curl --fail --silent --show-error --max-time 120 -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${token}" --data "$query" \
  http://127.0.0.1:3001/api/v1/retrieval/query/collection)
jq -e '[.documents[0][]] | join(" ") | contains("ASTER-4821")' <<<"$retrieval" >/dev/null ||
  fail 'RAG vectors did not survive backup and restore'

if "${ROOT}/scripts/restore.sh" --archive "$archive" --target-volume agent-lab-open-webui-data >/dev/null 2>&1; then
  fail 'restore accepted the live volume name'
fi
if "${ROOT}/scripts/restore.sh" --archive "$archive" --target-volume "$TEST_VOLUME" >/dev/null 2>&1; then
  fail 'restore accepted an existing target volume'
fi
corrupt="${TEMP_ROOT}/corrupt.tar.gz"
cp "$archive" "$corrupt"
printf 'damage' | dd of="$corrupt" bs=1 seek=128 conv=notrunc 2>/dev/null
if "${ROOT}/scripts/restore.sh" --archive "$corrupt" --target-volume "${TEST_VOLUME}-corrupt" >/dev/null 2>&1; then
  fail 'restore accepted a corrupted outer archive'
fi

version_dir="${TEMP_ROOT}/version-mismatch"
mkdir -p "$version_dir"
tar -xzf "$archive" -C "$version_dir"
jq '.components.open_webui.version = "0.0.0-incompatible"' "$version_dir/manifest.json" > "$version_dir/manifest.new"
mv "$version_dir/manifest.new" "$version_dir/manifest.json"
version_archive="${TEMP_ROOT}/version-mismatch.tar.gz"
tar -czf "$version_archive" -C "$version_dir" manifest.json open-webui-data.tar.gz configuration.tar.gz
if "${ROOT}/scripts/restore.sh" --archive "$version_archive" --target-volume "${TEST_VOLUME}-version" >/dev/null 2>&1; then
  fail 'restore accepted an incompatible Open WebUI version'
fi

traversal_dir="${TEMP_ROOT}/traversal"
mkdir -p "$traversal_dir"
printf 'unsafe' > "$traversal_dir/safe"
traversal_archive="${TEMP_ROOT}/traversal.tar.gz"
tar -czf "$traversal_archive" -s ',safe,../escape,' -C "$traversal_dir" safe
if "${ROOT}/scripts/restore.sh" --archive "$traversal_archive" --target-volume "${TEST_VOLUME}-traversal" >/dev/null 2>&1; then
  fail 'restore accepted a path-traversal archive'
fi

printf '%s\n' 'PASS: consistent backup, validated safe restore, chat persistence, and RAG persistence'
