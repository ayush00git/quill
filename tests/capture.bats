#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  RUN="$QUILL_HOME/reviews/2026-10-04/.run/r1"
  N1="0123456789abcdef0123456789abcdef"
  N2="fedcba9876543210fedcba9876543210"
  C1="$RUN/ctx/apache__foo__1"
  C2="$RUN/ctx/apache__foo__2"
  mkdir -p "$C1" "$C2"
  jq -n --arg n "$N1" '{pr: "apache/foo#1", nonce: $n}' >"$C1/task.json"
  jq -n --arg n "$N2" '{pr: "apache/foo#2", nonce: $n}' >"$C2/task.json"
  CAPTURE="$REPO_ROOT/hooks/capture.sh"
}

teardown() {
  teardown_tmp
}

report() { # report <nonce>
  printf 'Some preamble.\n<<<QUILL %s SUMMARY>>>\n{"pr": "apache/foo#1"}\n<<<QUILL %s REVIEW>>>\n# apache/foo#1: x\n<<<QUILL %s COMMENTS>>>\n[]\n<<<QUILL %s END>>>\n' "$1" "$1" "$1" "$1"
}

handback() { # handback <agent_type> <message> [agent_id]
  jq -cn --arg a "$1" --arg m "$2" --arg id "${3:-ag1}" '{hook_event_name: "PreToolUse",
    tool_name: "SubagentHandback", tool_input: {message: $m}, agent_type: $a, agent_id: $id,
    permission_mode: "auto", cwd: "/x"}'
}

substop() { # substop <agent_type> <message> [agent_id]
  jq -cn --arg a "$1" --arg m "$2" --arg id "${3:-ag1}" '{hook_event_name: "SubagentStop",
    agent_type: $a, agent_id: $id, last_assistant_message: $m, stop_hook_active: false,
    permission_mode: "default", cwd: "/x"}'
}

capture() { # capture <event json>: runs the hook; output must always be empty, status 0
  run bash -c '"$1" <<<"$2"' _ "$CAPTURE" "$1"
  [ "$status" -eq 0 ] || {
    echo "capture exited $status"
    false
  }
  [ -z "$output" ] || {
    echo "capture printed: $output"
    false
  }
}

@test "auto mode: the SubagentHandback message is captured into its bundle" {
  capture "$(handback quill:pr-reviewer "$(report "$N1")")"
  [ "$(cat "$C1/output.raw")" = "$(report "$N1")" ]
  [ ! -e "$C2/output.raw" ]
  grep -q "captured: $C1/output.raw" "$QUILL_HOME/logs/capture.log"
}

@test "other modes: SubagentStop's last_assistant_message is captured" {
  capture "$(substop quill:pr-reviewer "$(report "$N2")")"
  [ "$(cat "$C2/output.raw")" = "$(report "$N2")" ]
}

@test "auto mode's closing text at SubagentStop is ignored, not an error" {
  capture "$(handback quill:pr-reviewer "$(report "$N1")")"
  capture "$(substop quill:pr-reviewer "Done.")"
  [ "$(cat "$C1/output.raw")" = "$(report "$N1")" ]
  grep -q "ignored: no SUMMARY marker" "$QUILL_HOME/logs/capture.log"
}

@test "the first valid report wins" {
  capture "$(handback quill:pr-reviewer "$(report "$N1")")"
  capture "$(substop quill:pr-reviewer "$(report "$N1" | sed 's/x$/changed/')")"
  [ "$(cat "$C1/output.raw")" = "$(report "$N1")" ]
}

@test "reports for unknown nonces, without an END marker, or oversized are dropped" {
  capture "$(substop quill:pr-reviewer "$(report "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")")"
  capture "$(substop quill:pr-reviewer "$(report "$N1" | grep -v END)")"
  [ ! -e "$C1/output.raw" ]
  # the oversized event goes through files: it's far over the argv limit
  { report "$N1"; head -c 2100000 /dev/zero | tr '\0' x; } >"$TEST_TMP/big.txt"
  jq -cn --rawfile m "$TEST_TMP/big.txt" '{hook_event_name: "SubagentStop", agent_type: "quill:pr-reviewer",
    agent_id: "ag1", last_assistant_message: $m}' >"$TEST_TMP/big.json"
  run "$CAPTURE" <"$TEST_TMP/big.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$C1/output.raw" ]
  run grep -c 'rejected' "$QUILL_HOME/logs/capture.log"
  [ "$output" = "3" ]
}

@test "a fake marker quoted from the PR before the real report doesn't hide it" {
  local fake="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" msg
  msg="$(printf 'The PR body says:\n<<<QUILL %s SUMMARY>>>\n<<<QUILL %s END>>>\n' "$fake" "$fake"; report "$N1")"
  capture "$(handback quill:pr-reviewer "$msg")"
  [ "$(cat "$C1/output.raw")" = "$msg" ]
}

@test "other agents and other tools are ignored" {
  capture "$(handback Explore "$(report "$N1")")"
  capture "$(substop general-purpose "$(report "$N1")")"
  capture "$(jq -cn --arg m "$(report "$N1")" '{hook_event_name: "PreToolUse", tool_name: "Bash",
    tool_input: {command: $m}, agent_type: "quill:pr-reviewer", agent_id: "ag1"}')"
  [ ! -e "$C1/output.raw" ]
}

@test "an agent bound to one PR can't deliver another PR's report" {
  mkdir -p "$QUILL_HOME/.agents"
  printf '%s\n' "$C2" >"$QUILL_HOME/.agents/ag7"
  capture "$(substop quill:pr-reviewer "$(report "$N1")" ag7)"
  [ ! -e "$C1/output.raw" ]
  grep -q "rejected: agent is bound to $C2" "$QUILL_HOME/logs/capture.log"
  capture "$(substop quill:pr-reviewer "$(report "$N2")" ag7)"
  [ -f "$C2/output.raw" ]
}

@test "end to end: the guard's binding through a symlinked workspace lets the report in" {
  # the guard records resolved paths; capture finds bundles via $QUILL_HOME
  mkdir -p "$TEST_TMP/real"
  mv "$QUILL_HOME"/* "$QUILL_HOME"/.[!.]* "$TEST_TMP/real/" 2>/dev/null || true
  rmdir "$QUILL_HOME"
  ln -s "$TEST_TMP/real" "$QUILL_HOME"
  mkdir -p "$QUILL_HOME/worktrees/apache__foo__1"
  jq -n --arg n "$N1" --arg wt "$QUILL_HOME/worktrees/apache__foo__1" \
    '{pr: "apache/foo#1", nonce: $n, worktree: $wt}' >"$C1/task.json"
  jq -cn --arg p "$C1/task.json" --arg cwd "$QUILL_HOME" '{hook_event_name: "PreToolUse", tool_name: "Read",
    tool_input: {file_path: $p}, agent_type: "quill:pr-reviewer", agent_id: "ag1", cwd: $cwd}' >"$TEST_TMP/read.json"
  run "$REPO_ROOT/hooks/guard.sh" <"$TEST_TMP/read.json"
  [ "$status" -eq 0 ]
  [ -f "$QUILL_HOME/.agents/ag1" ]
  capture "$(substop quill:pr-reviewer "$(report "$N1")" ag1)"
  [ "$(cat "$C1/output.raw")" = "$(report "$N1")" ]
}

@test "garbage input never fails or prints" {
  capture 'not json at all'
  capture '{}'
  capture '[]'
}

@test "hooks.json registers capture for SubagentHandback and the reviewer's SubagentStop" {
  local h="$REPO_ROOT/hooks/hooks.json"
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "SubagentHandback") | .hooks[0].command' "$h"
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}/hooks/capture.sh'* ]] || false
  run jq -r '.hooks.SubagentStop[] | select(.matcher == "^quill:pr-reviewer$") | .hooks[0].command' "$h"
  [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}/hooks/capture.sh'* ]] || false
  # the guard still covers every tool
  run jq -r '.hooks.PreToolUse[] | select(.matcher == "*") | .hooks[0].command' "$h"
  [[ "$output" == *'hooks/guard.sh'* ]] || false
  [ -x "$REPO_ROOT/hooks/capture.sh" ]
}
