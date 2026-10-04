#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_git_sandbox
  export QUILL_HOME="$TEST_TMP/ws"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  # shellcheck source=../skills/quill/scripts/lib/diffmap.sh
  source "$SCRIPTS/lib/diffmap.sh"
  R="$TEST_TMP/repo"
  git init -q "$R"
  seq 1 20 | sed 's/^/line/' >"$R/a.txt"
  seq 1 10 | sed 's/^/keep/' >"$R/old_name.txt"
  printf 'x\ny\nz\n' >"$R/gone.txt"
  printf 'one\ntwo\nthree\n' >"$R/sp ace.txt"
  printf 'eins\nzwei\n' >"$R/ünï.txt"
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  BASE="$(git -C "$R" rev-parse HEAD)"
  sed -i.bak 's/^line10$/LINE TEN/' "$R/a.txt" && rm "$R/a.txt.bak"
  printf 'line21\n' >>"$R/a.txt"
  printf 'new1\nnew2\n' >"$R/new.txt"
  git -C "$R" rm -q gone.txt
  git -C "$R" mv old_name.txt new_name.txt
  sed -i.bak 's/^keep5$/changed5/' "$R/new_name.txt" && rm "$R/new_name.txt.bak"
  printf 'one\nTWO\nthree\n' >"$R/sp ace.txt"
  printf 'eins\nZWEI\n' >"$R/ünï.txt"
  git -C "$R" add -A
  git -C "$R" commit -q -m head
  HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
  GD="$R/.git"
}

teardown() {
  teardown_tmp
}

map() {
  diff_map "$GD" "$BASE" "$HEAD_SHA"
}

@test "hunk ranges per file and side, context included" {
  run map
  [ "$status" -eq 0 ]
  local m="$output"
  [ "$(jq -c '."a.txt"' <<<"$m")" = '{"LEFT":[[7,13],[18,20]],"RIGHT":[[7,13],[18,21]]}' ]
  [ "$(jq -c '."new.txt"' <<<"$m")" = '{"RIGHT":[[1,2]]}' ]
  [ "$(jq -c '."gone.txt"' <<<"$m")" = '{"LEFT":[[1,3]]}' ]
}

@test "the user's git config can't change the map (it must match GitHub's diff)" {
  local before
  before="$(map | jq -cS .)"
  git config --global diff.interHunkContext 20
  git config --global diff.noprefix true
  git config --global diff.algorithm patience
  git config --global diff.indentHeuristic false
  [ "$(map | jq -cS .)" = "$before" ]
}

@test "renames use the new path and only the changed hunk, like GitHub" {
  run map
  [ "$(jq -c '."new_name.txt"' <<<"$output")" = '{"LEFT":[[2,8]],"RIGHT":[[2,8]]}' ]
  [ "$(jq -c 'has("old_name.txt")' <<<"$output")" = "false" ]
}

@test "paths with spaces and non-ASCII characters come through as is" {
  run map
  [ "$(jq -c '."sp ace.txt".RIGHT' <<<"$output")" = '[[1,3]]' ]
  [ "$(jq -c '."ünï.txt".RIGHT' <<<"$output")" = '[[1,2]]' ]
}

@test "comment_in_diff: inside, outside, wrong side, wrong path" {
  local m
  m="$(map)"
  check() { jq -L "$SCRIPTS/lib" -r --argjson m "$m" 'include "diffmap"; comment_in_diff($m)' <<<"$1"; }
  [ "$(check '{"path": "a.txt", "line": 10, "side": "RIGHT"}')" = true ]
  [ "$(check '{"path": "a.txt", "line": 21, "side": "RIGHT"}')" = true ]
  [ "$(check '{"path": "a.txt", "line": 21, "side": "LEFT"}')" = false ]
  [ "$(check '{"path": "a.txt", "line": 15, "side": "RIGHT"}')" = false ]
  [ "$(check '{"path": "a.txt", "line": 0, "side": "RIGHT"}')" = false ]
  [ "$(check '{"path": "a.txt", "line": "10", "side": "RIGHT"}')" = false ]
  [ "$(check '{"path": "gone.txt", "line": 2, "side": "LEFT"}')" = true ]
  [ "$(check '{"path": "README.md", "line": 1, "side": "RIGHT"}')" = false ]
  [ "$(check '{"path": "a.txt", "line": 10}')" = true ] # side defaults to RIGHT
}

@test "comment_in_diff: a multi-line comment must stay in one hunk on one side" {
  local m
  m="$(map)"
  check() { jq -L "$SCRIPTS/lib" -r --argjson m "$m" 'include "diffmap"; comment_in_diff($m)' <<<"$1"; }
  [ "$(check '{"path": "a.txt", "start_line": 8, "line": 12, "side": "RIGHT"}')" = true ]
  [ "$(check '{"path": "a.txt", "start_line": 8, "line": 19, "side": "RIGHT"}')" = false ]
  [ "$(check '{"path": "a.txt", "start_line": 12, "line": 8, "side": "RIGHT"}')" = false ]
  [ "$(check '{"path": "a.txt", "start_line": 8, "start_side": "LEFT", "line": 12, "side": "RIGHT"}')" = false ]
}

@test "a diff that can't be computed fails instead of returning an empty map" {
  run diff_map "$GD" "$BASE" "0123456789abcdef0123456789abcdef01234567"
  [ "$status" -ne 0 ]
  run diff_map "$TEST_TMP/nope.git" "$BASE" "$HEAD_SHA"
  [ "$status" -ne 0 ]
}

@test "identical trees give an empty map" {
  run diff_map "$GD" "$BASE" "$BASE"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}
