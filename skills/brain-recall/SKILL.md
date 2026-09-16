---
name: brain-recall
description: Use when you want to manually pull this project's existing brain vault notes (status, decisions, reference, in-progress branch work) into the current conversation - for example after the lightweight session-start topics summary suggested something worth reading in full, or any time you want a refresher without waiting for a session resume.
---

# Brain Recall

## Overview

Pulls this project's brain vault notes into the current session on
demand. This is the manual counterpart to the automatic `SessionStart`
hook: on session resume the hook already injects the full notes
automatically, and on a fresh `startup` it injects only a lightweight
topics list (what notes exist, not their content) so you can decide
what's worth reading. This skill is how you pull the full content
yourself, at any point, without waiting for a resume.

This is pure reading - no writes, no vault commit, no subagent
dispatch. If the project has no vault entry yet, there is nothing to
recall.

## Steps

1. **Resolve project, branch, and vault.**
   ```bash
   repo_root="$(git rev-parse --show-toplevel)"
   project="$(basename "$repo_root")"
   branch="$(git rev-parse --abbrev-ref HEAD)"
   vault="${BRAIN_VAULT_PATH:-$HOME/Source/brain}"
   ```

2. **Pull the full notes** (read-only):
   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/scripts/brain-recall.sh" "$vault" "$project" "$branch" full
   ```
   This prints `status.md`, `decisions.md`, `reference.md` in full,
   the current branch's `branches/<branch>/update.md` and `log.md` if
   present (in-progress feature work), feature files listed by name
   only, and any pending rollups. If it prints nothing, this project
   has no vault entry yet.

3. **Read a specific feature file if relevant.** The output above lists
   feature names but not their content. If one looks relevant to what
   you're doing, read it directly:
   `$vault/projects/$project/features/<feature-name>.md`.

4. **Use the content directly** in the conversation - summarize it for
   the user or use it as context for the current task. No further
   action or write-back is needed.
