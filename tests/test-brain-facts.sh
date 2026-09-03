#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
repo="$(mktemp -d)"
trap 'rm -rf "$vault" "$repo"' EXIT

bash "$root/scripts/brain-scaffold.sh" "$vault" "demo"

git init -q -b main "$repo"
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
echo "one" > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m "first commit"

# Case 1: no prior log.md for this branch -> first snapshot, no range.
out1="$(cd "$repo" && bash "$root/scripts/brain-facts.sh" "$vault" "demo" "main")"
echo "$out1" | grep -q '^last_sha=$' || { echo "FAIL: expected empty last_sha" >&2; echo "$out1" >&2; exit 1; }
echo "$out1" | grep -qF "commits=(first snapshot for this branch)" || { echo "FAIL: expected first-snapshot marker" >&2; echo "$out1" >&2; exit 1; }
echo "$out1" | grep -q '^head_sha=' || { echo "FAIL: expected head_sha" >&2; exit 1; }
echo "$out1" | grep -qF "(none)" || { echo "FAIL: expected empty pending-rollups" >&2; exit 1; }

# Case 2: log.md exists with a stale last_sha -> new commits + diffstat.
first_sha="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$vault/projects/demo/branches/main"
cat > "$vault/projects/demo/branches/main/log.md" <<EOF
---
last_sha: $first_sha
merged: false
rolled_up: false
---

# Branch Log: main
EOF

echo "two" > "$repo/file2.txt"
git -C "$repo" add file2.txt
git -C "$repo" commit -q -m "second commit"

out2="$(cd "$repo" && bash "$root/scripts/brain-facts.sh" "$vault" "demo" "main")"
echo "$out2" | grep -qF "last_sha=$first_sha" || { echo "FAIL: expected last_sha=$first_sha" >&2; echo "$out2" >&2; exit 1; }
echo "$out2" | grep -qF "second commit" || { echo "FAIL: expected new commit in output" >&2; echo "$out2" >&2; exit 1; }
echo "$out2" | grep -qF "file2.txt" || { echo "FAIL: expected diffstat mentioning file2.txt" >&2; exit 1; }

# Case 3: pending-rollups.md has an entry -> should be echoed.
echo "- feature-x" >> "$vault/projects/demo/pending-rollups.md"
out3="$(cd "$repo" && bash "$root/scripts/brain-facts.sh" "$vault" "demo" "main")"
echo "$out3" | grep -qx -- "- feature-x" || { echo "FAIL: expected pending rollup entry" >&2; echo "$out3" >&2; exit 1; }

pass "brain-facts.sh"
