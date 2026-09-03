#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: brain-rollup-complete.sh <vault-path> <project> <branch>" >&2
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

if [ ! -f "$log_file" ]; then
  echo "brain-rollup-complete.sh: no log.md for branch $branch: $log_file" >&2
  exit 1
fi

fm_set "$log_file" rolled_up "true"

if [ -f "$rollups_file" ]; then
  tmp="$(mktemp)"
  # -- is required: "- $branch" starts with "-", which grep would otherwise parse as an option.
  grep -vxF -- "- $branch" "$rollups_file" > "$tmp" || true
  mv "$tmp" "$rollups_file"
fi
