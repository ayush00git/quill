#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_git_sandbox
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  "$SCRIPTS/init.sh" >/dev/null 2>&1
  export QUILL_GIT_BASE_URL="file://$TEST_TMP/remotes"
  local head
  head="$(make_remote apache/foo)"
  # PRs 2 and 3 share PR 1's commits.
  git -C "$TEST_TMP/remotes/apache/foo.git" update-ref refs/pull/2/head "$head"
  git -C "$TEST_TMP/remotes/apache/foo.git" update-ref refs/pull/3/head "$head"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  # shellcheck source=../skills/quill/scripts/lib/worktree.sh
  source "$SCRIPTS/lib/worktree.sh"
  GD="$(ensure_clone apache/foo)"
  local n
  for n in 1 2 3; do
    fetch_pr apache/foo "$n" main >/dev/null
    add_worktree apache/foo "$n" "$head" >/dev/null
  done
  jq -n '{version: 1, prs: {"apache/foo#1": {}, "apache/foo#2": {}, "apache/foo#3": {}, "apache/foo#4": {}}}' >"$QUILL_HOME/state.json"
  mkdir -p "$QUILL_HOME/worktrees/notaslug" "$QUILL_HOME/reviews/2026-10-01" "$QUILL_HOME/post" "$QUILL_HOME/.agents"
  printf 'old review\n' >"$QUILL_HOME/reviews/2026-10-01/apache__foo__2.md"
  printf '{}\n' >"$QUILL_HOME/post/apache__foo__2.json"
  printf 'x\n' >"$QUILL_HOME/.agents/old"
  touch -t 202001010000 "$QUILL_HOME/.agents/old"
  printf 'x\n' >"$QUILL_HOME/.agents/new"
  export FAKE_STATES="1:OPEN,2:MERGED,3:CLOSED"
  gh_respond_with 'api graphql *' fake-graphql-states
}

teardown() {
  teardown_tmp
}

@test "dry run lists closed and merged PRs and changes nothing" {
  run "$SCRIPTS/clean.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove apache/foo#2 (merged)"* ]] || false
  [[ "$output" == *"would remove apache/foo#3 (closed)"* ]] || false
  [[ "$output" == *"clean: would remove 2 closed or merged PR(s), kept 1 open, 1 unknown"* ]] || false
  [ -d "$QUILL_HOME/worktrees/apache__foo__2" ]
  [ "$(jq '.prs | length' "$QUILL_HOME/state.json")" = "4" ]
}

@test "closed and merged PRs lose their worktree, refs, state entry and unposted payload" {
  run "$SCRIPTS/clean.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean: removed 2 closed or merged PR(s), kept 1 open, 1 unknown"* ]] || false
  [ ! -e "$QUILL_HOME/worktrees/apache__foo__2" ]
  [ ! -e "$QUILL_HOME/worktrees/apache__foo__3" ]
  [ -d "$QUILL_HOME/worktrees/apache__foo__1" ]
  run git --git-dir="$GD" for-each-ref --format='%(refname)' refs/quill/pr/
  [ "$output" = "refs/quill/pr/1/head" ]
  run jq -c '.prs | keys' "$QUILL_HOME/state.json"
  [ "$output" = '["apache/foo#1","apache/foo#4"]' ]
  [ ! -e "$QUILL_HOME/post/apache__foo__2.json" ]
  run git --git-dir="$GD" worktree list --porcelain
  [[ "$output" != *"apache__foo__2"* ]] || false
}

@test "review files stay as a record; odd worktree names and unknown PRs are left alone" {
  run "$SCRIPTS/clean.sh"
  [ "$status" -eq 0 ]
  [ -f "$QUILL_HOME/reviews/2026-10-01/apache__foo__2.md" ]
  [ -d "$QUILL_HOME/worktrees/notaslug" ]
  [[ "$output" == *"leaving $QUILL_HOME/worktrees/notaslug alone"* ]] || false
  [[ "$output" == *"leaving apache/foo#4 alone: GitHub didn't say whether it's open"* ]] || false
}

@test "old reviewer bindings are dropped, recent ones kept" {
  run "$SCRIPTS/clean.sh"
  [ ! -e "$QUILL_HOME/.agents/old" ]
  [ -e "$QUILL_HOME/.agents/new" ]
}

@test "if GitHub can't be reached, nothing is removed, and gh's reason is shown" {
  : >"$GH_STUB_DIR/routes"
  printf '#!/bin/sh\necho "HTTP 401: Bad credentials" >&2\nexit 1\n' >"$GH_STUB_DIR/fail401"
  chmod +x "$GH_STUB_DIR/fail401"
  printf 'api graphql *\tfail401\t1\n' >>"$GH_STUB_DIR/routes"
  run "$SCRIPTS/clean.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't get PR states from GitHub: HTTP 401: Bad credentials"* ]] || false
  [[ "$output" == *"removed 0 closed or merged PR(s), kept 0 open, 4 unknown"* ]] || false
  [ -d "$QUILL_HOME/worktrees/apache__foo__2" ]
  [ "$(jq '.prs | length' "$QUILL_HOME/state.json")" = "4" ]
}

@test "slug parsing: owner has no underscore, repo may; anything else isn't a slug" {
  # shellcheck source=../skills/quill/scripts/clean.sh
  source "$SCRIPTS/clean.sh"
  [ "$(slug_to_key apache__foo__12)" = "apache/foo#12" ]
  [ "$(slug_to_key apache__my__repo__12)" = "apache/my__repo#12" ]
  [ "$(slug_to_key a-b__c.d_e__7)" = "a-b/c.d_e#7" ]
  local bad
  for bad in notaslug apache__foo apache__foo__01 apache__foo__x "__foo__1" "apache____1" "apache__..__1"; do
    [ -z "$(slug_to_key "$bad")" ] || {
      echo "accepted: $bad"
      false
    }
  done
}
