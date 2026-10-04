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
}

teardown() {
  teardown_tmp
}

history_fixture() {
  # history queries start with "query {"; the PR batch query with "query($me"
  gh_respond 'api graphql --method POST -f query=query {*' <<'JSON'
{"data": {
  "h0m": {"issueCount": 0}, "h0c": {"issueCount": 1}, "h0o": {"issueCount": 1},
  "h0r": {"nodes": [{"number": 3, "merged": false, "closedAt": "2026-09-01T00:00:00Z",
                     "reviews": {"totalCount": 2}, "changesRequested": {"totalCount": 1}}]}}}
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
}

@test "items in my court get the author's history in the repo" {
  history_fixture
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr apache/foo#1
  [ "$status" -eq 0 ]
  run jq -c '.items[0].authorHistory' "$RUN/queue.json"
  [ "$output" = '{"merged":0,"closedUnmerged":1,"open":1,"recent":[{"number":3,"merged":false,"closedAt":"2026-09-01T00:00:00Z","reviews":2,"changesRequested":1}]}' ]
  run grep -c 'author:alice' "$GH_STUB_LOG"
  [ "$output" = "4" ]
}

@test "a failed history lookup warns and leaves authorHistory null" {
  gh_respond 'api graphql --method POST -f query=query {*' 1 <<'JSON'
{"errors": [{"message": "rate limited"}]}
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
  run "$SCRIPTS/queue.sh" --run-dir "$RUN" --pr apache/foo#1
  [ "$status" -eq 0 ]
  [[ "$output" == *"couldn't fetch author history"* ]] || false
  run jq -c '.items[0].authorHistory' "$RUN/queue.json"
  [ "$output" = "null" ]
}

@test "the query only splices in validated repos and logins" {
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/history.sh
  source "$SCRIPTS/lib/history.sh"
  run _history_query <<<'[{"repo": "apache/foo", "login": "alice\" is:merged) { x } #"}]'
  [ "$status" -ne 0 ]
  run _history_query <<<'[{"repo": "apache/../x", "login": "alice"}]'
  [ "$status" -ne 0 ]
  run _history_query <<<'[{"repo": "apache/foo", "login": "alice-b"}]'
  [ "$status" -eq 0 ]
  [[ "$output" == *'h0m: search(query: "repo:apache/foo is:pr author:alice-b is:merged", type: ISSUE, first: 0)'* ]] || false
}

@test "skipped PRs and bots get no history lookup" {
  history_fixture
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/history.sh
  source "$SCRIPTS/lib/history.sh"
  mkdir -p "$RUN"
  jq -n '{items: [
    {repo: "apache/foo", number: 1, court: "skip", author: {login: "carol", isBot: false}},
    {repo: "apache/foo", number: 2, court: "mine", author: {login: "dependabot", isBot: true}},
    {repo: "apache/foo", number: 3, court: "waiting_on_author", author: {login: "alice", isBot: false}}]}' >"$RUN/q.json"
  add_author_history "$RUN/q.json"
  run grep -c 'author:carol\|author:dependabot' "$GH_STUB_LOG"
  [ "$output" = "0" ]
  run jq -c '[.items[] | .authorHistory != null]' "$RUN/q.json"
  [ "$output" = '[false,false,true]' ]
}
