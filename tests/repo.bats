#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_git_sandbox
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  HEAD_SHA="$(make_remote apache/foo)"
  export QUILL_GIT_BASE_URL="file://$TEST_TMP/remotes"
  GD="$QUILL_HOME/repos/apache__foo.git"
}

teardown() {
  teardown_tmp
}

@test "ensure_clone makes a bare, blob-less partial clone in repos/" {
  run ensure_clone apache/foo
  [ "$status" -eq 0 ]
  [ "$output" = "$GD" ]
  run git --git-dir="$GD" rev-parse --is-bare-repository
  [ "$output" = "true" ]
  run git --git-dir="$GD" config remote.origin.partialclonefilter
  [ "$output" = "blob:none" ]
  run git --git-dir="$GD" config remote.origin.promisor
  [ "$output" = "true" ]
}

@test "the clone is hardened: hooks, symlinks, fsmonitor, submodules, attributes" {
  ensure_clone apache/foo >/dev/null
  [ "$(git --git-dir="$GD" config core.symlinks)" = "false" ]
  [ "$(git --git-dir="$GD" config core.hooksPath)" = "/dev/null" ]
  [ "$(git --git-dir="$GD" config core.fsmonitor)" = "false" ]
  [ "$(git --git-dir="$GD" config fetch.recurseSubmodules)" = "false" ]
  [ "$(git --git-dir="$GD" config submodule.recurse)" = "false" ]
  [ "$(cat "$GD/info/attributes")" = '* !diff !filter !export-subst !export-ignore !working-tree-encoding' ]
}

@test "an existing clone is reused without the network, and re-hardened" {
  ensure_clone apache/foo >/dev/null
  git --git-dir="$GD" config core.symlinks true
  rm -rf "$TEST_TMP/remotes"
  run ensure_clone apache/foo
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$GD" config core.symlinks)" = "false" ]
}

@test "a failed clone leaves nothing behind" {
  run ensure_clone apache/missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"cloning apache/missing failed"* ]] || false
  run ls -A "$QUILL_HOME/repos"
  [ -z "$output" ]
}

@test "a non-repo in the clone's place is refused, not overwritten" {
  mkdir -p "$GD"
  printf 'mine\n' >"$GD/notes.txt"
  run ensure_clone apache/foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"isn't a bare git repository"* ]] || false
  [ -f "$GD/notes.txt" ]
}

@test "fetch_pr fetches the base branch and the PR head into refs/quill/" {
  ensure_clone apache/foo >/dev/null
  run fetch_pr apache/foo 1 main
  [ "$status" -eq 0 ]
  [ "$output" = "$HEAD_SHA" ]
  run git --git-dir="$GD" rev-parse refs/quill/pr/1/head refs/quill/base/main
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HEAD_SHA" ]
}

@test "fetch_pr validates its inputs before touching git" {
  ensure_clone apache/foo >/dev/null
  local bad
  for bad in "0" "01" "1a" "" "-1"; do
    run fetch_pr apache/foo "$bad" main
    [ "$status" -ne 0 ]
  done
  for bad in "-x" "a..b" "a b" "main:refs/heads/x" "@{-1}" ""; do
    run fetch_pr apache/foo 1 "$bad"
    [ "$status" -ne 0 ]
  done
  run fetch_pr "apache/../x" 1 main
  [ "$status" -ne 0 ]
}

@test "a missing PR fails clearly" {
  ensure_clone apache/foo >/dev/null
  run fetch_pr apache/foo 99 main
  [ "$status" -ne 0 ]
  [[ "$output" == *"fetching apache/foo#99 failed"* ]] || false
}

@test "qgit won't adopt a bare repo it merely finds (safe.bareRepository=explicit)" {
  ensure_clone apache/foo >/dev/null
  cd "$GD"
  run qgit log -1
  [ "$status" -ne 0 ]
  run qgit --git-dir="$GD" log -1 --format=%s refs/quill/base/main
  [ "$status" -ne 0 ] # base not fetched yet in this test
  fetch_pr apache/foo 1 main >/dev/null
  run qgit --git-dir="$GD" log -1 --format=%s refs/quill/base/main
  [ "$status" -eq 0 ]
  [ "$output" = "base" ]
}
