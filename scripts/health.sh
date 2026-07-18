#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

usage() {
  cat <<'EOF'
Usage: agent-lab health [--json]

Run read-only health diagnostics. Exit zero only when every required local
component, pinned artifact, cache, profile, and disk check passes.
EOF
}

json=false
case $# in
  0) ;;
  1)
    case $1 in
      --json) json=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 64 ;;
    esac
    ;;
  *) usage >&2; exit 64 ;;
esac

report=$("$SCRIPT_DIR/status.sh" --json)

if [[ "$json" == true ]]; then
  printf '%s\n' "$report"
else
  jq -r '
    def line($ok; $name; $detail; $action):
      (if $ok then "PASS  " else "FAIL  " end) + $name + ": " + $detail +
      (if $ok then "" else "; action: " + $action end);
    line(.profile.valid; "profile"; .profile.selected; .profile.action),
    line((.ollama.reachable and .ollama.response_valid and .ollama.version_matches); "Ollama endpoint"; (if .ollama.reachable then "version " + .ollama.version else "unavailable" end); .ollama.action),
    line(.ollama.binary.matches; "Ollama executable digest"; (if .ollama.binary.matches then "verified" else "drift or missing" end); .ollama.binary.action),
    line((.open_webui.reachable and .open_webui.response_valid and .open_webui.digest_matches); "Open WebUI"; (if .open_webui.reachable then "reachable, image digest " + (if .open_webui.digest_matches then "verified" else "drift" end) else "unavailable" end); .open_webui.action),
    line(.volume.exists; "Open WebUI volume"; (if .volume.exists then "present" else "missing" end); .volume.action),
    line(.embedding_cache.ready; "embedding cache"; (if .embedding_cache.ready then "pinned revision ready" else "not ready" end); .embedding_cache.action),
    (.models[] | line((.state == "verified"); "model " + .alias; .state; .action)),
    line(.disk.ok; "free disk"; ((.disk.free_bytes|tostring) + " bytes"); .disk.action),
    line(.environment.exists; "private environment"; (if .environment.exists then "present" else "missing" end); .environment.action),
    "SUMMARY healthy=" + (.healthy|tostring)
  ' <<<"$report"
fi

[[ $(jq -r '.healthy' <<<"$report") == true ]]
