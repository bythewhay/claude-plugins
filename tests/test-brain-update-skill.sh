#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

skill="$root/skills/brain-update/SKILL.md"
assert_file_exists "$skill"
assert_file_contains "$skill" "name: brain-update"
assert_file_contains "$skill" "description:"
assert_file_contains "$skill" "brain-scaffold.sh"
assert_file_contains "$skill" "brain-facts.sh"
assert_file_contains "$skill" "brain-commit.sh"
assert_file_contains "$skill" "brain-rollup-complete.sh"
assert_file_contains "$skill" "haiku"
assert_file_contains "$skill" "run.md"

pass "brain-update-skill"
