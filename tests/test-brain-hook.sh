#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/scripts/lib/frontmatter.sh"

vault="$(mktemp -d)"
repo="$(mktemp -d)"
trap 'rm -rf "$vault" "$repo"' EXIT

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
  local cwd="$1"
  printf '{"cwd": "%s"}' "$cwd" | BRAIN_VAULT_PATH="$vault" bash "$root/scripts/brain-hook.sh"
}

# --- First session-end: creates the initial log entry and vault commit. ---
run_hook "$repo"

log_file="$vault/projects/$project/branches/main/log.md"
assert_file_exists "$log_file"
assert_file_contains "$log_file" "Initial snapshot"

vault_commits_1="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$vault_commits_1" "1" "first hook run should create exactly one vault commit"

# --- Second session-end with no new commits: must be a no-op. ---
run_hook "$repo"
vault_commits_2="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$vault_commits_2" "1" "hook run with no new commits must not create a vault commit"

# --- Third session-end after a new commit: appends an entry. ---
echo "two" > "$repo/file2.txt"
git -C "$repo" add file2.txt
git -C "$repo" commit -q -m "second commit"
run_hook "$repo"
assert_file_contains "$log_file" "second commit"
vault_commits_3="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$vault_commits_3" "2" "hook run with new commits should create one more vault commit"

# --- Branching off main must NOT flag main as "merged" into the new branch. ---
git -C "$repo" checkout -q -b feature
echo "three" > "$repo/file3.txt"
git -C "$repo" add file3.txt
git -C "$repo" commit -q -m "feature commit"
run_hook "$repo"

feature_log="$vault/projects/$project/branches/feature/log.md"
assert_file_exists "$feature_log"
assert_file_not_contains "$vault/projects/$project/pending-rollups.md" "- main"

# --- Merging feature into main must flag it as newly merged. ---
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff feature -m "merge feature"
run_hook "$repo"

assert_eq "$(fm_get "$feature_log" merged)" "true" "feature branch should be marked merged"
assert_file_contains "$vault/projects/$project/pending-rollups.md" "- feature"

pass "brain-hook.sh"
