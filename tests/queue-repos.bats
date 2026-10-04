#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME"
  RUN="$TEST_TMP/run"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
  gh_respond 'search prs --review-requested=@me *' <<'JSON'
[{"number": 7, "repository": {"nameWithOwner": "apache/foo"}, "url": "https://github.com/apache/foo/pull/7"}]
JSON
  gh_respond 'search prs --reviewed-by=@me *' <<'JSON'
[]
JSON
  gh_respond 'pr list --repo apache/foo *' <<'JSON'
[
  {"number": 7, "url": "https://github.com/apache/foo/pull/7", "isDraft": false},
  {"number": 8, "url": "https://github.com/apache/foo/pull/8", "isDraft": true},
  {"number": 9, "url": "https://github.com/apache/foo/pull/9", "isDraft": false}
]
JSON
  gh_respond 'pr list --repo apache/bar *' <<'JSON'
[{"number": 1, "url": "https://github.com/apache/bar/pull/1", "isDraft": false}]
JSON
}

teardown() {
  teardown_tmp
}

@test "--repo adds every open non-draft PR in that repo" {
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --repo apache/foo
  [ "$status" -eq 0 ]
  [ "$output" = "queue: 2 open PR(s): 2 to review (0 re-reviews), 0 unchanged since the last draft, 0 waiting on author, 0 skipped" ]
  run jq -c '[.items[] | [.number, (.sources | join("+"))]]' "$RUN/queue.json"
  [ "$output" = '[[7,"repo+review-requested"],[9,"repo"]]' ]
  run grep -c -- 'pr list --repo apache/foo --state open --limit 1000' "$GH_STUB_LOG"
  [ "$output" = "1" ]
}

@test "repos come from --repo and config.json, each listed once" {
  printf '{"repos": ["apache/bar", "apache/foo"]}\n' >"$QUILL_HOME/config.json"
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --repo apache/foo
  [ "$status" -eq 0 ]
  run jq -c '[.items[] | "\(.repo)#\(.number)"]' "$RUN/queue.json"
  [ "$output" = '["apache/bar#1","apache/foo#7","apache/foo#9"]' ]
  run grep -c -- 'pr list --repo apache/foo' "$GH_STUB_LOG"
  [ "$output" = "1" ]
}

@test "invalid repo names are rejected before any listing" {
  local bad
  for bad in "apache" "apache/foo/bar" "apache/.." "-x/y" 'a/b;id' "a b/c"; do
    run "$SCRIPTS/queue.sh" --run-dir "$RUN" --repo "$bad"
    [ "$status" -ne 0 ]
  done
  run grep -c 'pr list' "$GH_STUB_LOG"
  [ "$output" = "0" ]
}

@test "invalid repos in config.json fail the run" {
  printf '{"repos": ["apache/foo", "not a repo"]}\n' >"$QUILL_HOME/config.json"
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -ne 0 ]
  printf '{"repos": "apache/foo"}\n' >"$QUILL_HOME/config.json"
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -ne 0 ]
  [ ! -f "$RUN/queue.json" ]
}

@test "a failed repo listing fails the run" {
  : >"$GH_STUB_DIR/routes"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond 'search prs *' <<'JSON'
[]
JSON
  gh_respond 'pr list *' 1 </dev/null
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --repo apache/foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"listing open PRs in apache/foo failed"* ]] || false
  [ ! -f "$RUN/queue.json" ]
}
