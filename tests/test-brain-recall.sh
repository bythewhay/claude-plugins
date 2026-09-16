#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
out="$(mktemp)"
trap 'rm -rf "$vault" "$out"' EXIT

project="myproj"
branch="main"

recall() {
  bash "$root/scripts/brain-recall.sh" "$vault" "$project" "$branch" "$1" > "$out"
}

# --- No vault entry yet for this project: both modes print nothing. ---
recall topics
assert_eq "$(wc -c < "$out")" "0" "topics mode on unscaffolded project must print nothing"
recall full
assert_eq "$(wc -c < "$out")" "0" "full mode on unscaffolded project must print nothing"

# --- Scaffold the project, then populate distinctive content in each file. ---
bash "$root/scripts/brain-scaffold.sh" "$vault" "$project"
project_dir="$vault/projects/$project"

cat >> "$project_dir/status.md" <<'EOF'
STATUS_MARKER: working on the frobnicator
EOF
cat >> "$project_dir/decisions.md" <<'EOF'
DECISIONS_MARKER: chose sqlite over postgres
EOF
cat >> "$project_dir/reference.md" <<'EOF'
REFERENCE_MARKER: entry point is main.go
EOF

mkdir -p "$project_dir/features"
echo "# Frobnicator" > "$project_dir/features/frobnicator.md"

# --- topics mode: lists index.md + feature names, but not the prose bodies. ---
recall topics
assert_file_contains "$out" "myproj"
assert_file_contains "$out" "frobnicator"
assert_file_not_contains "$out" "STATUS_MARKER"
assert_file_not_contains "$out" "DECISIONS_MARKER"
assert_file_not_contains "$out" "REFERENCE_MARKER"

# --- full mode: includes status/decisions/reference prose. ---
recall full
assert_file_contains "$out" "STATUS_MARKER"
assert_file_contains "$out" "DECISIONS_MARKER"
assert_file_contains "$out" "REFERENCE_MARKER"
# feature files are listed by name only, not dumped in full
assert_file_contains "$out" "frobnicator"
assert_file_not_contains "$out" "# Frobnicator"

# --- full mode: no branch/log/update section when the branch has no vault entry. ---
assert_file_not_contains "$out" "in-progress"

# --- full mode: picks up an in-progress branch's update.md and log.md. ---
branch_dir="$project_dir/branches/$branch"
mkdir -p "$branch_dir"
cat > "$branch_dir/update.md" <<'EOF'
---
project: myproj
branch: main
---
UPDATE_MARKER: staged notes for this branch
EOF
cat > "$branch_dir/log.md" <<'EOF'
---
last_sha: deadbeef
merged: false
rolled_up: false
---
LOG_MARKER: raw git facts
EOF

recall full
assert_file_contains "$out" "UPDATE_MARKER"
assert_file_contains "$out" "LOG_MARKER"

# --- full mode: pending rollups surfaced when present. ---
echo "- some-other-branch" >> "$project_dir/pending-rollups.md"
recall full
assert_file_contains "$out" "some-other-branch"

pass "brain-recall"
