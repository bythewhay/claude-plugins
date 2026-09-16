#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: brain-recall.sh <vault-path> <project> <branch> <topics|full>" >&2
  exit 1
}

[ $# -eq 4 ] || usage

vault="$1"
project="$2"
branch="$3"
mode="$4"

case "$mode" in
  topics|full) ;;
  *) usage ;;
esac

project_dir="$vault/projects/$project"

# Reading never scaffolds - a project with no vault entry yet has nothing to recall.
[ -f "$project_dir/index.md" ] || exit 0

print_features() {
  local features_dir="$project_dir/features"
  if [ -d "$features_dir" ] && [ -n "$(find "$features_dir" -maxdepth 1 -name '*.md' -print -quit)" ]; then
    find "$features_dir" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort
  else
    echo "(none)"
  fi
}

print_pending_rollups() {
  local rollups_file="$project_dir/pending-rollups.md"
  [ -f "$rollups_file" ] && grep '^- ' "$rollups_file"
}

if [ "$mode" = "topics" ]; then
  echo "--- brain vault: $project ---"
  cat "$project_dir/index.md"
  echo
  echo "--- features ---"
  print_features
  rollups="$(print_pending_rollups || true)"
  if [ -n "$rollups" ]; then
    echo
    echo "--- pending rollups ---"
    printf '%s\n' "$rollups"
  fi
  exit 0
fi

# mode = full
echo "--- brain vault: $project (status/decisions/reference) ---"
for f in status.md decisions.md reference.md; do
  if [ -f "$project_dir/$f" ]; then
    echo
    echo "## $f"
    cat "$project_dir/$f"
  fi
done

echo
echo "--- features (names only) ---"
print_features

branch_dir="$project_dir/branches/$branch"
if [ -f "$branch_dir/update.md" ] || [ -f "$branch_dir/log.md" ]; then
  echo
  echo "--- branch: $branch (in-progress work) ---"
  if [ -f "$branch_dir/update.md" ]; then
    echo
    echo "## update.md"
    cat "$branch_dir/update.md"
  fi
  if [ -f "$branch_dir/log.md" ]; then
    echo
    echo "## log.md"
    cat "$branch_dir/log.md"
  fi
fi

rollups="$(print_pending_rollups || true)"
if [ -n "$rollups" ]; then
  echo
  echo "--- pending rollups ---"
  printf '%s\n' "$rollups"
fi
