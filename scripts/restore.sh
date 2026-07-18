#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
readonly IMAGE='ghcr.io/open-webui/open-webui@sha256:9fcea9c6e32ab60b0498f3986c6cdf651ddbe61db48d2213a3d28048ddd673d4'
STAGING=
CREATED_VOLUME=

cleanup() {
    [[ -z $STAGING ]] || rm -rf -- "$STAGING"
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'EOF'
Usage: agent-lab restore --archive FILE [--target-volume NAME] [--config-destination EMPTY_DIRECTORY]

Validate and restore into a new volume by default. This command never replaces
the live Agent Lab volume; use the documented guarded recovery drill instead.
EOF
}

archive=
target_volume=
config_destination=
while (($#)); do
    case $1 in
        --archive) [[ $# -ge 2 ]] || die '--archive needs a value'; archive=$2; shift 2 ;;
        --target-volume) [[ $# -ge 2 ]] || die '--target-volume needs a value'; target_volume=$2; shift 2 ;;
        --config-destination) [[ $# -ge 2 ]] || die '--config-destination needs a value'; config_destination=$2; shift 2 ;;
        --replace-live|--yes) die 'live replacement is intentionally not automated; follow docs/recovery.md'; exit 64 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown restore option: $1"; exit 64 ;;
    esac
done
[[ -n $archive && -f $archive ]] || { usage >&2; die 'a readable --archive is required'; exit 64; }
require_command docker
require_command jq
require_command shasum
require_command tar
docker info >/dev/null 2>&1 || die 'Docker engine is unavailable' || exit 1

archive=$(cd "$(dirname "$archive")" && pwd -P)/$(basename "$archive")
members=$(tar -tzf "$archive") || die 'backup archive is corrupt or unreadable' || exit 1
printf '%s\n' "$members" | awk '
    /^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
    $0 != "manifest.json" && $0 != "open-webui-data.tar.gz" && $0 != "configuration.tar.gz" { bad=1 }
    END { exit bad }
' || die 'backup archive contains unsafe or unexpected paths' || exit 1

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/agent-lab-restore.XXXXXX")
chmod 700 "$STAGING"
tar -xzf "$archive" -C "$STAGING"
jq -e '.schema_version == 1 and (.files | keys | sort) == ["configuration.tar.gz","open-webui-data.tar.gz"]' "$STAGING/manifest.json" >/dev/null ||
    die 'unsupported or malformed backup manifest' || exit 1
expected_version=$(jq -r '.components[] | select(.id == "open-webui") | .version' "$REPO_ROOT/config/components.json")
[[ $(jq -r '.components.open_webui.version' "$STAGING/manifest.json") == "$expected_version" ]] ||
    die "backup Open WebUI version is incompatible; expected $expected_version" || exit 1
for file in open-webui-data.tar.gz configuration.tar.gz; do
    expected=$(jq -r --arg file "$file" '.files[$file]' "$STAGING/manifest.json")
    actual=$(shasum -a 256 "$STAGING/$file" | awk '{print $1}')
    [[ $actual == "$expected" ]] || die "backup checksum mismatch: $file" || exit 1
    tar -tzf "$STAGING/$file" | awk '/^\// || /(^|\/)\.\.($|\/)/ { bad=1 } END { exit bad }' ||
        die "nested archive contains unsafe paths: $file" || exit 1
done

if [[ -z $target_volume ]]; then
    target_volume="agent-lab-restore-$(date -u '+%Y%m%d%H%M%S')-$$"
fi
[[ $target_volume != 'agent-lab-open-webui-data' ]] || die 'refusing to overwrite the live Open WebUI volume' || exit 1
[[ $target_volume =~ ^[A-Za-z0-9][A-Za-z0-9_.-]+$ ]] || die 'invalid target volume name' || exit 1
! docker volume inspect "$target_volume" >/dev/null 2>&1 || die "target volume already exists: $target_volume" || exit 1
docker volume create "$target_volume" >/dev/null
CREATED_VOLUME=$target_volume
if ! docker run --rm --entrypoint sh -v "$target_volume:/target" -v "$STAGING:/backup:ro" "$IMAGE" \
    -c 'cd /target && tar -xzf /backup/open-webui-data.tar.gz'; then
    docker volume rm "$target_volume" >/dev/null 2>&1 || true
    die 'failed to restore Open WebUI data into the new volume'
    exit 1
fi

if [[ -n $config_destination ]]; then
    [[ -d $config_destination && -w $config_destination ]] || die 'config destination must be a writable directory' || exit 1
    [[ -z $(find "$config_destination" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'config destination must be empty' || exit 1
    tar -xzf "$STAGING/configuration.tar.gz" -C "$config_destination"
fi

printf 'Restored Open WebUI data into new volume: %s\n' "$target_volume"
[[ -z $config_destination ]] || printf 'Restored configuration into: %s\n' "$config_destination"
printf '%s\n' 'The live Agent Lab volume was not modified.'
