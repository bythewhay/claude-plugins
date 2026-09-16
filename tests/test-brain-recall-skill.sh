#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

skill="$root/skills/brain-recall/SKILL.md"
assert_file_exists "$skill"
assert_file_contains "$skill" "name: brain-recall"
assert_file_contains "$skill" "description:"
assert_file_contains "$skill" "brain-recall.sh"
assert_file_contains "$skill" "full"

pass "brain-recall-skill"
