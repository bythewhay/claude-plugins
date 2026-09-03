# Brain Tools — Design

## Overview

A persistent, Obsidian-browsable knowledge base ("the brain") for
tracking project state, decisions, and cross-project technical
knowledge, plus the automation to keep it updated without burning
unnecessary tokens.

Two repositories, kept separate on purpose:

- **`ClaudeBrainPlugin`** (this repo) — a private Claude Code plugin:
  the session-end hook, helper scripts, and the `/brain-update` skill.
  Clone + install on any machine to get the automation.
- **The vault** (default path `~/Source/brain`, overridable via
  `BRAIN_VAULT_PATH`) — a separate private git repo holding the actual
  notes. Clone it independently of the plugin.

Tooling and content evolve at different rates and belong in different
repos: the vault is data you write by hand or via `/brain-update`; the
plugin is code you version and reuse across machines.

## Goals

- Track, per project: current status, major decisions, per-feature
  detail, and reference/architecture notes.
- Track cross-project technical knowledge ("lessons") separately from
  project-specific notes.
- Keep a cheap, automatic breadcrumb trail (git facts only, no LLM
  calls) so nothing is lost even when you never run a manual update.
- Provide a deliberate, on-demand command for a real synthesized
  update, invoked when you actually want one.
- Correctly reflect a branch's work once it lands on another branch —
  whether merged locally or pulled in after a remote PR merge — without
  polluting the main project docs while that branch is still in flight.
- Minimize token cost: push every deterministic step into plain
  scripts, and route the one step that must use an LLM to the cheapest
  model by default.
- Be portable across machines: clone plugin + vault, install, done.

## Non-goals

- Not a public/shareable plugin (private repo, personal use).
- Not enforcing a rigid, code-parsed schema for project docs — only
  the auto-hook's log files have a fixed format; everything else is
  markdown maintained by the skill's judgment and free to evolve.
- No scheduled/cron sweeps, no automatic multi-project digesting.
- No locking/concurrency handling beyond what git itself provides —
  single-user, solo use.

## Vault structure

```
brain/                              (own git repo; default ~/Source/brain)
  projects/
    <project>/                      named by git repo folder basename
      index.md                      table of contents: links to status,
                                     decisions, reference, each feature file
      status.md                     project-wide current focus, recent
                                     progress, next steps, open questions
      decisions.md                  major/project-wide design decisions:
                                     dated log of decision, rationale,
                                     alternatives considered
      reference.md                  architecture notes, key files, gotchas;
                                     edited in place, grows organically
      features/
        <feature-name>.md           one file per feature: its own status +
                                     decisions + notes, scoped to that feature
      branches/
        <branch>/
          log.md                    hook-owned: raw git facts, fixed format
          update.md                 skill-owned: staged detailed update for
                                     this branch's in-flight work
      pending-rollups.md            list of branches whose work has landed
                                     elsewhere but hasn't been folded into
                                     the main docs yet
  lessons/
    <topic>.md                      cross-project technical/architectural
                                     knowledge (frontmatter: name,
                                     description, related projects)
```

All files carry light YAML frontmatter (project, dates, tags) and use
`[[wikilinks]]` to cross-reference related notes (e.g. a decision
linking to a lesson). This is still just markdown — it works fine
outside Obsidian, and is nicer inside it.

**Schema stability boundary:** only `branches/<branch>/log.md` has a
script that depends on its exact format (the hook parses and writes
its frontmatter). Every other file — `index.md`, `status.md`,
`decisions.md`, `reference.md`, `features/*.md`, `lessons/*.md` — is
maintained by the `/brain-update` skill's judgment, not by parsing
code. The structure can evolve later (new file types, further splits)
by editing the skill's instructions alone.

## Session-end hook (pure script, no tokens)

Fires on Claude Code's `SessionEnd` event, installed globally by the
plugin. Logic, entirely in shell/git, no LLM calls:

1. If the session's working directory isn't inside a git repo, or
   `HEAD` is detached, no-op.
2. Resolve project name (git repo root folder basename) and current
   branch.
3. Resolve vault path (`$BRAIN_VAULT_PATH`, else `~/Source/brain`).
   Run `brain-scaffold.sh <project>` if this project hasn't been seen
   before (creates the folder + templated files, including
   `index.md`).
4. Read `last_sha` from `branches/<branch>/log.md` frontmatter (absent
   on first run for that branch).
5. If `last_sha` differs from current `HEAD`: compute
   `git log --oneline last_sha..HEAD` and
   `git diff --stat last_sha..HEAD`, append a dated entry to
   `branches/<branch>/log.md`, update `last_sha`. If there were no new
   commits this session, skip the write — no noise entries.
6. **Merge detection**: for every other branch folder under
   `branches/` not marked `rolled_up: true`, check
   `git merge-base --is-ancestor <that branch's last_sha> HEAD`. If
   true, mark that branch's `log.md` frontmatter `merged: true` and add
   it to `pending-rollups.md` if not already listed.
   - This needs no knowledge of which branch is "main" and no network
     call: it just checks ancestry against whatever `HEAD` you're
     currently on, so it catches both a local merge and a remote PR
     merge you've since pulled, using the branch's own last-known SHA
     rather than a possibly-deleted branch ref.
7. Commit the vault repo (`brain-commit.sh`), silently.

Hook failures must never block or visibly disrupt a session — errors
are swallowed (optionally appended to a local debug log), not
surfaced.

## `/brain-update` skill

Deliberate, on-demand, invoked in a project's own session:

1. Resolve project + branch; run `brain-scaffold.sh` if new.
2. Run `brain-facts.sh <project> <branch>` — a plain script that
   gathers `git log`/`git diff --stat` since `last_sha` and prints the
   contents of `pending-rollups.md`. No LLM involved.
3. **Rollup check**: for each branch listed in `pending-rollups.md`,
   read that branch's `update.md` (+ `log.md` for factual grounding)
   and fold the relevant content into `status.md` / `decisions.md` /
   `reference.md` / `features/*.md` / `index.md` as appropriate. Mark
   that branch `rolled_up: true` and remove it from
   `pending-rollups.md`. This is synthesis, so it happens via the
   dispatch step below, not the script.
4. In the **current session** (whatever model you're using to code),
   write a short brief: what happened, what's a decision vs. routine
   progress, grounded in the facts script's output and the live
   conversation (free — already in context). This is cheap regardless
   of model, since it's a short summary, not the bulk of the writing.
5. Dispatch a **fresh** `general-purpose` subagent, always on the
   cheapest available model (Haiku) by default, with the brief plus
   the facts script's output as its prompt. It does the actual
   markdown writing:
   - On a feature branch → into `branches/<branch>/update.md`.
   - On a branch with no clear "in-progress feature" framing → directly
     into `status.md` / `decisions.md` / `reference.md`.
   - New feature work discovered → create `features/<name>.md`, link
     it from `index.md`.
   - Anything generalizable across projects (same applicable/durable/
     legible bar as the existing auto-memory system) → add or update a
     file under `lessons/`.
   - Any pending rollups identified in step 3.
   - Finish by calling `brain-commit.sh`.

A **fork** subagent inherits full conversation context but always runs
on the parent model — it cannot downgrade to a cheaper model. That's
why this design uses a brief handed to a *fresh* subagent instead: the
fresh agent has no memory of the conversation, so the brief has to
carry everything it needs, but the model that renders it into markdown
can be the cheapest one available.

If Haiku's output quality turns out to be a problem for complex
rollups, that's a tuning change to make later (e.g. re-introducing a
tiered choice), not upfront complexity now.

## Scripts (shared by hook and skill, no model involved)

- `brain-scaffold.sh <project>` — creates `projects/<project>/` with
  templated `index.md`, `status.md`, `decisions.md`, `reference.md` if
  missing.
- `brain-facts.sh <project> <branch>` — prints git log/diff-stat since
  `last_sha` and the current `pending-rollups.md` contents, as plain
  structured text.
- `brain-commit.sh` — stages and commits the vault repo.

Keeping scaffolding, fact-gathering, and committing as plain scripts
means the only tokens spent are on the two genuinely judgment-requiring
steps: summarizing what happened, and turning that summary into
well-written notes.

## Plugin repo layout

```
ClaudeBrainPlugin/                   (this repo; private)
  .claude-plugin/
    plugin.json                      manifest (name, version, description)
    marketplace.json                 self-hosted marketplace listing this
                                      one plugin
  hooks/
    hooks.json                       declares SessionEnd -> scripts/brain-hook.sh
  scripts/
    brain-hook.sh
    brain-scaffold.sh
    brain-facts.sh
    brain-commit.sh
  skills/
    brain-update/
      SKILL.md
```

`.claude-plugin/` is a fixed convention the Claude Code loader scans
for in every plugin (confirmed against the installed `superpowers`
plugin, which uses the identical folder name) — it is not a
distinguishing name for this plugin. This plugin's identity comes from
the `name` field inside `plugin.json`; future plugins get their own
repo with their own identically-named `.claude-plugin/` folder, so
there's no collision.

## Multi-machine setup

1. Clone `ClaudeBrainPlugin`.
2. `claude plugin marketplace add <path-or-url>`, then
   `claude plugin install <plugin-name>@<marketplace-name>`.
3. Clone (or init) the vault repo, by default at `~/Source/brain`; set
   `BRAIN_VAULT_PATH` if it lives elsewhere on this machine.

Creating the actual private remote repos (for the plugin and for the
vault) is a decision to make at implementation time, not part of this
design.

## Error handling

- Hook failures never block or visibly disrupt a session.
- Non-git directories, detached HEAD, or unresolvable vault path →
  hook no-ops.
- Concurrent sessions writing the same branch's `log.md` → last-write-
  wins; acceptable for solo use, not worth locking.

## Testing

- Scripts: manual/bats-style checks during implementation — scaffold a
  temp repo, run the hook, assert file contents; simulate a merge and
  assert `pending-rollups.md` picks it up.
- Skill: validated by actually running `/brain-update` against a
  scratch project once built, per the normal TDD/verification
  workflow.

## Open questions / future work

- Whether Haiku's output quality is sufficient for complex, multi-
  branch rollups, or whether model tiering should be reintroduced
  later.
- Whether/when to create the actual private remote repos for the vault
  and the plugin, and where (GitHub private repo, etc.) — deferred to
  implementation.
