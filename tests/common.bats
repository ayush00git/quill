#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME"
  unset QUILL_HOME
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
}

teardown() {
  teardown_tmp
}

# --- quill_home ---

@test "quill_home defaults to ~/quill" {
  run quill_home
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/quill" ]
}

@test "quill_home honors QUILL_HOME, expands ~ and drops trailing slashes" {
  QUILL_HOME="/srv/q//" run quill_home
  [ "$output" = "/srv/q" ]
  QUILL_HOME="~/reviews/" run quill_home
  [ "$output" = "$HOME/reviews" ]
}

@test "quill_home rejects a relative QUILL_HOME" {
  QUILL_HOME="quill" run quill_home
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an absolute path"* ]] || false
}

# --- config ---

@test "config_json returns the defaults when config.json is missing" {
  run config_get '.parallel'
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "config_json deep-merges config.json over the defaults" {
  mkdir -p "$HOME/quill"
  printf '%s\n' '{"parallel": 2, "repos": ["apache/foo"], "tests": {"network": "none"}}' >"$HOME/quill/config.json"
  [ "$(config_get '.parallel')" = "2" ]
  [ "$(config_get '.repos | join(",")')" = "apache/foo" ]
  [ "$(config_get '.tests.network')" = "none" ]
  # untouched nested defaults survive the merge
  [ "$(config_get '.tests.timeoutSec')" = "900" ]
  [ "$(config_get '.skipBots')" = "true" ]
}

@test "config_json fails clearly on invalid JSON" {
  mkdir -p "$HOME/quill"
  printf '{"parallel": ' >"$HOME/quill/config.json"
  run config_json
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid JSON object"* ]] || false
}

@test "config_json rejects a non-object config" {
  mkdir -p "$HOME/quill"
  printf '[1, 2]\n' >"$HOME/quill/config.json"
  run config_json
  [ "$status" -ne 0 ]
}

# --- parse_pr_ref / slugs ---

@test "parse_pr_ref accepts owner/repo#N" {
  run parse_pr_ref "apache/arrow#51691"
  [ "$status" -eq 0 ]
  [ "$output" = "apache arrow 51691" ]
}

@test "parse_pr_ref accepts PR URLs, with or without a trailing path" {
  run parse_pr_ref "https://github.com/apache/incubator-xtable/pull/12"
  [ "$output" = "apache incubator-xtable 12" ]
  run parse_pr_ref "https://github.com/a-b/c.d_e/pull/7/files#diff-1"
  [ "$output" = "a-b c.d_e 7" ]
}

@test "parse_pr_ref rejects malformed and hostile input" {
  local bad
  for bad in "apache/arrow" "apache/arrow#0" "apache/arrow#12a" "apache/../x#1" \
    "apache/..#1" "../x/y#1" "apache/arrow #1" "https://evil.example/apache/arrow/pull/1" \
    "http://github.com/apache/arrow/pull/1" "https://github.com/apache/arrow/issues/1" \
    'apache/arrow#1;rm -rf ~' ""; do
    run parse_pr_ref "$bad"
    [ "$status" -ne 0 ] || {
      echo "accepted: $bad"
      return 1
    }
  done
}

@test "pr_slug and repo_slug" {
  [ "$(pr_slug apache arrow 12)" = "apache__arrow__12" ]
  [ "$(repo_slug apache arrow)" = "apache__arrow" ]
}

# --- hashing / time ---

@test "sha256 helpers agree on a known value" {
  printf 'quill' >"$TEST_TMP/f"
  local want
  want="$(printf 'quill' | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1)"
  [ "$(sha256_file "$TEST_TMP/f")" = "$want" ]
  [ "$(printf 'quill' | sha256_stdin)" = "$want" ]
  [ "${#want}" -eq 64 ]
}

@test "now_iso is UTC ISO-8601 and today is YYYY-MM-DD" {
  [[ "$(now_iso)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || false
  [[ "$(today)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || false
}

# --- files ---

@test "write_atomic creates parents and leaves no temp files" {
  printf 'hello\n' | write_atomic "$TEST_TMP/a/b/out.txt"
  [ "$(cat "$TEST_TMP/a/b/out.txt")" = "hello" ]
  [ "$(find "$TEST_TMP/a/b" -name '*.tmp.*' | wc -l | tr -d ' ')" = "0" ]
}

@test "resolve_path follows symlinks; path_within uses the resolved path" {
  mkdir -p "$TEST_TMP/ws/worktrees/pr" "$TEST_TMP/secret"
  printf 'k' >"$TEST_TMP/secret/id_rsa"
  ln -s "$TEST_TMP/secret/id_rsa" "$TEST_TMP/ws/worktrees/pr/link"
  ln -s ../../../secret "$TEST_TMP/ws/worktrees/pr/dirlink"
  local real
  real="$(cd -P "$TEST_TMP/secret" && pwd -P)/id_rsa"
  [ "$(resolve_path "$TEST_TMP/ws/worktrees/pr/link")" = "$real" ]
  path_within "$TEST_TMP/ws/worktrees/pr" "$TEST_TMP/ws"
  ! path_within "$TEST_TMP/ws/worktrees/pr/link" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/worktrees/pr/dirlink/id_rsa" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/../secret/id_rsa" "$TEST_TMP/ws" || false
  # a trailing slash must not skip resolving the last symlink
  ! path_within "$TEST_TMP/ws/worktrees/pr/dirlink/" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/worktrees/pr/dirlink//" "$TEST_TMP/ws" || false
  ! path_within "" "$TEST_TMP/ws" || false
  # a sibling that shares the prefix is not inside
  mkdir -p "$TEST_TMP/ws2"
  ! path_within "$TEST_TMP/ws2" "$TEST_TMP/ws" || false
}

# --- locking ---

@test "lock_acquire is exclusive and times out" {
  lock_acquire "$TEST_TMP/lock" 1
  run lock_acquire "$TEST_TMP/lock" 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out"* ]] || false
  lock_release "$TEST_TMP/lock"
  lock_acquire "$TEST_TMP/lock" 1
  lock_release "$TEST_TMP/lock"
  [ ! -d "$TEST_TMP/lock" ]
}

# --- require_cmd ---

@test "require_cmd names every missing command" {
  run require_cmd git definitely-not-a-cmd-1 definitely-not-a-cmd-2
  [ "$status" -ne 0 ]
  [[ "$output" == *"definitely-not-a-cmd-1 definitely-not-a-cmd-2"* ]] || false
  run require_cmd git jq
  [ "$status" -eq 0 ]
}

@test "resolve_path fallback (no GNU realpath -m, as on macOS) gives the same answers" {
  mkdir -p "$TEST_TMP/bin" "$TEST_TMP/ws/worktrees/pr" "$TEST_TMP/secret"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_TMP/bin/realpath"
  chmod +x "$TEST_TMP/bin/realpath"
  PATH="$TEST_TMP/bin:$PATH"
  printf 'k' >"$TEST_TMP/secret/id_rsa"
  ln -s "$TEST_TMP/secret/id_rsa" "$TEST_TMP/ws/worktrees/pr/link"
  ln -s link "$TEST_TMP/ws/worktrees/pr/link2"
  ln -s ../../../secret "$TEST_TMP/ws/worktrees/pr/dirlink"
  ln -s dirlink/ "$TEST_TMP/ws/worktrees/pr/link3"
  local real
  real="$(cd -P "$TEST_TMP/secret" && pwd -P)/id_rsa"
  [ "$(resolve_path "$TEST_TMP/ws/worktrees/pr/link2")" = "$real" ]
  [ "$(resolve_path "$TEST_TMP/ws/worktrees/pr/../pr/new-file")" = "$(cd -P "$TEST_TMP/ws/worktrees/pr" && pwd -P)/new-file" ]
  path_within "$TEST_TMP/ws/worktrees/pr" "$TEST_TMP/ws"
  ! path_within "$TEST_TMP/ws/worktrees/pr/link2" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/../secret/id_rsa" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/worktrees/pr/dirlink/" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/worktrees/pr/dirlink//" "$TEST_TMP/ws" || false
  ! path_within "$TEST_TMP/ws/worktrees/pr/link3" "$TEST_TMP/ws" || false
  ! path_within "" "$TEST_TMP/ws" || false
  [ "$(resolve_path /)" = "/" ]
}
