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

# The workspace with symlinks resolved. On macOS $TMPDIR is under /var, a
# symlink to /private/var, so init lists both paths there.
real_home() { (cd -P "$QUILL_HOME" && pwd -P); }

# jq: the excludes init writes for <home> and its resolved path.
EXCLUDES='def excludes($h; $r): (if $h == $r then [$h] else [$h, $r] end)
  | map(. + "/repos/**", . + "/worktrees/**", . + "/reviews/**");'

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
  run jq -e --arg h "$QUILL_HOME" --arg r "$(real_home)" \
    "$EXCLUDES"' .claudeMdExcludes == excludes($h; $r)' "$QUILL_HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
  run jq -e '.permissions.ask == ["Bash(*post.sh*--submit*)"]' "$QUILL_HOME/.claude/settings.json"
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
  [[ "$output" != *"updated"* ]] || false
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
  run jq -e --arg h "$QUILL_HOME" --arg r "$(real_home)" "$EXCLUDES"'
    .env.FOO == "1"
    and .permissions.allow == ["Read"]
    and .permissions.deny == ["WebFetch"]
    and .permissions.ask == ["Bash(git push *)", "Bash(*post.sh*--submit*)"]
    and .claudeMdExcludes == ["/elsewhere/**"] + excludes($h; $r)
  ' "$QUILL_HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "init refuses to touch settings that aren't a JSON object" {
  mkdir -p "$QUILL_HOME/.claude"
  printf '{"permissions": ' >"$QUILL_HOME/.claude/settings.json"
  run "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"won't touch"* ]] || false
  [ "$(cat "$QUILL_HOME/.claude/settings.json")" = '{"permissions": ' ]
}

@test "init rejects a workspace path with glob characters" {
  export QUILL_HOME="$TEST_TMP/ws[1]"
  run "$INIT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"glob characters"* ]] || false
  [ ! -e "$QUILL_HOME" ]
}

@test "init excludes both paths when the workspace is a symlink" {
  mkdir -p "$TEST_TMP/real-ws"
  ln -s "$TEST_TMP/real-ws" "$TEST_TMP/ws"
  run "$INIT"
  [ "$status" -eq 0 ]
  local real
  real="$(cd -P "$TEST_TMP/real-ws" && pwd -P)"
  run jq -e --arg h "$QUILL_HOME" --arg r "$real" '
    .claudeMdExcludes == [$h + "/repos/**", $h + "/worktrees/**", $h + "/reviews/**",
                          $r + "/repos/**", $r + "/worktrees/**", $r + "/reviews/**"]
  ' "$QUILL_HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
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
