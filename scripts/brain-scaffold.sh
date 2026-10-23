#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: brain-scaffold.sh <vault-path> <project>" >&2
  exit 1
}

[ $# -eq 2 ] || usage

vault="$1"
project="$2"
project_dir="$vault/projects/$project"

if [ -f "$project_dir/index.md" ]; then
  exit 0
fi

mkdir -p "$project_dir/branches" "$project_dir/features"

cat > "$project_dir/index.md" <<EOF
---
project: $project
---

# $project

## Status
See [status](status.md).

## Decisions
See [decisions](decisions.md).

## Reference
See [reference](reference.md).

## Running
See [run](run.md).

## Features
(none yet)
EOF

cat > "$project_dir/status.md" <<EOF
---
type: status
project: $project
updated: $(date +%Y-%m-%d)
---

# Status

## Current Focus

## Recent Progress

## Next Steps

## Open Questions
EOF

cat > "$project_dir/decisions.md" <<EOF
---
type: decisions
project: $project
---

# Decisions

Dated log of major project-wide design decisions. Newest entries at the
bottom.
EOF

cat > "$project_dir/reference.md" <<EOF
---
type: reference
project: $project
---

# Reference

Architecture notes, key files, and gotchas for $project.
EOF

cat > "$project_dir/run.md" <<EOF
---
type: run
project: $project
---

# Run

How to start $project: entry point, arguments, and the exact command.

## Entry Point

## Arguments

## Command
EOF

cat > "$project_dir/pending-rollups.md" <<EOF
---
type: pending-rollups
project: $project
---

# Pending Rollups

Branches whose work has landed but hasn't been folded into the main
docs yet. Populated by the session-end hook; cleared by /brain-update.
EOF
