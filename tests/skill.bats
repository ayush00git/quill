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
  for s in init queue prepare save-review render-queue clean; do
    [[ "$tools" == *"Bash(\${CLAUDE_SKILL_DIR}/scripts/$s.sh *)"* ]] || false
  done
  # posting is only ever the dry run; --submit always asks
  [[ "$tools" == *"Bash(\${CLAUDE_SKILL_DIR}/scripts/post.sh --dry-run *)"* ]] || false
  [[ "$tools" != *"--submit"* ]] || false
  [[ "$tools" != *"post.sh *"* ]] || false
  [[ "$tools" != *"gh "* ]] || false
  # every entry is one of quill's scripts
  local entries
  entries="$(grep -o 'Bash([^)]*)' <<<"$tools")"
  [ "$(wc -l <<<"$entries" | tr -d ' ')" = "7" ]
  run grep -v '^Bash(${CLAUDE_SKILL_DIR}/scripts/[a-z-]*\.sh ' <<<"$entries"
  [ "$status" -eq 1 ]
}

@test "the post flow shows the dry run, ends the turn, and submits only that payload" {
  local post
  post="$(sed -n '/^## Post$/,/^## /p' "$skill")"
  [[ "$post" == *'post.sh --dry-run <PR>'* ]] || false
  [[ "$post" == *'**End your turn.**'* ]] || false
  [[ "$post" == *'post.sh --submit <PR> --sha <sha256>'* ]] || false
  # the dry run, then the end of the turn, then the submit
  local dry stop submit
  dry="$(grep -n 'post.sh --dry-run' <<<"$post" | head -1 | cut -d: -f1)"
  stop="$(grep -n 'End your turn' <<<"$post" | head -1 | cut -d: -f1)"
  submit="$(grep -n 'post.sh --submit' <<<"$post" | head -1 | cut -d: -f1)"
  [ "$dry" -lt "$stop" ]
  [ "$stop" -lt "$submit" ]
}

@test "clean is reachable from the arguments" {
  grep -q '^| `clean` or `clean --dry-run` |' "$skill"
  grep -q '^## Clean$' "$skill"
  grep -qF 'scripts/clean.sh' "$skill"
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
