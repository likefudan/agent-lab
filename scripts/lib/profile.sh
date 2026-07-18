#!/usr/bin/env bash

# Validated configuration-profile helpers. This file is intended to be sourced
# after scripts/lib/common.sh. Profile files are data and are never shell-sourced.

agent_lab_default_profile() {
    printf '%s\n' online-manual
}

agent_lab_profile_keys() {
    cat <<'EOF'
AGENT_LAB_PROFILE
AGENT_LAB_ALLOW_MODEL_PULLS
AGENT_LAB_ALLOW_REMOTE_TOOLS
AGENT_LAB_SEARCH_MODE
OFFLINE_MODE
ENABLE_VERSION_UPDATE_CHECK
ENABLE_WEB_SEARCH
WEB_SEARCH_ENGINE
RAG_EMBEDDING_MODEL_AUTO_UPDATE
RAG_RERANKING_MODEL_AUTO_UPDATE
SCARF_NO_ANALYTICS
DO_NOT_TRACK
ANONYMIZED_TELEMETRY
EOF
}

agent_lab_profile_name_is_valid() {
    case ${1:-} in
        offline|online-manual|online-automatic) return 0 ;;
        *) return 1 ;;
    esac
}

agent_lab_profile_file() {
    local name=${1:-}
    local profile_root
    agent_lab_profile_name_is_valid "$name" || {
        die "unknown Agent Lab profile: ${name:-<empty>}"
        return 1
    }
    if [ -n "${AGENT_LAB_PROFILE_DIR:-}" ]; then
        profile_root=$AGENT_LAB_PROFILE_DIR
    else
        profile_root=$(repository_root "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)") || return 1
        profile_root="$profile_root/config/profiles"
    fi
    printf '%s/%s.env\n' "$profile_root" "$name"
}

agent_lab_profile_value_is_valid() {
    local key=$1
    local value=$2
    case $key in
        AGENT_LAB_PROFILE) agent_lab_profile_name_is_valid "$value" ;;
        AGENT_LAB_ALLOW_MODEL_PULLS|AGENT_LAB_ALLOW_REMOTE_TOOLS|OFFLINE_MODE|ENABLE_VERSION_UPDATE_CHECK|ENABLE_WEB_SEARCH|RAG_EMBEDDING_MODEL_AUTO_UPDATE|RAG_RERANKING_MODEL_AUTO_UPDATE|SCARF_NO_ANALYTICS|DO_NOT_TRACK|ANONYMIZED_TELEMETRY)
            case $value in true|false) return 0 ;; *) return 1 ;; esac
            ;;
        AGENT_LAB_SEARCH_MODE)
            case $value in disabled|manual|automatic) return 0 ;; *) return 1 ;; esac
            ;;
        WEB_SEARCH_ENGINE)
            case $value in ''|duckduckgo) return 0 ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
}

agent_lab_validate_profile_file() {
    local profile_file=$1
    local expected_name=${2:-}
    local line key value seen=''
    local count=0 expected_count
    local actual_profile='' search_mode='' offline_mode='' web_search='' search_engine=''
    local allow_pulls='' allow_remote='' version_updates='' embedding_updates=''
    local reranking_updates='' scarf='' tracking='' telemetry=''

    [ -r "$profile_file" ] || {
        die "profile is not readable: $profile_file"
        return 1
    }
    expected_count=$(agent_lab_profile_keys | awk 'END { print NR }')

    while IFS= read -r line || [ -n "$line" ]; do
        case $line in ''|'#'*) continue ;; esac
        case $line in
            *=*) ;;
            *) die "invalid profile entry in $profile_file: expected KEY=VALUE"; return 1 ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case $key in
            ''|*[!A-Z0-9_]*) die "invalid profile key in $profile_file: $key"; return 1 ;;
        esac
        if ! agent_lab_profile_keys | grep -Fqx -- "$key"; then
            die "unknown profile key in $profile_file: $key"
            return 1
        fi
        case $seen in
            *$'\n'"$key"$'\n'*) die "duplicate profile key in $profile_file: $key"; return 1 ;;
        esac
        agent_lab_profile_value_is_valid "$key" "$value" || {
            die "unsupported profile value in $profile_file: $key"
            return 1
        }
        seen="${seen}"$'\n'"${key}"$'\n'
        count=$((count + 1))
        case $key in
            AGENT_LAB_PROFILE) actual_profile=$value ;;
            AGENT_LAB_ALLOW_MODEL_PULLS) allow_pulls=$value ;;
            AGENT_LAB_ALLOW_REMOTE_TOOLS) allow_remote=$value ;;
            AGENT_LAB_SEARCH_MODE) search_mode=$value ;;
            OFFLINE_MODE) offline_mode=$value ;;
            ENABLE_VERSION_UPDATE_CHECK) version_updates=$value ;;
            ENABLE_WEB_SEARCH) web_search=$value ;;
            WEB_SEARCH_ENGINE) search_engine=$value ;;
            RAG_EMBEDDING_MODEL_AUTO_UPDATE) embedding_updates=$value ;;
            RAG_RERANKING_MODEL_AUTO_UPDATE) reranking_updates=$value ;;
            SCARF_NO_ANALYTICS) scarf=$value ;;
            DO_NOT_TRACK) tracking=$value ;;
            ANONYMIZED_TELEMETRY) telemetry=$value ;;
        esac
    done < "$profile_file"

    [ "$count" -eq "$expected_count" ] || {
        die "profile must define every allowed key exactly once: $profile_file"
        return 1
    }
    [ -z "$expected_name" ] || [ "$actual_profile" = "$expected_name" ] || {
        die "profile name does not match file selection: $expected_name"
        return 1
    }
    [ "$allow_remote" = false ] && [ "$version_updates" = false ] &&
        [ "$embedding_updates" = false ] && [ "$reranking_updates" = false ] &&
        [ "$scarf" = true ] && [ "$tracking" = true ] && [ "$telemetry" = false ] || {
        die "profile violates Agent Lab remote-endpoint, update, or telemetry policy: $profile_file"
        return 1
    }
    case $actual_profile in
        offline)
            [ "$allow_pulls" = false ] && [ "$search_mode" = disabled ] &&
                [ "$offline_mode" = true ] && [ "$web_search" = false ] &&
                [ -z "$search_engine" ] || {
                die "offline profile enables an online-only capability"
                return 1
            }
            ;;
        online-manual)
            [ "$allow_pulls" = true ] && [ "$search_mode" = manual ] &&
                [ "$offline_mode" = false ] && [ "$web_search" = true ] &&
                [ "$search_engine" = duckduckgo ] || {
                die "online-manual profile does not require explicit DuckDuckGo search"
                return 1
            }
            ;;
        online-automatic)
            [ "$allow_pulls" = true ] && [ "$search_mode" = automatic ] &&
                [ "$offline_mode" = false ] && [ "$web_search" = true ] &&
                [ "$search_engine" = duckduckgo ] || {
                die "online-automatic profile does not expose the qualified search tool"
                return 1
            }
            ;;
    esac
}

agent_lab_validate_profile() {
    local name=${1:-}
    local profile_file
    profile_file=$(agent_lab_profile_file "$name") || return 1
    agent_lab_validate_profile_file "$profile_file" "$name"
}

agent_lab_effective_profile() {
    local name=${1:-$(agent_lab_default_profile)}
    local profile_file
    profile_file=$(agent_lab_profile_file "$name") || return 1
    agent_lab_validate_profile_file "$profile_file" "$name" || return 1
    LC_ALL=C grep -v '^[[:space:]]*#' "$profile_file" | grep -v '^[[:space:]]*$' | LC_ALL=C sort
}

agent_lab_load_profile() {
    local name=${1:-$(agent_lab_default_profile)}
    local profile_file line key value
    profile_file=$(agent_lab_profile_file "$name") || return 1
    agent_lab_validate_profile_file "$profile_file" "$name" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in ''|'#'*) continue ;; esac
        key=${line%%=*}
        value=${line#*=}
        export "$key=$value"
    done < "$profile_file"
}

agent_lab_selected_profile() {
    local name=${AGENT_LAB_PROFILE:-$(agent_lab_default_profile)}
    agent_lab_profile_name_is_valid "$name" || {
        die "unknown Agent Lab profile: $name"
        return 1
    }
    printf '%s\n' "$name"
}

agent_lab_profile_state_file() {
    local root state_dir
    if [ -n "${AGENT_LAB_PROFILE_STATE_FILE:-}" ]; then
        printf '%s\n' "$AGENT_LAB_PROFILE_STATE_FILE"
        return 0
    fi
    root=$(repository_root "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)") || return 1
    state_dir=${AGENT_LAB_STATE_DIR:-$root/.agent-lab}
    printf '%s/profile\n' "$state_dir"
}

agent_lab_active_profile() {
    local state_file name
    state_file=$(agent_lab_profile_state_file) || return 1
    if [ ! -r "$state_file" ]; then
        agent_lab_default_profile
        return 0
    fi
    IFS= read -r name < "$state_file" || true
    agent_lab_profile_name_is_valid "$name" || {
        die "invalid active profile state: $state_file"
        return 1
    }
    printf '%s\n' "$name"
}

agent_lab_profile_restart_required() {
    local desired=${1:-$(agent_lab_selected_profile)}
    local active
    agent_lab_validate_profile "$desired" || return 2
    active=$(agent_lab_active_profile) || return 2
    [ "$desired" != "$active" ]
}

# Switch profile state after a caller-provided function successfully recreates
# only the Open WebUI container configuration. The callback receives the desired
# profile name and literal service name "open-webui". Named volumes are never
# removed here. Re-selecting the active profile is an idempotent no-op.
agent_lab_switch_profile() {
    local desired=${1:-}
    local recreate_function=${2:-}
    local assume_yes=${3:-false}
    local state_file state_dir temporary active

    agent_lab_validate_profile "$desired" || return 1
    active=$(agent_lab_active_profile) || return 1
    [ "$desired" != "$active" ] || return 0
    case $recreate_function in
        ''|*[!A-Za-z0-9_]*|[0-9]*) die "invalid profile recreation function"; return 1 ;;
    esac
    declare -F "$recreate_function" >/dev/null 2>&1 || {
        die "profile recreation function is not defined: $recreate_function"
        return 1
    }
    if [ "$assume_yes" != true ]; then
        confirm "Switch profile from $active to $desired and recreate Open WebUI?" no || {
            die "profile switch was not confirmed"
            return 1
        }
    fi
    "$recreate_function" "$desired" open-webui || return 1

    state_file=$(agent_lab_profile_state_file) || return 1
    state_dir=$(dirname -- "$state_file")
    mkdir -p -- "$state_dir"
    temporary=$(mktemp "$state_dir/.profile.XXXXXX") || return 1
    printf '%s\n' "$desired" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$state_file"
}
