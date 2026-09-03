#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
trap 'rm -rf "$vault"' EXIT

git init -q -b main "$vault"
git -C "$vault" config user.email "test@example.com"
git -C "$vault" config user.name "Test"

bash "$root/scripts/brain-commit.sh" "$vault" "should not commit"
count_before="$(git -C "$vault" rev-list --count HEAD 2>/dev/null || echo 0)"
assert_eq "$count_before" "0" "brain-commit.sh must not commit when there is nothing to commit"

echo "hello" > "$vault/note.md"
bash "$root/scripts/brain-commit.sh" "$vault" "add note"
count_after="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$count_after" "1" "brain-commit.sh should create exactly one commit"

last_msg="$(git -C "$vault" log -1 --format=%s)"
assert_eq "$last_msg" "add note" "commit message should match what was passed"

pass "brain-commit.sh"
