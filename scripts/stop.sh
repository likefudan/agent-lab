#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
readonly PLIST_TEMPLATE="$REPO_ROOT/config/ollama/ai.agent-lab.ollama.plist.template"
readonly LAUNCH_LABEL='ai.agent-lab.ollama'
readonly LAUNCH_DOMAIN="gui/$(id -u)"
readonly LAUNCH_SERVICE="$LAUNCH_DOMAIN/$LAUNCH_LABEL"
readonly INSTALLED_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
readonly ENV_FILE="$REPO_ROOT/.env"
readonly COMPOSE_FILE="$REPO_ROOT/compose.yaml"

usage() {
    cat <<'EOF'
Usage: agent-lab stop

Stop the Ollama instance owned by the matching Agent Lab launch agent. The
launch-agent file remains installed so the service persists across login/reboot.
EOF
}

render_plist() {
    local destination=$1
    local escaped_home=${HOME//&/\\&}
    escaped_home=${escaped_home//|/\\|}
    sed "s|__AGENT_LAB_HOME__|$escaped_home|g" "$PLIST_TEMPLATE" > "$destination"
}

case $# in
    0) ;;
    1)
        case $1 in
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown stop option: $1"; exit 64 ;;
        esac
        ;;
    *) usage >&2; die 'stop accepts no arguments'; exit 64 ;;
esac

require_command launchctl

if command_exists docker && docker info >/dev/null 2>&1 && [[ -r "$ENV_FILE" ]]; then
    container_id=$(docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" ps --quiet open-webui 2>/dev/null || true)
    if [[ -n "$container_id" ]]; then
        docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" stop --timeout 30 open-webui
        info 'stopped the Agent Lab Open WebUI container; data volume and image were preserved'
    else
        info 'Agent Lab Open WebUI container is already stopped'
    fi
elif command_exists docker; then
    warn 'Docker engine or private environment is unavailable; no Open WebUI container was changed'
fi

if [ ! -e "$INSTALLED_PLIST" ]; then
    info 'Agent Lab Ollama launch agent is not installed; nothing to stop'
    exit 0
fi

expected=$(mktemp "${TMPDIR:-/tmp}/agent-lab-ollama-plist.XXXXXX")
trap 'rm -f -- "$expected"' EXIT HUP INT TERM
render_plist "$expected"
cmp -s "$expected" "$INSTALLED_PLIST" ||
    die "refusing to stop an unverified launch agent at $INSTALLED_PLIST" || exit 1

if ! launchctl print "$LAUNCH_SERVICE" >/dev/null 2>&1; then
    info 'Agent Lab Ollama launch agent is already stopped'
    exit 0
fi

launchctl bootout "$LAUNCH_SERVICE"
info 'stopped the Agent Lab-managed Ollama launch agent'
