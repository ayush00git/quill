#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  export QUILL_HOME="$TEST_TMP/ws"
  INIT="$SCRIPTS/init.sh"
}

teardown() {
  teardown_tmp
}

settings() { cat "$QUILL_HOME/.claude/settings.json"; }

@test "init creates the workspace layout and prints its path" {
  run "$INIT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "$QUILL_HOME" ]
  for d in notes references repos worktrees logs reviews; do
    [ -d "$QUILL_HOME/$d" ]
  done
  run jq -e '.repos == []' "$QUILL_HOME/config.json"
  [ "$status" -eq 0 ]
  run jq -e '.version == 1 and .prs == {}' "$QUILL_HOME/state.json"
  [ "$status" -eq 0 ]
}

@test "init writes claudeMdExcludes and the post ask rule" {
  run "$INIT"
  [ "$status" -eq 0 ]
  run jq -e --arg h "$QUILL_HOME" \
    '.claudeMdExcludes == [$h + "/repos/**", $h + "/worktrees/**", $h + "/reviews/**"]' \
    "$QUILL_HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
  run jq -e '.permissions.ask == ["Bash(*post.sh --submit*)"]' "$QUILL_HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "init is idempotent: a second run changes nothing" {
  run "$INIT"
  [ "$status" -eq 0 ]
  local before
  before="$(settings)"
  printf '{"repos": ["apache/foo"]}\n' >"$QUILL_HOME/config.json"
  run "$INIT"
  [ "$status" -eq 0 ]
  [ "$(settings)" = "$before" ]
  [[ "$output" != *"updated"* ]]
  # existing config and state are never overwritten
  run jq -e '.repos == ["apache/foo"]' "$QUILL_HOME/config.json"
  [ "$status" -eq 0 ]
}

@test "init merges into existing settings without dropping your keys" {
  mkdir -p "$QUILL_HOME/.claude"
  cat >"$QUILL_HOME/.claude/settings.json" <<'JSON'
{
  "env": {"FOO": "1"},
  "claudeMdExcludes": ["/elsewhere/**"],
  "permissions": {"allow": ["Read"], "ask": ["Bash(git push *)"], "deny": ["WebFetch"]}
}
JSON
  run "$INIT"
  [ "$status" -eq 0 ]
  run jq -e --arg h "$QUILL_HOME" '
    .env.FOO == "1"
    and .permissions.allow == ["Read"]
    and .permissions.deny == ["WebFetch"]
    and .permissions.ask == ["Bash(git push *)", "Bash(*post.sh --submit*)"]
    and .claudeMdExcludes == ["/elsewhere/**", $h + "/repos/**", $h + "/worktrees/**", $h + "/reviews/**"]
  ' "$QUILL_HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "init refuses to touch settings that aren't a JSON object" {
  mkdir -p "$QUILL_HOME/.claude"
  printf '{"permissions": ' >"$QUILL_HOME/.claude/settings.json"
  run "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"won't touch"* ]]
  [ "$(cat "$QUILL_HOME/.claude/settings.json")" = '{"permissions": ' ]
}

@test "init rejects a workspace path with glob characters" {
  export QUILL_HOME="$TEST_TMP/ws[1]"
  run "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"glob characters"* ]]
}

@test "init never creates instruction files Claude Code would auto-load" {
  run "$INIT"
  [ "$status" -eq 0 ]
  run find "$QUILL_HOME" \( -iname CLAUDE.md -o -iname CLAUDE.local.md -o -iname AGENTS.md \) -print
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # the only .claude directory is the workspace's own, holding only settings.json
  run find "$QUILL_HOME" -type d -name .claude -print
  [ "$output" = "$QUILL_HOME/.claude" ]
  run ls -A "$QUILL_HOME/.claude"
  [ "$output" = "settings.json" ]
}
