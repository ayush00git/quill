#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

agent="$REPO_ROOT/agents/pr-reviewer.md"

# field <name>: a top-level frontmatter value.
field() {
  sed -n '2,/^---$/p' "$agent" | sed -n "s/^$1: //p"
}

@test "pr-reviewer frontmatter: name, read-only tools, inherited model, no CLAUDE.md" {
  [ "$(head -1 "$agent")" = "---" ]
  [ "$(field name)" = "pr-reviewer" ]
  [ "$(field tools)" = "Read, Grep, Glob, Bash" ]
  [ "$(field model)" = "inherit" ]
  [ "$(field omitClaudeMd)" = "true" ]
  [ -n "$(field description)" ]
}

@test "frontmatter fields plugin agents ignore are absent (enforcement lives in hooks/)" {
  run sed -n '2,/^---$/p' "$agent"
  [[ "$output" != *"hooks:"* ]] || false
  [[ "$output" != *"permissionMode:"* ]] || false
  [[ "$output" != *"mcpServers:"* ]] || false
}

@test "the guard hook targets this agent's plugin-scoped name" {
  local plugin
  plugin="$(jq -r .name "$REPO_ROOT/.claude-plugin/plugin.json")"
  grep -q "^REVIEWER_AGENT='$plugin:$(field name)'\$" "$REPO_ROOT/hooks/guard.sh"
}

@test "the prompt points at the bundle, the references and the output contract" {
  local w
  for w in task.json meta.json risk.json guidance/ notes.md prev/ refsDir review-standard.md comment-style.md \
    review-template.md output-contract.md nonce "git -C <worktree root>"; do
    grep -qF -- "$w" "$agent" || {
      echo "missing: $w"
      false
    }
  done
}

@test "the agent prompt follows the comment style it asks for (no em dashes)" {
  run grep -n $'\xe2\x80\x94' "$agent"
  [ "$status" -eq 1 ]
}
