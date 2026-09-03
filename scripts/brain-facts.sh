#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: brain-facts.sh <vault-path> <project> <branch>" >&2
  exit 1
}

[ $# -eq 3 ] || usage

vault="$1"
project="$2"
branch="$3"

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/lib/frontmatter.sh"

log_file="$vault/projects/$project/branches/$branch/log.md"
rollups_file="$vault/projects/$project/pending-rollups.md"

head_sha="$(git rev-parse HEAD)"

last_sha=""
if [ -f "$log_file" ]; then
  last_sha="$(fm_get "$log_file" last_sha)"
fi

echo "head_sha=$head_sha"
echo "last_sha=$last_sha"

if [ -z "$last_sha" ]; then
  echo "commits=(first snapshot for this branch)"
elif [ "$last_sha" = "$head_sha" ]; then
  echo "commits=(no new commits)"
else
  echo "--- commits ---"
  git log --oneline "$last_sha..$head_sha"
  echo "--- diffstat ---"
  git diff --stat "$last_sha..$head_sha"
fi

echo "--- pending-rollups ---"
if [ -f "$rollups_file" ] && grep -q '^- ' "$rollups_file"; then
  grep '^- ' "$rollups_file"
else
  echo "(none)"
fi
