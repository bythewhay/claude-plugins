#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/scripts/lib/frontmatter.sh"

vault="$(mktemp -d)"
trap 'rm -rf "$vault"' EXIT

bash "$root/scripts/brain-scaffold.sh" "$vault" "demo"
mkdir -p "$vault/projects/demo/branches/feat/x"
cat > "$vault/projects/demo/branches/feat/x/log.md" <<EOF
---
last_sha: abc123
merged: true
rolled_up: false
---

# Branch Log: feat/x
EOF
cat >> "$vault/projects/demo/pending-rollups.md" <<EOF
- feat/x
- feature-y
EOF

bash "$root/scripts/brain-rollup-complete.sh" "$vault" "demo" "feat/x"

assert_eq "$(fm_get "$vault/projects/demo/branches/feat/x/log.md" rolled_up)" "true" \
  "rolled_up should be flipped to true"
assert_file_not_contains "$vault/projects/demo/pending-rollups.md" "- feat/x"
assert_file_contains "$vault/projects/demo/pending-rollups.md" "- feature-y"

pass "brain-rollup-complete.sh"
