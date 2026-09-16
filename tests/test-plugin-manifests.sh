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

assert_eq "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$root/hooks/hooks.json")" \
  'bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain-session-start.sh"' \
  "hooks.json must wire SessionStart to brain-session-start.sh via CLAUDE_PLUGIN_ROOT"

pass "plugin-manifests"
