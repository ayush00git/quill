#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/reviews"
  RUN="$QUILL_HOME/reviews/2026-10-04/.run/t1"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
}

teardown() {
  teardown_tmp
}

requested_fixture() {
  gh_respond 'search prs --review-requested=@me *' <<'JSON'
[
  {"number": 7, "repository": {"name": "foo", "nameWithOwner": "apache/foo"}, "url": "https://github.com/apache/foo/pull/7"},
  {"number": 3, "repository": {"name": "bar", "nameWithOwner": "apache/bar"}, "url": "https://github.com/apache/bar/pull/3"}
]
JSON
}

reviewed_fixture() {
  gh_respond 'search prs --reviewed-by=@me *' <<'JSON'
[
  {"number": 7, "repository": {"name": "foo", "nameWithOwner": "apache/foo"}, "url": "https://github.com/apache/foo/pull/7"},
  {"number": 12, "repository": {"name": "foo", "nameWithOwner": "apache/foo"}, "url": "https://github.com/apache/foo/pull/12"}
]
JSON
}

@test "discovery merges review-requested and reviewed-by, deduped and sorted" {
  requested_fixture
  reviewed_fixture
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  [ "$output" = "queue: 3 open PR(s): 3 to review (0 re-reviews), 0 unchanged since the last draft, 0 waiting on author, 0 skipped" ]
  run jq -c '[.items[] | [.repo, .number, (.sources | join("+"))]]' "$RUN/queue.json"
  [ "$output" = '[["apache/bar",3,"review-requested"],["apache/foo",7,"review-requested+reviewed-by"],["apache/foo",12,"reviewed-by"]]' ]
  run jq -r '.viewer, .version' "$RUN/queue.json"
  [ "$output" = "$(printf 'me\n1')" ]
}

@test "searches ask for every open, non-draft PR, not gh's default 30" {
  requested_fixture
  reviewed_fixture
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  run grep -c -- '--state=open --draft=false --archived=false --limit 1000' "$GH_STUB_LOG"
  [ "$output" = "2" ]
}

@test "an empty queue is fine" {
  gh_respond 'search prs *' <<'JSON'
[]
JSON
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  [ "$output" = "queue: 0 open PR(s): 0 to review (0 re-reviews), 0 unchanged since the last draft, 0 waiting on author, 0 skipped" ]
  run jq -c .items "$RUN/queue.json"
  [ "$output" = "[]" ]
}

@test "--pr reviews exactly that PR and skips discovery" {
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr https://github.com/apache/foo/pull/42/files
  [ "$status" -eq 0 ]
  run jq -c '[.items[] | {repo, number, url, sources}]' "$RUN/queue.json"
  [ "$output" = '[{"repo":"apache/foo","number":42,"url":"https://github.com/apache/foo/pull/42","sources":["explicit"]}]' ]
  run grep -c 'search prs' "$GH_STUB_LOG"
  [ "$output" = "0" ]
}

@test "--pr rejects anything that isn't a GitHub PR reference" {
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr 'apache/foo#1;id'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a PR reference"* ]] || false
  [ ! -f "$RUN/queue.json" ]
}

@test "unauthenticated gh fails with a clear message" {
  : >"$GH_STUB_DIR/routes"
  gh_respond 'api --method GET user *' 4 </dev/null
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh auth login"* ]] || false
}

@test "a failing search fails the run instead of writing a partial queue" {
  gh_respond 'search prs --review-requested=@me *' 1 </dev/null
  reviewed_fixture
  run "$SCRIPTS/queue.sh" --run-dir "$RUN"
  [ "$status" -ne 0 ]
  [ ! -f "$RUN/queue.json" ]
}

@test "usage errors" {
  run "$SCRIPTS/queue.sh"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --bogus
  [ "$status" -eq 64 ]
}
