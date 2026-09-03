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

  # prev_last_sha is only non-empty on a branch's second-or-later hook run.
  # A merge that lands during a branch's very first hook run (no prior
  # log.md yet) is a deliberate, permanent miss: scanning on the first run
  # would trivially flag the parent branch as "just merged," since the
  # parent's last commit is always an ancestor of a branch just cut from
  # it. Do not "fix" this by scanning on the first run — that reintroduces
  # the branch-off false-positive bug.
  if [ -n "$prev_last_sha" ]; then
    local branches_dir rollups_file other_log other_branch
    local other_rolled_up other_last
    branches_dir="$vault/projects/$project/branches"
    rollups_file="$vault/projects/$project/pending-rollups.md"
    if [ -d "$branches_dir" ]; then
      while IFS= read -r other_log; do
        other_branch="${other_log#"$branches_dir"/}"
        other_branch="${other_branch%/log.md}"
        [ "$other_branch" != "$branch" ] || continue
        other_rolled_up="$(fm_get "$other_log" rolled_up)"
        [ "$other_rolled_up" = "true" ] && continue
        other_last="$(fm_get "$other_log" last_sha)"
        [ -n "$other_last" ] || continue
        if git merge-base --is-ancestor "$other_last" "$prev_last_sha" 2>/dev/null; then
          continue
        fi
        if git merge-base --is-ancestor "$other_last" "$head_sha" 2>/dev/null; then
          fm_set "$other_log" merged "true"
          # -- is required: "- $other_branch" starts with "-", which grep would otherwise parse as an option.
          if [ -f "$rollups_file" ] && ! grep -qxF -- "- $other_branch" "$rollups_file"; then
            echo "- $other_branch" >> "$rollups_file"
          fi
        fi
      done < <(find "$branches_dir" -type f -name log.md)
    fi
  fi

  bash "$script_dir/brain-commit.sh" "$vault" "auto: session-end $project/$branch"
}

( main ) 2>>"${BRAIN_HOOK_DEBUG_LOG:-/dev/null}"
exit 0
