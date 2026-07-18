#!/usr/bin/env bash
set -euo pipefail

# Shared, side-effect-conscious shell helpers for Agent Lab scripts.
# This file is intended to be sourced.

agent_lab_log() {
    local level=$1
    shift
    printf '%s: %s\n' "$level" "$*" >&2
}

info() { agent_lab_log INFO "$@"; }
warn() { agent_lab_log WARN "$@"; }
error() { agent_lab_log ERROR "$@"; }

die() {
    error "$@"
    return 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || die "missing required software: $1"
}

# Print the first dotted numeric version found in a command's version output.
command_version() {
    "$@" 2>/dev/null | awk '
        match($0, /[0-9]+([.][0-9]+)+/) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

# Return success when $1 is greater than or equal to $2. Non-numeric suffixes
# are ignored, and omitted dotted components compare as zero.
version_at_least() {
    awk -v actual="$1" -v minimum="$2" 'BEGIN {
        na = split(actual, a, ".")
        nm = split(minimum, m, ".")
        n = na > nm ? na : nm
        for (i = 1; i <= n; i++) {
            av = a[i] + 0
            mv = m[i] + 0
            if (av > mv) exit 0
            if (av < mv) exit 1
        }
        exit 0
    }'
}

# Find the repository root without depending on the caller's working directory.
# An optional starting directory may be supplied.
repository_root() {
    local start=${1:-$(pwd)}
    local root
    if command_exists git; then
        root=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null) && {
            printf '%s\n' "$root"
            return 0
        }
    fi

    while [ "$start" != / ]; do
        if [ -d "$start/.git" ]; then
            printf '%s\n' "$start"
            return 0
        fi
        start=$(dirname "$start")
    done
    die "repository root not found"
}

# Read one jq expression from a JSON file. jq -e makes absent/null values fail.
json_get() {
    local file=$1
    local filter=$2
    require_command jq || return 1
    [ -r "$file" ] || die "JSON file is not readable: $file" || return 1
    jq -er "$filter" "$file"
}

# Load a conservative KEY=VALUE profile. It deliberately does not source the
# file, so command substitutions and other shell syntax are never executed.
load_profile() {
    local profile_file=$1
    local line key value
    [ -r "$profile_file" ] || die "profile is not readable: $profile_file" || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            ''|'#'*) continue ;;
            export\ *) line=${line#export } ;;
        esac
        case $line in
            *=*) ;;
            *) die "invalid profile entry in $profile_file" || return 1 ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case $key in
            ''|*[!A-Za-z0-9_]*) die "invalid profile key in $profile_file" || return 1 ;;
        esac
        case $key in
            [0-9]*) die "invalid profile key in $profile_file" || return 1 ;;
        esac
        case $value in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        export "$key=$value"
    done < "$profile_file"
}

# Return success if a TCP port has no listener. Host defaults to loopback.
port_is_available() {
    local port=$1
    local host=${2:-127.0.0.1}
    case $port in
        ''|*[!0-9]*) die "invalid TCP port: $port" || return 2 ;;
    esac
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || {
        die "invalid TCP port: $port"
        return 2
    }

    if command_exists lsof; then
        ! lsof -nP -iTCP@"$host":"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 { found=1 } END { exit !found }'
    elif command_exists nc; then
        ! nc -z -w 1 "$host" "$port" >/dev/null 2>&1
    else
        die "cannot check ports: install lsof or nc"
        return 2
    fi
}

require_available_port() {
    local port=$1
    local host=${2:-127.0.0.1}
    local status
    if port_is_available "$port" "$host"; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 2 ] && return 2
    die "occupied port: $host:$port"
}

# Probe an HTTP service without echoing its URL, which may contain credentials.
require_http_endpoint() {
    local url=$1
    local label=${2:-HTTP endpoint}
    require_command curl || return 1
    curl --silent --show-error --fail --max-time 3 "$url" >/dev/null 2>&1 ||
        die "$label: service or network unavailable"
}

# Verify a local Ollama tag without pulling or loading it.
require_ollama_model() {
    local model=$1
    require_command ollama || return 1
    ollama show "$model" >/dev/null 2>&1 || die "unavailable model: $model"
}

# Ask for an explicit yes/no response. The optional default is "yes" or "no".
confirm() {
    local prompt=$1
    local default=${2:-no}
    local suffix answer
    [ -t 0 ] || return 1
    case $default in
        yes) suffix='[Y/n]' ;;
        no) suffix='[y/N]' ;;
        *) die "confirmation default must be yes or no" || return 2 ;;
    esac
    printf '%s %s ' "$prompt" "$suffix" >&2
    IFS= read -r answer || return 1
    case $answer in
        y|Y|yes|YES|Yes) return 0 ;;
        n|N|no|NO|No) return 1 ;;
        '') [ "$default" = yes ] ;;
        *) return 1 ;;
    esac
}

AGENT_LAB_CLEANUP_PATHS=${AGENT_LAB_CLEANUP_PATHS:-}

register_cleanup_path() {
    local cleanup_path=$1
    case $cleanup_path in
        ''|/|"${TMPDIR:-/tmp}"|/tmp) die "refusing unsafe cleanup path" || return 1 ;;
    esac
    case $cleanup_path in
        *$'\n'*) die "cleanup path must not contain a newline" || return 1 ;;
    esac
    AGENT_LAB_CLEANUP_PATHS="${AGENT_LAB_CLEANUP_PATHS}${cleanup_path}"$'\n'
}

cleanup_registered_paths() {
    local cleanup_path
    while IFS= read -r cleanup_path; do
        [ -n "$cleanup_path" ] || continue
        if [ -f "$cleanup_path" ] || [ -L "$cleanup_path" ]; then
            rm -f -- "$cleanup_path"
        elif [ -d "$cleanup_path" ]; then
            rmdir "$cleanup_path" 2>/dev/null || warn "cleanup directory is not empty: $cleanup_path"
        fi
    done <<< "$AGENT_LAB_CLEANUP_PATHS"
    AGENT_LAB_CLEANUP_PATHS=
}

install_cleanup_trap() {
    trap 'cleanup_registered_paths' EXIT
    trap 'cleanup_registered_paths; exit 129' HUP
    trap 'cleanup_registered_paths; exit 130' INT
    trap 'cleanup_registered_paths; exit 143' TERM
}
