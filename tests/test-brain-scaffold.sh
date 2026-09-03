#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
trap 'rm -rf "$vault"' EXIT

bash "$root/scripts/brain-scaffold.sh" "$vault" "demo-project"

proj="$vault/projects/demo-project"
assert_file_exists "$proj/index.md"
assert_file_exists "$proj/status.md"
assert_file_exists "$proj/decisions.md"
assert_file_exists "$proj/reference.md"
assert_file_exists "$proj/pending-rollups.md"
[ -d "$proj/branches" ] || { echo "FAIL: expected branches/ dir" >&2; exit 1; }
[ -d "$proj/features" ] || { echo "FAIL: expected features/ dir" >&2; exit 1; }

assert_file_contains "$proj/index.md" "project: demo-project"
assert_file_contains "$proj/status.md" "## Current Focus"
assert_file_contains "$proj/decisions.md" "# Decisions"
assert_file_contains "$proj/reference.md" "# Reference"
assert_file_contains "$proj/pending-rollups.md" "# Pending Rollups"

# Idempotency: existing content must survive a second run.
echo "MY CUSTOM NOTE" >> "$proj/status.md"
bash "$root/scripts/brain-scaffold.sh" "$vault" "demo-project"
assert_file_contains "$proj/status.md" "MY CUSTOM NOTE"

pass "brain-scaffold.sh"
