#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  LIB="$SCRIPTS/lib"
}

keys() { # keys <item json> [cfg json]
  local c="${2:-}"
  [ -n "$c" ] || c='{}'
  jq -nc -L "$LIB" --argjson i "$1" --argjson c "$c" 'include "group"; $i | issue_keys($c)'
}

group() { # group <items json> [cfg json] -> number:group:members per item
  local c="${2:-}"
  [ -n "$c" ] || c='{}'
  jq -nr -L "$LIB" --argjson i "$1" --argjson c "$c" \
    'include "group"; $i | group_items($c)[] | "\(.number):\(.group // "-"):\(.groupMembers // [] | join(","))"'
}

@test "issue keys: linked issues, closing keywords and issue URLs, not plain mentions" {
  run keys '{"repo": "apache/kafka", "title": "x", "body": "Fixes #12, closes: #13\nresolved #14\nsee #99 and https://github.com/apache/kafka/issues/15", "linkedIssues": [{"repo": "apache/kafka", "number": 7}, {"repo": "other/repo", "number": 8}]}'
  [ "$output" = '["#12","#13","#14","#15","#7"]' ]
}

@test "JIRA keys: the repo's project by default, configurable, and bracketed title keys" {
  run keys '{"repo": "apache/kafka", "title": "KAFKA-1: x", "body": "relates to KAFKA-22, UTF-8, SHA-256, ISO-8601, JIRA-5"}'
  [ "$output" = '["KAFKA-1","KAFKA-22"]' ]
  run keys '{"repo": "apache/incubator-xtable", "title": "XTABLE-3 fix", "body": ""}'
  [ "$output" = '["XTABLE-3"]' ]
  run keys '{"repo": "apache/spark-connect-go", "title": "SPARKCONNECTGO-1", "body": "SPARK-9"}' '{"jiraProjects": {"apache/spark-connect-go": ["SPARK"]}}'
  [ "$output" = '["SPARK-9"]' ]
  run keys '{"repo": "apache/foo", "title": "[OTHER-4] borrowed key", "body": ""}'
  [ "$output" = '["OTHER-4"]' ]
}

@test "PRs sharing a key in the same repo are grouped; others aren't" {
  run group '[
    {"repo": "apache/kafka", "number": 1, "title": "KAFKA-123: approach A", "body": ""},
    {"repo": "apache/kafka", "number": 2, "title": "approach B", "body": "Fixes KAFKA-123"},
    {"repo": "apache/kafka", "number": 3, "title": "unrelated", "body": "see #5"},
    {"repo": "apache/other", "number": 4, "title": "[KAFKA-123] same key, other repo", "body": ""}]'
  [ "$output" = "$(printf '%s\n' '1:KAFKA-123:1,2' '2:KAFKA-123:1,2' '3:-:' '4:-:')" ]
}

@test "a JIRA key is preferred over #N as the group's label" {
  run group '[
    {"repo": "apache/kafka", "number": 1, "title": "KAFKA-7", "body": "Fixes #9"},
    {"repo": "apache/kafka", "number": 2, "title": "KAFKA-7 too", "body": "closes #9"}]'
  [ "$output" = "$(printf '%s\n' '1:KAFKA-7:1,2' '2:KAFKA-7:1,2')" ]
}

@test "queue.sh adds issueKeys to every item" {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/reviews"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
  run "$SCRIPTS/queue.sh" --run-dir "$QUILL_HOME/reviews/2026-10-04/.run/t1" --pr apache/foo#1
  [ "$status" -eq 0 ]
  run jq -c '.items[0] | [.issueKeys, has("group")]' "$QUILL_HOME/reviews/2026-10-04/.run/t1/queue.json"
  [ "$output" = '[[],false]' ]
  teardown_tmp
}
