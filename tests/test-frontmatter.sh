#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/scripts/lib/frontmatter.sh"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<'EOF'
---
project: demo
last_sha: abc123
---

# Body

Some content.
EOF

assert_eq "$(fm_get "$tmp" project)" "demo" "fm_get should read project"
assert_eq "$(fm_get "$tmp" last_sha)" "abc123" "fm_get should read last_sha"
assert_eq "$(fm_get "$tmp" missing)" "" "fm_get should return empty for missing key"

fm_set "$tmp" last_sha "def456"
assert_eq "$(fm_get "$tmp" last_sha)" "def456" "fm_set should update an existing key"
assert_file_contains "$tmp" "project: demo"
assert_file_contains "$tmp" "# Body"

fm_set "$tmp" merged "true"
assert_eq "$(fm_get "$tmp" merged)" "true" "fm_set should insert a new key"

pass "frontmatter.sh"
