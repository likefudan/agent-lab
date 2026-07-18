#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

failures=0
warnings=0
passes=0

pass_check() { printf 'PASS  %s\n' "$1"; passes=$((passes + 1)); }
warn_check() { printf 'WARN  %s\n' "$1"; warnings=$((warnings + 1)); }
fail_check() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }

check_required_command() {
    local name=$1
    local minimum=$2
    local version
    shift 2
    if ! command_exists "$name"; then
        fail_check "$name: missing required software"
        return
    fi
    version=$(command_version "$@")
    if [ -n "$minimum" ] && { [ -z "$version" ] || ! version_at_least "$version" "$minimum"; }; then
        fail_check "$name: unsupported version ${version:-unknown}; need >= $minimum"
    else
        pass_check "$name${version:+ $version}"
    fi
}

printf '%s\n' 'Agent Lab doctor (read-only)'

os=$(uname -s 2>/dev/null || printf unknown)
arch=$(uname -m 2>/dev/null || printf unknown)
[ "$os" = Darwin ] && pass_check 'operating system: macOS' || fail_check "operating system: unsupported $os"
[ "$arch" = arm64 ] && pass_check 'architecture: Apple Silicon arm64' || fail_check "architecture: unsupported $arch"

check_required_command git 2.30 git --version
check_required_command curl 7.70 curl --version
check_required_command jq 1.6 jq --version

if command_exists ollama; then
    ollama_version=
    ollama_version=$(command_version ollama --version)
    if curl --silent --show-error --fail --max-time 2 \
        http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
        pass_check "Ollama service${ollama_version:+ $ollama_version}"
    else
        fail_check 'Ollama service: installed but stopped or unavailable on loopback:11434'
    fi
else
    fail_check 'Ollama: missing required software'
fi

if ! command_exists docker; then
    fail_check 'Docker: missing required software'
elif ! docker info >/dev/null 2>&1; then
    fail_check 'Docker engine: CLI installed but service is stopped or unavailable'
elif ! docker compose version >/dev/null 2>&1; then
    fail_check 'Docker Compose: unavailable or unsupported'
else
    docker_version=
    docker_version=$(command_version docker --version)
    if [ -n "$docker_version" ] && ! version_at_least "$docker_version" 24.0; then
        fail_check "Docker: unsupported version $docker_version; need >= 24.0"
    else
        pass_check "Docker engine${docker_version:+ $docker_version}"
    fi
fi

for tool in llm aider; do
    if command_exists "$tool"; then
        pass_check "$tool: optional client installed"
    else
        warn_check "$tool: optional client not installed"
    fi
done

for tool in node npm promptfoo; do
    if command_exists "$tool"; then
        pass_check "$tool: deferred evaluation tool installed"
    else
        warn_check "$tool: deferred evaluation tool not installed"
    fi
done

printf 'SUMMARY pass/warn/fail: %s/%s/%s\n' "$passes" "$warnings" "$failures"
[ "$failures" -eq 0 ]
