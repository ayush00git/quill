#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

skill="$REPO_ROOT/skills/quill/SKILL.md"

field() {
  sed -n '2,/^---$/p' "$skill" | sed -n "s/^$1: //p"
}

@test "skill frontmatter: /quill:quill, never model-invoked" {
  [ "$(head -1 "$skill")" = "---" ]
  [ "$(field name)" = "quill" ]
  [ "$(field disable-model-invocation)" = "true" ]
  [ -n "$(field description)" ]
  [ -n "$(field argument-hint)" ]
}

@test "allowed-tools pre-approves quill's scripts and nothing that posts" {
  local tools
  tools="$(field allowed-tools)"
  for s in init queue prepare save-review render-queue; do
    [[ "$tools" == *"Bash(\${CLAUDE_SKILL_DIR}/scripts/$s.sh *)"* ]] || false
  done
  [[ "$tools" != *"post.sh"* ]] || false
  [[ "$tools" != *"gh "* ]] || false
  # every entry is one of quill's scripts
  run sh -c "printf '%s\n' \"\$1\" | tr ' ' '\n' | grep -c '^Bash(' " _ "$tools"
  [ "$output" = "5" ]
}

@test "every script the skill runs exists and is executable" {
  local s
  for s in $(grep -o 'scripts/[a-z-]*\.sh' "$skill" | sort -u); do
    [ -x "$REPO_ROOT/skills/quill/$s" ] || {
      echo "missing: $s"
      false
    }
  done
}

@test "the skill dispatches the plugin's reviewer by its scoped name" {
  local plugin agent
  plugin="$(jq -r .name "$REPO_ROOT/.claude-plugin/plugin.json")"
  agent="$(sed -n 's/^name: //p' "$REPO_ROOT/agents/pr-reviewer.md" | head -1)"
  grep -qF "\`$plugin:$agent\`" "$skill"
}

@test "the skill stays lean and follows the comment style" {
  [ "$(wc -l <"$skill" | tr -d ' ')" -lt 150 ]
  run grep -n $'\xe2\x80\x94' "$skill"
  [ "$status" -eq 1 ]
}
