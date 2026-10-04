#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/reviews"
  RUN="$QUILL_HOME/reviews/2026-10-04/.run/t1"
  LIB="$SCRIPTS/lib"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
}

teardown() {
  teardown_tmp
}

# normalize <filter> <file>: the normalized PR, then <filter>, compact.
normalize() {
  jq -L "$LIB" -c "include \"normalize\"; normalize | $1" "$2"
}

# --- normalize.jq ---

@test "normalize: author, base/head, size, labels, linked issues" {
  run normalize '{author, base, head, size, labels, linkedIssues, filesTruncated}' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$status" -eq 0 ]
  [ "$output" = '{"author":{"login":"newdev42","isBot":false,"association":"FIRST_TIME_CONTRIBUTOR"},"base":{"ref":"main","sha":"1111111111111111111111111111111111111111"},"head":{"sha":"2222222222222222222222222222222222222222","repo":"newdev42/foo"},"size":{"additions":142,"deletions":18,"files":120},"labels":["io","security"],"linkedIssues":[{"repo":"apache/foo","number":12}],"filesTruncated":true}' ]
}

@test "normalize: workflows awaiting approval are 'not run', never passing or pending" {
  run normalize '.ci' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = '{"state":"not run (awaiting approval)","rollup":"PENDING","checks":3,"awaitingApproval":true}' ]
}

@test "normalize: CI rollup mapping" {
  local rollup want
  for pair in "SUCCESS:passing" "FAILURE:failing" "ERROR:failing" "PENDING:pending" "EXPECTED:pending" "null:not run"; do
    rollup="${pair%%:*}"
    want="${pair#*:}"
    run jq -L "$LIB" -r --arg r "$rollup" 'include "normalize";
      .commits.nodes[0].commit.checkSuites.nodes = []
      | .commits.nodes[0].commit.statusCheckRollup = (if $r == "null" then null else {state: $r, contexts: {totalCount: 1}} end)
      | normalize | .ci.state' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
    [ "$output" = "$want" ] || {
      echo "rollup $rollup: got $output, want $want"
      false
    }
  done
}

@test "normalize: no commits at all is 'not run'" {
  run jq -L "$LIB" -r 'include "normalize"; .commits.nodes = [] | normalize | .ci.state' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = "not run" ]
}

@test "normalize: my submitted reviews sorted, pending kept separate" {
  run normalize '[.myReviews[].state], .myPendingReview' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = "$(printf '%s\n' '["COMMENTED","CHANGES_REQUESTED"]' 'true')" ]
}

@test "normalize: review requests and timeline" {
  run normalize '.reviewRequests' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = '[{"team":"committers"},{"user":"me"}]' ]
  run normalize '[.timeline[] | .type]' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = '["commit","review","force_push","comment","review_requested"]' ]
  run normalize '.timeline[3].by, .timeline[4].reviewer' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = "$(printf '%s\n' '"ghost"' '{"user":"me"}')" ]
}

@test "normalize: bots by type or [bot] suffix" {
  run jq -L "$LIB" -c 'include "normalize";
    [(.author = {__typename: "Bot", login: "dependabot"} | normalize | .author.isBot),
     (.author = {__typename: "User", login: "renovate[bot]"} | normalize | .author.isBot),
     (.author = null | normalize | .author)]' "$REPO_ROOT/tests/fixtures/pr-graphql.json"
  [ "$output" = '[true,true,{"login":"ghost","isBot":false,"association":"FIRST_TIME_CONTRIBUTOR"}]' ]
}

# --- batching and errors ---

@test "enrichment batches PRs and keeps their order" {
  export QUILL_ENRICH_BATCH=2
  gh_respond_with 'api graphql *' fake-graphql-prs
  for n in 5 3 9; do
    run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr "apache/foo#$n"
    [ "$status" -eq 0 ]
  done
  # a 3-item queue through the same code path: build it via config repos
  gh_respond 'search prs *' <<'JSON'
[]
JSON
  gh_respond 'pr list --repo apache/foo *' <<'JSON'
[{"number": 5, "url": "u5", "isDraft": false}, {"number": 3, "url": "u3", "isDraft": false}, {"number": 9, "url": "u9", "isDraft": false}]
JSON
  : >"$GH_STUB_LOG"
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --repo apache/foo
  [ "$status" -eq 0 ]
  run grep -c '^api graphql' "$GH_STUB_LOG"
  [ "$output" = "2" ]
  run jq -c '[.items[] | [.number, .title]]' "$RUN/queue.json"
  [ "$output" = '[[3,"PR 3"],[5,"PR 5"],[9,"PR 9"]]' ]
}

@test "an unreadable PR is skipped with a warning; the rest survive gh's non-zero exit" {
  gh_respond 'api graphql *' 1 <<'JSON'
{"data": {"p0": {"pullRequest": null}}, "errors": [{"message": "Could not resolve to a PullRequest with the number of 99."}]}
JSON
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr apache/foo#99
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping apache/foo#99: not readable on GitHub"* ]] || false
  run jq -c '.items' "$RUN/queue.json"
  [ "$output" = "[]" ]
}

@test "a GraphQL failure with no data fails the run" {
  gh_respond 'api graphql *' 1 <<'JSON'
{"errors": [{"message": "API rate limit exceeded"}]}
JSON
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr apache/foo#1
  [ "$status" -ne 0 ]
  [[ "$output" == *"API rate limit exceeded"* ]] || false
  [ ! -f "$RUN/queue.json" ]
}

@test "a failed gh call with no JSON reports gh's own error" {
  # an executable fixture that fails the way gh does on a 401: stderr only
  printf '#!/bin/sh\necho "HTTP 401: Bad credentials" >&2\nexit 1\n' >"$GH_STUB_DIR/fail401"
  chmod +x "$GH_STUB_DIR/fail401"
  printf 'api graphql *\tfail401\t1\n' >>"$GH_STUB_DIR/routes"
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr apache/foo#1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bad credentials"* ]] || false
  [ ! -f "$RUN/queue.json" ]
}

@test "responses far over the 128 KB argument limit work" {
  gh_respond_with 'api graphql *' fake-graphql-huge
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr apache/foo#1
  [ "$status" -eq 0 ]
  run jq '.items[0].body | length' "$RUN/queue.json"
  [ "$output" = "300000" ]
}

@test "the query refuses invalid repo names or numbers" {
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$LIB/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/enrich.sh
  source "$LIB/enrich.sh"
  run _enrich_query <<<'[{"repo": "apache/foo\") { x } #", "number": 1}]'
  [ "$status" -ne 0 ]
  run _enrich_query <<<'[{"repo": "apache/foo", "number": "1) { x }"}]'
  [ "$status" -ne 0 ]
  run _enrich_query <<<'[{"repo": "apache/foo", "number": 7}]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'p0: repository(owner: "apache", name: "foo") { pullRequest(number: 7) { ...PR } }'* ]] || false
}
