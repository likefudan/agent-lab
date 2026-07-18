#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

readonly REPO_ROOT="$(repository_root "$SCRIPT_DIR")"
readonly COMPONENTS_FILE="$REPO_ROOT/config/components.json"
readonly PLIST_TEMPLATE="$REPO_ROOT/config/ollama/ai.agent-lab.ollama.plist.template"
readonly LAUNCH_LABEL='ai.agent-lab.ollama'
readonly LAUNCH_DOMAIN="gui/$(id -u)"
readonly LAUNCH_SERVICE="$LAUNCH_DOMAIN/$LAUNCH_LABEL"
readonly LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly INSTALLED_PLIST="$LAUNCH_AGENTS_DIR/$LAUNCH_LABEL.plist"
readonly LOG_DIR="$HOME/.agent-lab/logs"
readonly OLLAMA_BIN='/opt/homebrew/opt/ollama/bin/ollama'
readonly OLLAMA_HOST='127.0.0.1'
readonly OLLAMA_PORT='11434'
readonly HEALTH_URL="http://$OLLAMA_HOST:$OLLAMA_PORT/api/version"
readonly ENV_FILE="$REPO_ROOT/.env"
readonly COMPOSE_FILE="$REPO_ROOT/compose.yaml"
readonly WEBUI_HEALTH_URL='http://127.0.0.1:3000/health'
START_TEMPORARY=

cleanup_start_temporary() {
    [ -z "$START_TEMPORARY" ] || rm -f -- "$START_TEMPORARY"
}

usage() {
    cat <<'EOF'
Usage: agent-lab start [--install-launch-agent]

Start the Agent Lab-managed Ollama launch agent. On first use, pass
--install-launch-agent and confirm the installation into ~/Library/LaunchAgents.
EOF
}

render_plist() {
    local destination=$1
    local escaped_home=${HOME//&/\\&}
    escaped_home=${escaped_home//|/\\|}
    sed "s|__AGENT_LAB_HOME__|$escaped_home|g" "$PLIST_TEMPLATE" > "$destination"
}

require_pinned_ollama() {
    local expected_version expected_sha actual_version actual_sha
    [ -x "$OLLAMA_BIN" ] || die "missing required software: pinned Ollama executable $OLLAMA_BIN" || return 1
    expected_version=$(json_get "$COMPONENTS_FILE" '.components[] | select(.id == "ollama") | .version') || return 1
    expected_sha=$(json_get "$COMPONENTS_FILE" '.components[] | select(.id == "ollama") | .artifact.executable_sha256') || return 1
    actual_version=$(command_version "$OLLAMA_BIN" --version)
    [ "$actual_version" = "$expected_version" ] ||
        die "unsupported Ollama version ${actual_version:-unknown}; Agent Lab requires $expected_version at $OLLAMA_BIN" || return 1
    actual_sha=$(shasum -a 256 "$OLLAMA_BIN" | awk '{print $1}')
    [ "$actual_sha" = "$expected_sha" ] ||
        die "incompatible Ollama executable at $OLLAMA_BIN; reinstall the pinned Homebrew 0.32.1 bottle" || return 1
}

installed_configuration_matches() {
    local expected
    [ -f "$INSTALLED_PLIST" ] || return 1
    expected=$(mktemp "${TMPDIR:-/tmp}/agent-lab-ollama-plist.XXXXXX")
    render_plist "$expected"
    if cmp -s "$expected" "$INSTALLED_PLIST"; then
        rm -f -- "$expected"
        return 0
    fi
    rm -f -- "$expected"
    return 1
}

service_is_loaded() {
    launchctl print "$LAUNCH_SERVICE" >/dev/null 2>&1
}

managed_pid() {
    launchctl print "$LAUNCH_SERVICE" 2>/dev/null |
        awk '$1 == "pid" && $2 == "=" { gsub(/;/, "", $3); print $3; exit }'
}

listener_belongs_to_managed_service() {
    local pid
    pid=$(managed_pid)
    [ -n "$pid" ] || return 1
    lsof -nP -a -p "$pid" -iTCP@"$OLLAMA_HOST":"$OLLAMA_PORT" -sTCP:LISTEN 2>/dev/null |
        awk 'NR == 2 { found=1 } END { exit !found }'
}

healthy_pinned_server() {
    local version
    version=$(curl --silent --show-error --fail --max-time 2 "$HEALTH_URL" 2>/dev/null |
        jq -er '.version' 2>/dev/null) || return 1
    [ "$version" = "$(json_get "$COMPONENTS_FILE" '.components[] | select(.id == "ollama") | .version')" ]
}

fail_for_existing_listener() {
    if healthy_pinned_server; then
        die "a compatible but unmanaged Ollama already owns $OLLAMA_HOST:$OLLAMA_PORT; stop it, then run Agent Lab start again"
    else
        die "occupied port: $OLLAMA_HOST:$OLLAMA_PORT; stop the unrelated or incompatible service before starting Agent Lab"
    fi
}

wait_for_managed_health() {
    local attempt
    for attempt in {1..40}; do
        if healthy_pinned_server && listener_belongs_to_managed_service; then
            return 0
        fi
        sleep 0.25
    done
    die "managed Ollama did not become healthy; inspect $LOG_DIR/ollama.stderr.log"
}

compose_command() {
    docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

wait_for_webui_health() {
    local attempt
    for attempt in {1..240}; do
        if curl --silent --show-error --fail --max-time 2 "$WEBUI_HEALTH_URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    compose_command logs --tail 40 open-webui >&2 || true
    die 'Open WebUI did not become healthy within 120 seconds'
}

install_launch_agent() {
    local temporary
    [ ! -e "$INSTALLED_PLIST" ] || {
        installed_configuration_matches && return 0
        die "refusing to overwrite a different launch agent at $INSTALLED_PLIST; inspect and remove it manually"
        return 1
    }
    confirm "Install the Agent Lab Ollama launch agent at $INSTALLED_PLIST?" no ||
        die 'launch agent installation was not confirmed' || return 1
    mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
    temporary=$(mktemp "$LAUNCH_AGENTS_DIR/.$LAUNCH_LABEL.XXXXXX")
    START_TEMPORARY=$temporary
    render_plist "$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$INSTALLED_PLIST"
    START_TEMPORARY=
    info "installed launch agent: $INSTALLED_PLIST"
}

install_requested=false
case $# in
    0) ;;
    1)
        case $1 in
            --install-launch-agent) install_requested=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown start option: $1"; exit 64 ;;
        esac
        ;;
    *) usage >&2; die 'start accepts at most one option'; exit 64 ;;
esac

trap 'cleanup_start_temporary' EXIT
trap 'cleanup_start_temporary; exit 129' HUP
trap 'cleanup_start_temporary; exit 130' INT
trap 'cleanup_start_temporary; exit 143' TERM
require_command jq
require_command curl
require_command launchctl
require_command lsof
require_command shasum
require_command docker
require_pinned_ollama

[[ -r "$ENV_FILE" ]] ||
    die "private environment file is missing; run 'agent-lab setup' first" || exit 1
docker info >/dev/null 2>&1 || die 'Docker engine is stopped or unavailable' || exit 1

if [ "$install_requested" = true ]; then
    if ! service_is_loaded && ! port_is_available "$OLLAMA_PORT" "$OLLAMA_HOST"; then
        fail_for_existing_listener
        exit 1
    fi
    install_launch_agent
fi

[ -f "$INSTALLED_PLIST" ] ||
    die "launch agent is not installed; run 'agent-lab start --install-launch-agent' from an interactive terminal" || exit 1
installed_configuration_matches ||
    die "installed launch agent differs from Agent Lab configuration; inspect $INSTALLED_PLIST before replacing it" || exit 1

if service_is_loaded; then
    if healthy_pinned_server && listener_belongs_to_managed_service; then
        info "Ollama is already running at $HEALTH_URL"
    else
        if ! port_is_available "$OLLAMA_PORT" "$OLLAMA_HOST" && ! listener_belongs_to_managed_service; then
            fail_for_existing_listener
            exit 1
        fi
        launchctl kickstart -k "$LAUNCH_SERVICE"
        wait_for_managed_health
        info "Ollama is ready at $HEALTH_URL"
    fi
else
    if ! port_is_available "$OLLAMA_PORT" "$OLLAMA_HOST"; then
        fail_for_existing_listener
        exit 1
    fi
    launchctl bootstrap "$LAUNCH_DOMAIN" "$INSTALLED_PLIST"
    wait_for_managed_health
    info "Ollama is ready at $HEALTH_URL"
fi

compose_command up --detach --no-build open-webui
wait_for_webui_health
info 'Open WebUI is ready at http://127.0.0.1:3000'
