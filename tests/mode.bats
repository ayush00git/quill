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
  # shellcheck source=../skills/quill/scripts/lib/mode.sh
  source "$SCRIPTS/lib/mode.sh"
  export QUILL_GIT_BASE_URL="file://$TEST_TMP/remotes"
  SRC="$TEST_TMP/src"
  REMOTE="$TEST_TMP/remotes/apache/foo.git"
  mkdir -p "$SRC" "$(dirname "$REMOTE")"
  git init -q "$SRC"
  printf 'one\n' >"$SRC/f.txt"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m M1
  M1="$(git -C "$SRC" rev-parse HEAD)"
  git -C "$SRC" checkout -q -b pr
  printf 'one\ntwo\n' >"$SRC/f.txt"
  git -C "$SRC" commit -q -am A
  A="$(git -C "$SRC" rev-parse HEAD)"
  git init -q --bare "$REMOTE"
  git -C "$REMOTE" config uploadpack.allowFilter true
  git -C "$REMOTE" config uploadpack.allowAnySHA1InWant true
  publish
  ensure_clone apache/foo >/dev/null
  fetch_pr apache/foo 1 main >/dev/null
}

teardown() {
  teardown_tmp
}

# publish: push main and the PR branch (as refs/pull/1/head), forcing.
publish() {
  git -C "$SRC" push -q -f "$REMOTE" main "pr:refs/pull/1/head"
}

refetch() {
  publish
  fetch_pr apache/foo 1 main
}

mode_of() { # mode_of <head> [last] -> "mode|diff|rangeDiff|lastReviewed"
  review_mode apache/foo 1 main "$@" |
    jq -r '[.mode, (.diff // [] | join("..")), (.rangeDiff // [] | join(" ")), (.lastReviewed // "-")] | join("|")'
}

@test "first review: full diff from the merge base" {
  run mode_of "$A"
  [ "$status" -eq 0 ]
  [ "$output" = "full|$M1..$A||-" ]
}

@test "new commits on top: incremental from the last reviewed head" {
  mark_reviewed apache/foo 1 "$A"
  printf 'one\ntwo\nthree\n' >"$SRC/f.txt"
  git -C "$SRC" commit -q -am B
  local b
  b="$(refetch)"
  run mode_of "$b" "$(last_reviewed apache/foo 1)"
  [ "$output" = "incremental|$A..$b||$A" ]
}

@test "force-push: range-diff, and the old head survives gc" {
  mark_reviewed apache/foo 1 "$A"
  printf 'one\nTWO\n' >"$SRC/f.txt"
  git -C "$SRC" commit -q --amend -am "A rewritten"
  local a2
  a2="$(refetch)"
  git --git-dir="$QUILL_HOME/repos/apache__foo.git" gc -q --prune=now
  run mode_of "$a2" "$A"
  [ "$output" = "range-diff||$M1..$A $M1..$a2|$A" ]
  run review_mode apache/foo 1 main "$a2" "$A"
  [[ "$output" == *'"reason": "force-pushed since the last review"'* ]] || false
}

@test "base merged into the PR: range-diff against the new merge base" {
  mark_reviewed apache/foo 1 "$A"
  git -C "$SRC" checkout -q main
  printf 'zero\n' >"$SRC/g.txt"
  git -C "$SRC" add g.txt
  git -C "$SRC" commit -q -m M2
  local m2 merged
  m2="$(git -C "$SRC" rev-parse HEAD)"
  git -C "$SRC" checkout -q pr
  git -C "$SRC" merge -q --no-edit main
  merged="$(refetch)"
  run mode_of "$merged" "$A"
  [ "$output" = "range-diff||$M1..$A $m2..$merged|$A" ]
}

@test "a previously reviewed head that no longer exists falls back to a full review" {
  run mode_of "$A" "0123456789abcdef0123456789abcdef01234567"
  [ "$output" = "full|$M1..$A||-" ]
  run review_mode apache/foo 1 main "$A" "0123456789abcdef0123456789abcdef01234567"
  [[ "$output" == *"no longer available"* ]] || false
}

@test "same head as last time (forced rerun): full review" {
  run mode_of "$A" "$A"
  [ "$output" = "full|$M1..$A||$A" ]
}

@test "mark_reviewed and last_reviewed round-trip" {
  run last_reviewed apache/foo 1
  [ -z "$output" ]
  mark_reviewed apache/foo 1 "$A"
  run last_reviewed apache/foo 1
  [ "$output" = "$A" ]
}

@test "inputs are validated" {
  run review_mode apache/foo 1 main HEAD
  [ "$status" -ne 0 ]
  run review_mode apache/foo 1 main "$A" "HEAD~1"
  [ "$status" -ne 0 ]
  run review_mode apache/foo 1 "a..b" "$A"
  [ "$status" -ne 0 ]
  run mark_reviewed apache/foo 01 "$A"
  [ "$status" -ne 0 ]
  run mark_reviewed apache/foo 1 "refs/heads/main"
  [ "$status" -ne 0 ]
  # uppercase hex without F: a [0-9a-f] range accepts it under bash 3.2's
  # locale collation (a A b B ... f), so the check must list the characters
  run mark_reviewed apache/foo 1 "ABCDE0123456789ABCDE0123456789ABCDE01234"
  [ "$status" -ne 0 ]
}
