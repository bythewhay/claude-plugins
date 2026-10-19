#!/usr/bin/env bash
# SessionStart hook: pulls brain vault context back into the session.
# Must never fail the session: all work runs in a guarded subshell and
# this script always exits 0, emitting valid (possibly empty) JSON.

main() {
  set -euo pipefail

  local input cwd hook_source
  input="$(cat)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  hook_source="$(printf '%s' "$input" | jq -r '.source // empty')"
  [ -n "$cwd" ] || return 0

  cd "$cwd" 2>/dev/null || return 0
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 0

  local repo_root project branch vault script_dir mode context
  repo_root="$(git rev-parse --show-toplevel)"
  project="$(basename "$repo_root")"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" != "HEAD" ] || return 0

  vault="${BRAIN_VAULT_PATH:-$HOME/Source/vault}"
  [ -d "$vault/.git" ] || return 0

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  mode="topics"
  [ "$hook_source" = "resume" ] && mode="full"

  context="$(bash "$script_dir/brain-recall.sh" "$vault" "$project" "$branch" "$mode")"
  [ -n "$context" ] || return 0

  jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
}

( main ) 2>>"${BRAIN_HOOK_DEBUG_LOG:-/dev/null}"
exit 0
