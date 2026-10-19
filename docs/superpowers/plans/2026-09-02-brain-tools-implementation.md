# Brain Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `brain-tools` Claude Code plugin: a session-end hook that leaves a cheap, no-LLM git-facts breadcrumb trail per branch, plus a `/brain-update` skill that does a deliberate, cheap-model synthesis of project notes into an Obsidian-browsable vault.

**Architecture:** Plain bash scripts (scaffold, facts, commit, rollup-complete) do every deterministic step with zero LLM involvement; a SessionEnd hook wires the breadcrumb trail and merge-detection into every git repo automatically; a skill wraps those scripts and dispatches a fresh, cheapest-model subagent to do the one genuinely judgment-requiring step (turning a session's facts into well-written markdown).

**Tech Stack:** bash, git, jq (for hook JSON stdin parsing). No other runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-09-02-brain-tools-design.md`

## Global Constraints

- Plugin name: `brain-tools`. Marketplace name (self-hosted in this same repo): `brain-tools-dev`.
- Default vault path: `~/Source/brain`, overridable via the `BRAIN_VAULT_PATH` environment variable.
- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail` (except where a task-local subshell intentionally isolates that, as in the hook).
- Scripts are invoked as `bash <path>`, not relying on the executable bit (still set `chmod +x` when committing, but nothing depends on it).
- `.claude-plugin/` is a fixed Claude Code convention (verified against the installed `superpowers` plugin) — never rename it.
- The session-end hook must never cause the shell to exit non-zero: all internal work runs in a subshell guarded by `|| true`, followed by an explicit `exit 0`.
- Frontmatter format across all vault files: a `key: value` line per key, between two lines that are exactly `---`, at the top of the file.
- `jq` is a required dependency of this plugin (used by the hook to parse its stdin JSON) — already present on this machine (`jq-1.8.1`).

---

### Task 1: Test assertion helper + frontmatter read/write library

**Files:**
- Create: `tests/lib/assert.sh`
- Create: `scripts/lib/frontmatter.sh`
- Test: `tests/test-frontmatter.sh`

**Interfaces:**
- Consumes: nothing (foundational).
- Produces:
  - `fm_get FILE KEY` — prints the value for `KEY` in `FILE`'s frontmatter, or an empty string if absent. Always exits 0.
  - `fm_set FILE KEY VALUE` — rewrites `FILE` in place, updating `KEY` if present in the frontmatter or inserting it (before the closing `---`) if not. Leaves the body and all other keys untouched.
  - Both are shell functions meant to be `source`d, not standalone executables.
  - `tests/lib/assert.sh` provides `assert_file_exists`, `assert_file_contains`, `assert_file_not_contains`, `assert_eq`, `pass` — all `source`d by every other test file in this plan.

- [ ] **Step 1: Create the test assertion helper**

File: `tests/lib/assert.sh`
```bash
#!/usr/bin/env bash
# Minimal assertion helpers for shell script tests.

assert_file_exists() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "FAIL: expected file to exist: $f" >&2
    exit 1
  fi
}

assert_file_contains() {
  local f="$1" pattern="$2"
  if ! grep -qF -- "$pattern" "$f"; then
    echo "FAIL: expected '$f' to contain: $pattern" >&2
    echo "--- actual content of $f ---" >&2
    cat "$f" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local f="$1" pattern="$2"
  if grep -qF -- "$pattern" "$f"; then
    echo "FAIL: expected '$f' NOT to contain: $pattern" >&2
    exit 1
  fi
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-values differ}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $msg (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

pass() {
  echo "PASS: $1"
}
```

- [ ] **Step 2: Write the failing test for frontmatter.sh**

File: `tests/test-frontmatter.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/scripts/lib/frontmatter.sh"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<'EOF'
---
project: demo
last_sha: abc123
---

# Body

Some content.
EOF

assert_eq "$(fm_get "$tmp" project)" "demo" "fm_get should read project"
assert_eq "$(fm_get "$tmp" last_sha)" "abc123" "fm_get should read last_sha"
assert_eq "$(fm_get "$tmp" missing)" "" "fm_get should return empty for missing key"

fm_set "$tmp" last_sha "def456"
assert_eq "$(fm_get "$tmp" last_sha)" "def456" "fm_set should update an existing key"
assert_file_contains "$tmp" "project: demo"
assert_file_contains "$tmp" "# Body"

fm_set "$tmp" merged "true"
assert_eq "$(fm_get "$tmp" merged)" "true" "fm_set should insert a new key"

pass "frontmatter.sh"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test-frontmatter.sh`
Expected: FAIL — `scripts/lib/frontmatter.sh: No such file or directory`

- [ ] **Step 4: Implement frontmatter.sh**

File: `scripts/lib/frontmatter.sh`
```bash
#!/usr/bin/env bash
# Read/write simple `key: value` frontmatter blocks delimited by `---` lines.

fm_get() {
  local file="$1" key="$2"
  local in_fm=0
  local line rest
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" -eq 0 ]; then
        in_fm=1
        continue
      else
        break
      fi
    fi
    if [ "$in_fm" -eq 1 ] && [[ "$line" == "$key":* ]]; then
      rest="${line#"$key":}"
      rest="${rest# }"
      printf '%s\n' "$rest"
      return 0
    fi
  done < "$file"
  printf '\n'
}

fm_set() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  local in_fm=0 fm_closed=0 key_written=0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$fm_closed" -eq 0 ] && [ "$line" = "---" ]; then
      if [ "$in_fm" -eq 0 ]; then
        in_fm=1
        printf '%s\n' "$line" >> "$tmp"
        continue
      else
        if [ "$key_written" -eq 0 ]; then
          printf '%s: %s\n' "$key" "$value" >> "$tmp"
        fi
        fm_closed=1
        in_fm=0
        printf '%s\n' "$line" >> "$tmp"
        continue
      fi
    fi
    if [ "$in_fm" -eq 1 ] && [[ "$line" == "$key":* ]]; then
      printf '%s: %s\n' "$key" "$value" >> "$tmp"
      key_written=1
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$file"
  mv "$tmp" "$file"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-frontmatter.sh`
Expected: `PASS: frontmatter.sh`, no `FAIL` lines.

- [ ] **Step 6: Commit**

```bash
chmod +x scripts/lib/frontmatter.sh
git add tests/lib/assert.sh scripts/lib/frontmatter.sh tests/test-frontmatter.sh
git commit -m "Add frontmatter read/write helper with tests"
```

---

### Task 2: Vault scaffolding script

**Files:**
- Create: `scripts/brain-scaffold.sh`
- Test: `tests/test-brain-scaffold.sh`

**Interfaces:**
- Consumes: nothing (foundational).
- Produces: `brain-scaffold.sh <vault-path> <project>` — idempotent. If `<vault>/projects/<project>/index.md` already exists, no-ops (exit 0) without touching any existing file. Otherwise creates `<vault>/projects/<project>/{index.md,status.md,decisions.md,reference.md,pending-rollups.md}` and empty `branches/`, `features/` directories.

- [ ] **Step 1: Write the failing test**

File: `tests/test-brain-scaffold.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
trap 'rm -rf "$vault"' EXIT

bash "$root/scripts/brain-scaffold.sh" "$vault" "demo-project"

proj="$vault/projects/demo-project"
assert_file_exists "$proj/index.md"
assert_file_exists "$proj/status.md"
assert_file_exists "$proj/decisions.md"
assert_file_exists "$proj/reference.md"
assert_file_exists "$proj/pending-rollups.md"
[ -d "$proj/branches" ] || { echo "FAIL: expected branches/ dir" >&2; exit 1; }
[ -d "$proj/features" ] || { echo "FAIL: expected features/ dir" >&2; exit 1; }

assert_file_contains "$proj/index.md" "project: demo-project"
assert_file_contains "$proj/status.md" "## Current Focus"
assert_file_contains "$proj/decisions.md" "# Decisions"
assert_file_contains "$proj/reference.md" "# Reference"
assert_file_contains "$proj/pending-rollups.md" "# Pending Rollups"

# Idempotency: existing content must survive a second run.
echo "MY CUSTOM NOTE" >> "$proj/status.md"
bash "$root/scripts/brain-scaffold.sh" "$vault" "demo-project"
assert_file_contains "$proj/status.md" "MY CUSTOM NOTE"

pass "brain-scaffold.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-brain-scaffold.sh`
Expected: FAIL — `scripts/brain-scaffold.sh: No such file or directory`

- [ ] **Step 3: Implement brain-scaffold.sh**

File: `scripts/brain-scaffold.sh`
```bash
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
See [[status]].

## Decisions
See [[decisions]].

## Reference
See [[reference]].

## Features
(none yet)
EOF

cat > "$project_dir/status.md" <<EOF
---
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
project: $project
---

# Decisions

Dated log of major project-wide design decisions. Newest entries at the
bottom.
EOF

cat > "$project_dir/reference.md" <<EOF
---
project: $project
---

# Reference

Architecture notes, key files, and gotchas for $project.
EOF

cat > "$project_dir/pending-rollups.md" <<EOF
---
project: $project
---

# Pending Rollups

Branches whose work has landed but hasn't been folded into the main
docs yet. Populated by the session-end hook; cleared by /brain-update.
EOF
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-brain-scaffold.sh`
Expected: `PASS: brain-scaffold.sh`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/brain-scaffold.sh
git add scripts/brain-scaffold.sh tests/test-brain-scaffold.sh
git commit -m "Add vault scaffolding script"
```

---

### Task 3: Git-facts reporter script

**Files:**
- Create: `scripts/brain-facts.sh`
- Test: `tests/test-brain-facts.sh`

**Interfaces:**
- Consumes: `fm_get` from `scripts/lib/frontmatter.sh` (Task 1).
- Produces: `brain-facts.sh <vault-path> <project> <branch>` — run with cwd inside the target git repo. Prints to stdout, read-only, no writes:
  - `head_sha=<sha>`
  - `last_sha=<sha-or-empty>`
  - if `last_sha` empty: `commits=(first snapshot for this branch)`
  - elif `last_sha == head_sha`: `commits=(no new commits)`
  - else: a `--- commits ---` section (`git log --oneline last_sha..head_sha`) then a `--- diffstat ---` section (`git diff --stat last_sha..head_sha`)
  - a trailing `--- pending-rollups ---` section: each `- <branch>` line from the project's `pending-rollups.md`, or `(none)` if there are none.

- [ ] **Step 1: Write the failing test**

File: `tests/test-brain-facts.sh`
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-brain-facts.sh`
Expected: FAIL — `scripts/brain-facts.sh: No such file or directory`

- [ ] **Step 3: Implement brain-facts.sh**

File: `scripts/brain-facts.sh`
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-brain-facts.sh`
Expected: `PASS: brain-facts.sh`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/brain-facts.sh
git add scripts/brain-facts.sh tests/test-brain-facts.sh
git commit -m "Add git-facts reporter script"
```

---

### Task 4: Vault commit script

**Files:**
- Create: `scripts/brain-commit.sh`
- Test: `tests/test-brain-commit.sh`

**Interfaces:**
- Consumes: nothing (foundational).
- Produces: `brain-commit.sh <vault-path> <message>` — no-ops (exit 0, no commit) if `git -C <vault> status --porcelain` is empty; otherwise stages everything and commits with `<message>`.

- [ ] **Step 1: Write the failing test**

File: `tests/test-brain-commit.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

vault="$(mktemp -d)"
trap 'rm -rf "$vault"' EXIT

git init -q -b main "$vault"
git -C "$vault" config user.email "test@example.com"
git -C "$vault" config user.name "Test"

bash "$root/scripts/brain-commit.sh" "$vault" "should not commit"
count_before="$(git -C "$vault" rev-list --count HEAD 2>/dev/null || echo 0)"
assert_eq "$count_before" "0" "brain-commit.sh must not commit when there is nothing to commit"

echo "hello" > "$vault/note.md"
bash "$root/scripts/brain-commit.sh" "$vault" "add note"
count_after="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$count_after" "1" "brain-commit.sh should create exactly one commit"

last_msg="$(git -C "$vault" log -1 --format=%s)"
assert_eq "$last_msg" "add note" "commit message should match what was passed"

pass "brain-commit.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-brain-commit.sh`
Expected: FAIL — `scripts/brain-commit.sh: No such file or directory`

- [ ] **Step 3: Implement brain-commit.sh**

File: `scripts/brain-commit.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: brain-commit.sh <vault-path> <message>" >&2
  exit 1
}

[ $# -eq 2 ] || usage

vault="$1"
message="$2"

if [ -z "$(git -C "$vault" status --porcelain)" ]; then
  exit 0
fi

git -C "$vault" add -A
git -C "$vault" commit -q -m "$message"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-brain-commit.sh`
Expected: `PASS: brain-commit.sh`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/brain-commit.sh
git add scripts/brain-commit.sh tests/test-brain-commit.sh
git commit -m "Add vault commit script"
```

---

### Task 5: Rollup-completion script

**Files:**
- Create: `scripts/brain-rollup-complete.sh`
- Test: `tests/test-brain-rollup-complete.sh`

**Interfaces:**
- Consumes: `fm_get`/`fm_set` from `scripts/lib/frontmatter.sh` (Task 1).
- Produces: `brain-rollup-complete.sh <vault-path> <project> <branch>` — sets that branch's `branches/<branch>/log.md` frontmatter `rolled_up: true`, and removes the `- <branch>` line from the project's `pending-rollups.md` if present.

- [ ] **Step 1: Write the failing test**

File: `tests/test-brain-rollup-complete.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/scripts/lib/frontmatter.sh"

vault="$(mktemp -d)"
trap 'rm -rf "$vault"' EXIT

bash "$root/scripts/brain-scaffold.sh" "$vault" "demo"
mkdir -p "$vault/projects/demo/branches/feature-x"
cat > "$vault/projects/demo/branches/feature-x/log.md" <<EOF
---
last_sha: abc123
merged: true
rolled_up: false
---

# Branch Log: feature-x
EOF
cat >> "$vault/projects/demo/pending-rollups.md" <<EOF
- feature-x
- feature-y
EOF

bash "$root/scripts/brain-rollup-complete.sh" "$vault" "demo" "feature-x"

assert_eq "$(fm_get "$vault/projects/demo/branches/feature-x/log.md" rolled_up)" "true" \
  "rolled_up should be flipped to true"
assert_file_not_contains "$vault/projects/demo/pending-rollups.md" "- feature-x"
assert_file_contains "$vault/projects/demo/pending-rollups.md" "- feature-y"

pass "brain-rollup-complete.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-brain-rollup-complete.sh`
Expected: FAIL — `scripts/brain-rollup-complete.sh: No such file or directory`

- [ ] **Step 3: Implement brain-rollup-complete.sh**

File: `scripts/brain-rollup-complete.sh`
```bash
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

fm_set "$log_file" rolled_up "true"

if [ -f "$rollups_file" ]; then
  tmp="$(mktemp)"
  grep -vxF "- $branch" "$rollups_file" > "$tmp" || true
  mv "$tmp" "$rollups_file"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-brain-rollup-complete.sh`
Expected: `PASS: brain-rollup-complete.sh`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/brain-rollup-complete.sh
git add scripts/brain-rollup-complete.sh tests/test-brain-rollup-complete.sh
git commit -m "Add rollup-completion script"
```

---

### Task 6: Session-end hook script

**Files:**
- Create: `scripts/brain-hook.sh`
- Test: `tests/test-brain-hook.sh`

**Interfaces:**
- Consumes: `fm_get`/`fm_set` (Task 1), `brain-scaffold.sh` (Task 2), `brain-commit.sh` (Task 4). Reads JSON on stdin with at least a `cwd` field (the Claude Code `SessionEnd` hook payload).
- Produces: a script with no stdout/stderr contract other than optional debug logging to `$BRAIN_HOOK_DEBUG_LOG` if set; **always exits 0**, regardless of internal failures.

Merge-detection nuance worth calling out for whoever implements this: a branch's own **first** hook run (its `log.md` doesn't exist yet) must skip the merge-scan entirely — otherwise a brand-new branch would immediately and incorrectly flag its parent branch as "just merged," since the parent's last commit is trivially an ancestor of a branch that was just cut from it. The scan only runs when there's a previous recorded `last_sha` to compare against, and only flags another branch as newly merged if that branch's `last_sha` was **not** an ancestor of *this* branch's previous state but **is** an ancestor of its new state — i.e., a real transition happened this session, not an artifact of ordinary branching.

- [ ] **Step 1: Write the failing test**

File: `tests/test-brain-hook.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/scripts/lib/frontmatter.sh"

vault="$(mktemp -d)"
repo="$(mktemp -d)"
trap 'rm -rf "$vault" "$repo"' EXIT

git init -q -b main "$vault"
git -C "$vault" config user.email "vault@example.com"
git -C "$vault" config user.name "Vault"

git init -q -b main "$repo"
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
echo "one" > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m "first commit"

project="$(basename "$repo")"

run_hook() {
  local cwd="$1"
  printf '{"cwd": "%s"}' "$cwd" | BRAIN_VAULT_PATH="$vault" bash "$root/scripts/brain-hook.sh"
}

# --- First session-end: creates the initial log entry and vault commit. ---
run_hook "$repo"

log_file="$vault/projects/$project/branches/main/log.md"
assert_file_exists "$log_file"
assert_file_contains "$log_file" "Initial snapshot"

vault_commits_1="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$vault_commits_1" "1" "first hook run should create exactly one vault commit"

# --- Second session-end with no new commits: must be a no-op. ---
run_hook "$repo"
vault_commits_2="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$vault_commits_2" "1" "hook run with no new commits must not create a vault commit"

# --- Third session-end after a new commit: appends an entry. ---
echo "two" > "$repo/file2.txt"
git -C "$repo" add file2.txt
git -C "$repo" commit -q -m "second commit"
run_hook "$repo"
assert_file_contains "$log_file" "second commit"
vault_commits_3="$(git -C "$vault" rev-list --count HEAD)"
assert_eq "$vault_commits_3" "2" "hook run with new commits should create one more vault commit"

# --- Branching off main must NOT flag main as "merged" into the new branch. ---
git -C "$repo" checkout -q -b feature
echo "three" > "$repo/file3.txt"
git -C "$repo" add file3.txt
git -C "$repo" commit -q -m "feature commit"
run_hook "$repo"

feature_log="$vault/projects/$project/branches/feature/log.md"
assert_file_exists "$feature_log"
assert_file_not_contains "$vault/projects/$project/pending-rollups.md" "- main"

# --- Merging feature into main must flag it as newly merged. ---
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff feature -m "merge feature"
run_hook "$repo"

assert_eq "$(fm_get "$feature_log" merged)" "true" "feature branch should be marked merged"
assert_file_contains "$vault/projects/$project/pending-rollups.md" "- feature"

pass "brain-hook.sh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-brain-hook.sh`
Expected: FAIL — `scripts/brain-hook.sh: No such file or directory`

- [ ] **Step 3: Implement brain-hook.sh**

File: `scripts/brain-hook.sh`
```bash
#!/usr/bin/env bash
# Session-end hook: cheap, no-LLM breadcrumb trail for the brain vault.
# Must never fail the session: all work runs in a guarded subshell and
# this script always exits 0.

main() {
  set -euo pipefail

  local input cwd
  input="$(cat)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  [ -n "$cwd" ] || return 0

  cd "$cwd" 2>/dev/null || return 0
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 0

  local repo_root project branch vault script_dir
  repo_root="$(git rev-parse --show-toplevel)"
  project="$(basename "$repo_root")"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" != "HEAD" ] || return 0

  vault="${BRAIN_VAULT_PATH:-$HOME/Source/brain}"
  [ -d "$vault/.git" ] || return 0

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$script_dir/lib/frontmatter.sh"

  bash "$script_dir/brain-scaffold.sh" "$vault" "$project"

  local branch_dir log_file head_sha prev_last_sha
  branch_dir="$vault/projects/$project/branches/$branch"
  log_file="$branch_dir/log.md"
  mkdir -p "$branch_dir"
  head_sha="$(git rev-parse HEAD)"
  prev_last_sha=""

  if [ ! -f "$log_file" ]; then
    cat > "$log_file" <<EOF
---
last_sha: $head_sha
merged: false
rolled_up: false
---

# Branch Log: $branch

## $(date '+%Y-%m-%d %H:%M')
Initial snapshot at $head_sha ($(git log -1 --format=%s "$head_sha")).
EOF
  else
    prev_last_sha="$(fm_get "$log_file" last_sha)"
    if [ -n "$prev_last_sha" ] && [ "$prev_last_sha" != "$head_sha" ]; then
      {
        echo
        echo "## $(date '+%Y-%m-%d %H:%M')"
        git log --oneline "$prev_last_sha..$head_sha"
        echo
        git diff --stat "$prev_last_sha..$head_sha"
      } >> "$log_file"
      fm_set "$log_file" last_sha "$head_sha"
    fi
  fi

  if [ -n "$prev_last_sha" ]; then
    local branches_dir rollups_file other_dir other_branch other_log
    local other_rolled_up other_last
    branches_dir="$vault/projects/$project/branches"
    rollups_file="$vault/projects/$project/pending-rollups.md"
    if [ -d "$branches_dir" ]; then
      for other_dir in "$branches_dir"/*/; do
        [ -d "$other_dir" ] || continue
        other_branch="$(basename "$other_dir")"
        [ "$other_branch" != "$branch" ] || continue
        other_log="$other_dir/log.md"
        [ -f "$other_log" ] || continue
        other_rolled_up="$(fm_get "$other_log" rolled_up)"
        [ "$other_rolled_up" = "true" ] && continue
        other_last="$(fm_get "$other_log" last_sha)"
        [ -n "$other_last" ] || continue
        if git merge-base --is-ancestor "$other_last" "$prev_last_sha" 2>/dev/null; then
          continue
        fi
        if git merge-base --is-ancestor "$other_last" "$head_sha" 2>/dev/null; then
          fm_set "$other_log" merged "true"
          if [ -f "$rollups_file" ] && ! grep -qxF "- $other_branch" "$rollups_file"; then
            echo "- $other_branch" >> "$rollups_file"
          fi
        fi
      done
    fi
  fi

  bash "$script_dir/brain-commit.sh" "$vault" "auto: session-end $project/$branch"
}

( main ) 2>>"${BRAIN_HOOK_DEBUG_LOG:-/dev/null}" || true
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-brain-hook.sh`
Expected: `PASS: brain-hook.sh`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/brain-hook.sh
git add scripts/brain-hook.sh tests/test-brain-hook.sh
git commit -m "Add session-end hook with merge detection"
```

---

### Task 7: Plugin manifest and hook wiring

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `hooks/hooks.json`
- Test: `tests/test-plugin-manifests.sh`

**Interfaces:**
- Consumes: `scripts/brain-hook.sh` (Task 6), via the `${CLAUDE_PLUGIN_ROOT}` variable Claude Code substitutes at hook-execution time.
- Produces: an installable plugin named `brain-tools`, listed in a self-hosted marketplace named `brain-tools-dev`, wiring `scripts/brain-hook.sh` to the `SessionEnd` event.

- [ ] **Step 1: Write the failing test**

File: `tests/test-plugin-manifests.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

jq empty "$root/.claude-plugin/plugin.json"
jq empty "$root/.claude-plugin/marketplace.json"
jq empty "$root/hooks/hooks.json"

assert_eq "$(jq -r '.name' "$root/.claude-plugin/plugin.json")" "brain-tools" \
  "plugin.json name must be brain-tools"

assert_eq "$(jq -r '.name' "$root/.claude-plugin/marketplace.json")" "brain-tools-dev" \
  "marketplace.json name must be brain-tools-dev"
assert_eq "$(jq -r '.plugins[0].name' "$root/.claude-plugin/marketplace.json")" "brain-tools" \
  "marketplace.json must list the brain-tools plugin"

assert_eq "$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$root/hooks/hooks.json")" \
  'bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain-hook.sh"' \
  "hooks.json must wire SessionEnd to brain-hook.sh via CLAUDE_PLUGIN_ROOT"

pass "plugin-manifests"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-plugin-manifests.sh`
Expected: FAIL — `.claude-plugin/plugin.json: No such file or directory` (from the first `jq empty`)

- [ ] **Step 3: Create the manifests**

File: `.claude-plugin/plugin.json`
```json
{
  "name": "brain-tools",
  "description": "Session-end git-facts breadcrumbs and a deliberate /brain-update skill for a personal Obsidian project-knowledge vault",
  "version": "0.1.0",
  "author": {
    "name": "Nicholas Whay",
    "email": "169461794+bythewhay@users.noreply.github.com"
  },
  "license": "UNLICENSED",
  "keywords": [
    "knowledge-base",
    "obsidian",
    "notes",
    "hooks"
  ]
}
```

File: `.claude-plugin/marketplace.json`
```json
{
  "name": "brain-tools-dev",
  "description": "Personal marketplace for the brain-tools plugin",
  "owner": {
    "name": "Nicholas Whay",
    "email": "169461794+bythewhay@users.noreply.github.com"
  },
  "plugins": [
    {
      "name": "brain-tools",
      "description": "Session-end git-facts breadcrumbs and a deliberate /brain-update skill for a personal Obsidian project-knowledge vault",
      "version": "0.1.0",
      "source": "./",
      "author": {
        "name": "Nicholas Whay",
        "email": "169461794+bythewhay@users.noreply.github.com"
      }
    }
  ]
}
```

File: `hooks/hooks.json`
```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "clear|resume|logout|prompt_input_exit|other",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/brain-hook.sh\"",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-plugin-manifests.sh`
Expected: `PASS: plugin-manifests`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json tests/test-plugin-manifests.sh
git commit -m "Add plugin manifest, marketplace listing, and SessionEnd hook wiring"
```

---

### Task 8: `/brain-update` skill

**Files:**
- Create: `skills/brain-update/SKILL.md`
- Test: `tests/test-brain-update-skill.sh`

**Interfaces:**
- Consumes: `scripts/brain-scaffold.sh`, `scripts/brain-facts.sh`, `scripts/brain-commit.sh`, `scripts/brain-rollup-complete.sh` (Tasks 2-5), the `Agent` tool (for dispatch).
- Produces: a skill invocable as `/brain-tools:brain-update` once the plugin is installed.

This is a prose/instructions file the running Claude follows, not code with its own logic — its "test" is a structural smoke test (are the right scripts and dispatch parameters actually named in it) plus a real manual run in Task 9.

- [ ] **Step 1: Write the failing test**

File: `tests/test-brain-update-skill.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/tests/lib/assert.sh"

skill="$root/skills/brain-update/SKILL.md"
assert_file_exists "$skill"
assert_file_contains "$skill" "name: brain-update"
assert_file_contains "$skill" "description:"
assert_file_contains "$skill" "brain-scaffold.sh"
assert_file_contains "$skill" "brain-facts.sh"
assert_file_contains "$skill" "brain-commit.sh"
assert_file_contains "$skill" "brain-rollup-complete.sh"
assert_file_contains "$skill" "haiku"

pass "brain-update-skill"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-brain-update-skill.sh`
Expected: FAIL — `skills/brain-update/SKILL.md: No such file or directory`

- [ ] **Step 3: Write the skill**

File: `skills/brain-update/SKILL.md`
```markdown
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
   vault="${BRAIN_VAULT_PATH:-$HOME/Source/brain}"
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
     branch's `update.md`, merge its content into the appropriate main
     docs, then run
     `bash "$CLAUDE_PLUGIN_ROOT/scripts/brain-rollup-complete.sh" "$vault" "$project" "<branch>"`.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-brain-update-skill.sh`
Expected: `PASS: brain-update-skill`, no `FAIL` lines.

- [ ] **Step 5: Commit**

```bash
git add skills/brain-update/SKILL.md tests/test-brain-update-skill.sh
git commit -m "Add /brain-update skill"
```

---

### Task 9: Real vault init, local plugin install, end-to-end verification

**Files:**
- Create (outside this repo): `~/Source/brain/.git` (a new, separate git repo — the actual vault, per the design's separation of tooling from content)
- No test file — this task's verification is a manual, scripted walkthrough against the real (not temp) environment.

**Interfaces:**
- Consumes: this whole plugin, installed via the `claude` CLI.
- Produces: a working installed plugin, a real vault repo ready for use, and one demonstrated hook run against a scratch repo.

- [ ] **Step 1: Initialize the real vault repo**

```bash
ls -la ~/Source/brain   # confirm it's still empty before initializing
cd ~/Source/brain
git init
git config user.name "Nicholas Whay"
git config user.email "169461794+bythewhay@users.noreply.github.com"
echo "# Brain" > README.md
git add README.md
git commit -m "Initialize brain vault"
```

Expected: a new repo at `~/Source/brain` with one commit.

- [ ] **Step 2: Register the marketplace and install the plugin**

```bash
claude plugin marketplace add /var/home/nswhay/Source/ClaudeBrainPlugin
claude plugin install brain-tools@brain-tools-dev
claude plugin list
```

Expected: `claude plugin list` shows `brain-tools` installed and enabled.

- [ ] **Step 3: Exercise the installed hook against a scratch repo**

```bash
scratch="$(mktemp -d)"
git init -q -b main "$scratch"
git -C "$scratch" config user.email "test@example.com"
git -C "$scratch" config user.name "Test"
echo "hello" > "$scratch/file.txt"
git -C "$scratch" add file.txt
git -C "$scratch" commit -q -m "scratch commit"

installed_hook="$(find ~/.claude/plugins -path '*brain-tools*/scripts/brain-hook.sh' | head -1)"
echo "$installed_hook"
printf '{"cwd": "%s"}' "$scratch" | bash "$installed_hook"

cat ~/Source/brain/projects/"$(basename "$scratch")"/branches/main/log.md
git -C ~/Source/brain log --oneline -3

rm -rf "$scratch"
```

Expected: the `find` command locates the installed copy of `brain-hook.sh` under `~/.claude/plugins`; the `log.md` it prints shows an "Initial snapshot" entry; `git log` on the vault shows a new `auto: session-end ...` commit.

- [ ] **Step 4: Confirm the skill is discoverable**

Start a Claude Code session in any git repo and run `/brain-tools:brain-update`, or ask "what skills are available" and confirm `brain-tools:brain-update` is listed. Do one real run of it in a small repo with a couple of recent commits, and confirm:
- `~/Source/brain/projects/<that-repo>/` has sensible `status.md`/`decisions.md` content reflecting the session.
- `git log` in `~/Source/brain` shows a new commit from the skill run.

- [ ] **Step 5: Commit any leftover changes**

If Step 1 left the vault repo uncommitted beyond the initial commit (it shouldn't), commit them. No commit is needed in the `ClaudeBrainPlugin` repo for this task, since it makes no code changes there.

---

## Self-Review Notes

- **Spec coverage:** vault structure and templates (Task 2), session-end hook + merge detection (Task 6), branch staging + rollup (Tasks 5, 8), `/brain-update` behavior (Task 8), model-aware dispatch to the cheapest model (Task 8, step 6), scripting boundary (Tasks 2-5 are all script-only, no model involved), plugin packaging (Task 7), multi-machine setup (Task 9 documents the same steps a second machine would run), error handling / never-block guarantee (Task 6's subshell + `|| true` + `exit 0`).
- **Placeholder scan:** no TBD/TODO markers; every step has literal, runnable code.
- **Type/interface consistency:** `fm_get`/`fm_set` signatures are identical everywhere they're used (Tasks 3, 5, 6). Script argument orders (`<vault> <project> [<branch>]`) are consistent across `brain-scaffold.sh`, `brain-facts.sh`, `brain-rollup-complete.sh`, and `brain-hook.sh`'s internal calls.
- **Fixed correctness issue found during planning:** the original spec's merge-detection description didn't account for a brand-new branch trivially satisfying the ancestry check against its own parent. Task 6 implements and tests the corrected version (compare against the branch's *previous* recorded state, not just its current one), and the test in Task 6 explicitly covers the branch-off case to guard against regressing this.
