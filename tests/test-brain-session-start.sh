#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
repo="$(mktemp -d)"
out="$(mktemp)"
trap 'rm -rf "$vault" "$repo" "$out"' EXIT

git init -q -b main "$vault"
git -C "$vault" config user.email "vault@example.com"
git -C "$vault" config user.name "Vault"

git init -q -b main "$repo"
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
echo "one" > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m "first commit"

project="$(basename "$repo")"

run_hook() {
  local source="$1"
  printf '{"cwd": "%s", "source": "%s"}' "$repo" "$source" \
    | BRAIN_VAULT_PATH="$vault" bash "$root/scripts/brain-session-start.sh" > "$out"
}

# --- No vault entry yet: hook must still emit valid JSON and never fail. ---
run_hook "startup"
jq empty "$out"

# --- Populate the vault with distinctive content per file. ---
bash "$root/scripts/brain-scaffold.sh" "$vault" "$project"
project_dir="$vault/projects/$project"
echo "STATUS_MARKER" >> "$project_dir/status.md"

# --- startup source: lightweight, topics-only context. ---
run_hook "startup"
context="$(jq -r '.hookSpecificOutput.additionalContext' "$out")"
[[ "$context" == *"$project"* ]] || { echo "FAIL: startup context missing project name" >&2; exit 1; }
[[ "$context" != *"STATUS_MARKER"* ]] || { echo "FAIL: startup context should not include full status.md prose" >&2; exit 1; }

# --- resume source: full context, including status.md prose. ---
run_hook "resume"
context="$(jq -r '.hookSpecificOutput.additionalContext' "$out")"
[[ "$context" == *"STATUS_MARKER"* ]] || { echo "FAIL: resume context missing status.md content" >&2; exit 1; }

assert_eq "$(jq -r '.hookSpecificOutput.hookEventName' "$out")" "SessionStart" \
  "hook must declare hookEventName SessionStart"

# --- non-git cwd: no-op, must still exit 0 and emit nothing harmful. ---
nongit="$(mktemp -d)"
trap 'rm -rf "$vault" "$repo" "$out" "$nongit"' EXIT
set +e
printf '{"cwd": "%s", "source": "startup"}' "$nongit" \
  | BRAIN_VAULT_PATH="$vault" bash "$root/scripts/brain-session-start.sh" > "$out"
rc=$?
set -e
assert_eq "$rc" "0" "hook must exit 0 for a non-git cwd"

pass "brain-session-start"
