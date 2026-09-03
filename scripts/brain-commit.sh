#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: brain-commit.sh <vault-path> <message>" >&2
  exit 1
}

[ $# -eq 2 ] || usage

vault="$1"
message="$2"

if ! git -C "$vault" rev-parse --git-dir >/dev/null 2>&1; then
  echo "brain-commit.sh: not a git repository: $vault" >&2
  exit 1
fi

if [ -z "$(git -C "$vault" status --porcelain)" ]; then
  exit 0
fi

git -C "$vault" add -A
git -C "$vault" commit -q -m "$message"
