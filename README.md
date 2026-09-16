# brain-tools

A Claude Code plugin that keeps a personal Obsidian project-knowledge
vault (`~/Source/brain` by default, overridable via `BRAIN_VAULT_PATH`)
up to date with what happens in your other git repos, and pulls it
back into future sessions.

**Writing:** a session-end hook automatically appends raw git-facts
breadcrumbs (commit range, diffstat, merge detection) to each
project's vault entry with no LLM involvement, and a `/brain-update`
skill you run deliberately to turn recent work into real synthesized
notes - status, decisions, feature write-ups, cross-project lessons.

**Reading:** a session-start hook automatically pulls that vault entry
back into the session - a full recap of status/decisions/reference/
in-progress branch work on a resumed session, or just a lightweight
list of what topics exist on a fresh session start (so the model can
decide what's worth reading in full). A `/brain-recall` skill pulls the
full notes on demand at any point in a session, without waiting for a
resume.

## Install

```bash
claude plugin marketplace add <path-to-this-repo>
claude plugin install brain-tools@brain-tools-dev
```

## Updating

`claude plugin install` copies a snapshot of this repo, pinned to the
commit it was installed from. Editing this repo does **not**
automatically update an already-installed copy - the installed plugin
is frozen at that snapshot. To ship changes to an installed copy, bump
the `version` field in **both** `.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json` together, then run:

```bash
claude plugin update brain-tools@brain-tools-dev
```

(`claude plugin install` on an unchanged plugin name reports "already
installed" and does nothing - `update` is the command that actually
picks up the bumped version.) A restart of Claude Code is required
before the update takes effect.

Note: a newly installed or updated plugin's skills only become visible
to Claude Code sessions started *after* the install/update - not the
session that ran the install command itself.
