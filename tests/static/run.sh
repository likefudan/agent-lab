#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

printf '%s\n' 'Static checks'

shell_files="$(find bin scripts tests -type f \( -name '*.sh' -o -path 'bin/agent-lab' \) -print | LC_ALL=C sort)"
while IFS= read -r shell_file; do
  [[ -n "$shell_file" ]] || continue
  bash -n "$shell_file" || fail "Bash syntax: $shell_file"
  [[ -x "$shell_file" ]] || fail "expected executable bit: $shell_file"
done <<<"$shell_files"
printf '%s\n' 'PASS: Bash syntax and executable bits'

if command -v shellcheck >/dev/null 2>&1; then
  # SC2086 is intentional here: shell_files is a newline-delimited list of
  # repository paths, and project paths do not contain whitespace at present.
  # shellcheck disable=SC2086
  shellcheck -x $shell_files
  printf '%s\n' 'PASS: ShellCheck'
else
  printf '%s\n' 'SKIP: ShellCheck is not installed (required before contributor release checks)'
fi

bash scripts/validate-config.sh

for test_script in tests/static/test-*.sh; do
  [[ -e "$test_script" ]] || continue
  "$test_script"
done

if [[ -f compose.yaml ]]; then
  command -v docker >/dev/null 2>&1 || fail 'compose.yaml exists but Docker CLI is unavailable'
  docker compose --env-file .env.example config --quiet
  printf '%s\n' 'PASS: Compose renders'
else
  printf '%s\n' 'SKIP: compose.yaml is not implemented yet'
fi

while IFS= read -r markdown_file; do
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    link="${link%%#*}"
    [[ -n "$link" ]] || continue
    case "$link" in
      http://*|https://*|mailto:*|/*) continue ;;
    esac
    decoded_link="${link//%20/ }"
    target="$(dirname "$markdown_file")/$decoded_link"
    [[ -e "$target" ]] || fail "broken relative Markdown link in $markdown_file: $link"
  done < <(rg --no-filename -o '\[[^]]+\]\([^)]+' "$markdown_file" | sed -E 's/^.*\]\((.*)$/\1/' || true)
done < <(find . -path './.git' -prune -o -path './.agent-lab' -prune -o -name '*.md' -type f -print)
printf '%s\n' 'PASS: relative Markdown links'

tracked_candidates="$(git ls-files --cached --others --exclude-standard)"
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  case "$candidate" in
    .env.example) ;;
    .env|.env.*|*.pem|*.key) fail "secret-like file is tracked or unignored: $candidate" ;;
  esac
done <<<"$tracked_candidates"

if [[ -n "$tracked_candidates" ]]; then
  # Match only high-confidence token/private-key signatures to avoid flagging
  # documented variable names and generated-secret placeholders.
  if printf '%s\n' "$tracked_candidates" | xargs rg -n \
      'gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    fail 'high-confidence secret signature found in a tracked or unignored file'
  fi
fi
printf '%s\n' 'PASS: tracked-file secret signatures'

for ignored_path in \
  .agent-lab/example \
  logs/example.log \
  model-cache/example \
  open-webui-data/example \
  vector-db/example \
  backup.sqlite \
  .cursor/example; do
  git check-ignore -q "$ignored_path" || fail "runtime/editor path is not ignored: $ignored_path"
done
printf '%s\n' 'PASS: generated data and Cursor metadata are ignored'

git diff --check
printf '%s\n' 'PASS: whitespace'
printf '%s\n' 'PASS: static repository checks'
