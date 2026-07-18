#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
readonly IMAGE='ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4'
readonly LIVE_VOLUME='agent-lab-open-webui-data'
readonly VOLUME="${AGENT_LAB_BACKUP_VOLUME:-$LIVE_VOLUME}"
readonly ENV_FILE="$REPO_ROOT/.env"
readonly COMPOSE_FILE="$REPO_ROOT/compose.yaml"
STAGING=
RESTART_WEBUI=false

usage() {
    cat <<'EOF'
Usage: agent-lab backup --destination DIRECTORY

Create a consistent, sensitive backup archive in an explicit directory.
Model weights and caches are reproducible and are not included.
EOF
}

cleanup() {
    if [[ $RESTART_WEBUI == true ]]; then
        docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" up --detach --no-build open-webui >/dev/null 2>&1 || true
    fi
    [[ -z $STAGING ]] || rm -rf -- "$STAGING"
}
trap cleanup EXIT HUP INT TERM

destination=
while (($#)); do
    case $1 in
        --destination) [[ $# -ge 2 ]] || die '--destination needs a value'; destination=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown backup option: $1"; exit 64 ;;
    esac
done
[[ -n $destination ]] || { usage >&2; die 'an explicit --destination is required'; exit 64; }
require_command docker
require_command jq
require_command shasum
require_command tar
[[ -d $destination && -w $destination ]] || die "backup destination is not a writable directory: $destination" || exit 1
destination=$(cd "$destination" && pwd -P)
case "$destination/" in
    "$REPO_ROOT/.agent-lab/"*|"$REPO_ROOT/open-webui-data/"*)
        die 'backup destination must be outside ignored Agent Lab runtime data'; exit 1 ;;
esac
docker info >/dev/null 2>&1 || die 'Docker engine is unavailable' || exit 1
docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "Open WebUI data volume is missing: $VOLUME" || exit 1

volume_kb=$(docker run --rm --entrypoint sh -v "$VOLUME:/source:ro" "$IMAGE" -c 'du -sk /source | cut -f1')
available_kb=$(df -Pk "$destination" | awk 'NR == 2 {print $4}')
required_kb=$((volume_kb + 102400))
((available_kb >= required_kb)) || die "insufficient free space: need at least ${required_kb} KiB" || exit 1

if [[ $VOLUME == "$LIVE_VOLUME" ]] && docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" ps --status running --quiet open-webui | grep -q .; then
    docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" stop --timeout 30 open-webui >/dev/null
    RESTART_WEBUI=true
fi

STAGING=$(mktemp -d "$destination/.agent-lab-backup.XXXXXX")
chmod 700 "$STAGING"
docker run --rm --entrypoint sh -v "$VOLUME:/source:ro" -v "$STAGING:/backup" "$IMAGE" \
    -c 'cd /source && tar -czf /backup/open-webui-data.tar.gz .'
config_inputs=(compose.yaml config .env.example)
[[ ! -f "$ENV_FILE" ]] || config_inputs+=(.env)
tar -czf "$STAGING/configuration.tar.gz" -C "$REPO_ROOT" "${config_inputs[@]}"

data_sha=$(shasum -a 256 "$STAGING/open-webui-data.tar.gz" | awk '{print $1}')
config_sha=$(shasum -a 256 "$STAGING/configuration.tar.gz" | awk '{print $1}')
profile=$(sed -n 's/^AGENT_LAB_PROFILE=//p' "$ENV_FILE" 2>/dev/null || true)
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n \
    --arg timestamp "$timestamp" --arg profile "${profile:-offline}" --arg volume "$VOLUME" \
    --arg open_webui_version "$(jq -r '.components[] | select(.id == "open-webui") | .version' "$REPO_ROOT/config/components.json")" \
    --arg open_webui_image "$IMAGE" --arg data_sha "$data_sha" --arg config_sha "$config_sha" \
    '{schema_version:1,created_at:$timestamp,profile:$profile,source_volume:$volume,components:{open_webui:{version:$open_webui_version,image:$open_webui_image}},files:{"open-webui-data.tar.gz":$data_sha,"configuration.tar.gz":$config_sha},included:["Open WebUI application data","versioned Agent Lab configuration","private .env when present"],excluded:["Ollama model weights","container image","logs","tool caches"]}' \
    > "$STAGING/manifest.json"

stamp=$(date -u '+%Y%m%dT%H%M%SZ')
archive="$destination/agent-lab-backup-$stamp.tar.gz"
tar -czf "$archive" -C "$STAGING" manifest.json open-webui-data.tar.gz configuration.tar.gz
shasum -a 256 "$archive" > "$archive.sha256"
chmod 600 "$archive" "$archive.sha256"
printf 'Backup created: %s\n' "$archive"
printf '%s\n' 'WARNING: the archive may contain local credentials and must be protected.'
