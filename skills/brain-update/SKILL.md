---
name: brain-update
description: Use when you want to record a deliberate, synthesized update to a project's brain vault (status, decisions, features, reference) after doing real work in this session - reads existing notes and git facts, then dispatches a cheap subagent to write the update and commit it.
---

# Brain Update

## Overview

Writes a deliberate, synthesized update to this project's notes in the
brain vault. Unlike the automatic session-end hook (which only logs
raw git facts with no LLM involvement), this skill actually reads what
happened and writes real prose: status, decisions, feature notes,
cross-project lessons.

Token cost is kept down two ways: every deterministic step (finding
the project, gathering git facts, scaffolding new files, committing)
is a plain script, not something you do by hand with Read/Write/Bash.
And the one step that must use judgment - turning facts into
well-written notes - is handed to a fresh subagent on the cheapest
available model, not done in the current (possibly more expensive)
session.

## Steps

1. **Resolve project, branch, and vault.**
   ```bash
   repo_root="$(git rev-parse --show-toplevel)"
   project="$(basename "$repo_root")"
   branch="$(git rev-parse --abbrev-ref HEAD)"
   vault="${BRAIN_VAULT_PATH:-$HOME/Source/vault}"
   ```

2. **Scaffold if needed** (idempotent - safe to always run):
   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/scripts/brain-scaffold.sh" "$vault" "$project"
   ```

3. **Gather facts** (read-only, no writes):
   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/scripts/brain-facts.sh" "$vault" "$project" "$branch"
   ```
   This prints the commit range and diffstat since the last hook
   snapshot, plus any branches listed in `pending-rollups.md` for this
   project.

4. **Read existing notes for context.** Read (don't summarize at
   length - just skim) `$vault/projects/$project/index.md`,
   `status.md`, `decisions.md`, and any `features/*.md` files that
   look relevant to what changed this session. If a branch named in
   `pending-rollups.md` needs folding in, also read that branch's
   `branches/<branch>/update.md` and `branches/<branch>/log.md`.

5. **Write a short brief, in this session.** In a few bullet points,
   using the live conversation plus the facts from step 3: what
   actually happened, what (if anything) was a real decision versus
   routine progress, which feature(s) this touches, and whether any
   pending rollup needs folding in. Keep this brief - it is the only
   part of this skill that must run in the current session's model,
   and it should stay short regardless of that model's cost.

6. **Dispatch a fresh subagent to do the writing**, always on the
   cheapest available model (do not use a fork - a fork inherits this
   session's model and cannot downgrade). Use the `Agent` tool with
   `subagent_type: "general-purpose"` and `model: "haiku"`. The prompt
   must be self-contained (the subagent has no memory of this
   conversation) and must include:
   - The vault path, project name, and branch name.
   - The brief from step 5.
   - The raw facts output from step 3.
   - The exact target files to edit, following this rule: on a branch
     that represents in-progress feature work, write into
     `$vault/projects/$project/branches/$branch/update.md` (create it
     if missing, using the template below) instead of touching the
     main project docs. On a branch with no distinct in-progress
     feature (general maintenance, or you're on the trunk branch),
     write directly into `status.md` / `decisions.md` / `reference.md`
     as appropriate. If new feature work was discovered, create
     `features/<feature-name>.md` and add a link to it under the
     "Features" section of `index.md`.
   - Instructions to fold in any pending rollups: for each branch
     named in the facts output's `pending-rollups` section, read that
     branch's `log.md` (always present - the automatic session-end
     hook writes it even when `/brain-update` is never run on that
     branch) and its `update.md` if it exists. If only `log.md` is
     present, synthesize the rollup content from the git facts and
     commit messages it contains instead of treating `update.md` as
     required. Merge whatever content results into the appropriate
     main docs, then run
     `bash "$CLAUDE_PLUGIN_ROOT/scripts/brain-rollup-complete.sh" "$vault" "$project" "<branch>"`.
     If that script (or any other script the subagent runs) exits
     non-zero, stop and report the failure to the user rather than
     continuing silently.
   - Instructions to check `$vault/projects/$project/run.md` (how to
     start the program: entry point, arguments, exact command). If it
     is still the empty scaffolded template (no content under its
     headings), inspect the repo directly (package.json, Makefile,
     pyproject.toml, Dockerfile, README, CLI entry scripts, etc.) and
     fill in the entry point, arguments, and exact command from
     scratch. If it already has real content, leave it untouched
     unless this session's brief or facts show that how the program is
     started actually changed (new/renamed entrypoint, changed launch
     script, changed CLI flags) - in that case update only the parts
     that changed.
   - Instructions to consider whether anything learned is generalizable
     across projects (the same applicable/durable/legible bar used for
     Claude's own memory files) - if so, add or update a file under
     `$vault/lessons/`.
   - A final instruction to run
     `bash "$CLAUDE_PLUGIN_ROOT/scripts/brain-commit.sh" "$vault" "<a descriptive commit message>"`
     once all edits are made.

   `branches/<branch>/update.md` template, for the subagent to create
   if it doesn't already exist:
   ```markdown
   ---
   project: <project>
   branch: <branch>
   ---

   # <branch>: staged update

   ## Status

   ## Decisions

   ## Notes
   ```

7. **Report back** to the user, briefly, what was updated (which files
   changed, whether any rollup was folded in).

If Haiku's output quality turns out to be a problem for a particularly
complex, multi-branch rollup, that's a reason to reconsider the model
choice for that dispatch later - not a reason to do the writing
yourself in the current session by default.
