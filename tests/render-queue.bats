#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  RUN="$QUILL_HOME/reviews/2026-10-04/.run/r1"
  mkdir -p "$RUN"
  H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # pr <number> <waitingSince> <jq update>: one queue item
  write_fixture
}

teardown() {
  teardown_tmp
}

write_fixture() {
  local prog
  # shellcheck disable=SC2016 # jq program
  prog='def pr($n; $w): {repo: "apache/foo", number: $n, url: "https://github.com/apache/foo/pull/\($n)",
      title: "PR \($n)", court: "mine", reReview: false, waitingSince: $w, labels: [],
      head: {sha: $h}, ci: {state: "passing"}, sizeClass: "medium",
      effectiveSize: {additions: 100, deletions: 20, partial: false},
      author: {login: "dev\($n)", association: "CONTRIBUTOR", isBot: false},
      authorHistory: {merged: 3}};
    {generatedAt: "2026-10-04T12:00:00Z", viewer: "me", items: [
      pr(1; "2026-10-02T12:00:00Z") + {labels: ["security"]},
      pr(2; "2026-10-03T12:00:00Z") + {reReview: true},
      pr(3; "2026-09-29T12:00:00Z") + {sizeClass: "small"},
      pr(4; "2026-09-24T12:00:00Z"),
      pr(5; "2026-09-20T12:00:00Z"),
      pr(6; "2026-09-14T12:00:00Z") + {group: "FOO-9", groupMembers: [6, 7]},
      pr(7; "2026-10-04T11:30:00Z") + {group: "FOO-9", groupMembers: [6, 7],
        title: "a | piped\ntitle", author: {login: "newbie", association: "FIRST_TIME_CONTRIBUTOR"},
        authorHistory: null, effectiveSize: {additions: 5, deletions: 0, partial: true}},
      pr(8; "2026-09-01T12:00:00Z"),
      pr(9; null) + {court: "waiting_on_author",
        lastMyReview: {state: "CHANGES_REQUESTED", submittedAt: "2026-10-02T12:00:00Z"}},
      pr(10; null) + {court: "skip"}
    ]}'
  jq -n --arg h "$H" "$prog" >"$RUN/queue.json"
  # shellcheck disable=SC2016 # jq program
  prog='def d($v; $extra): {reviewedHeadSha: $h, verdict: $v, reason: "reason \($v)", effort: "M",
      fixes: "none", lowEffort: false, previousFindings: "n/a", reviewFile: "reviews/2026-10-04/x.md"} + $extra;
    {version: 1, prs: {
      "apache/foo#1": d("request_changes"; {fixes: "security"}),
      "apache/foo#2": d("approve"; {previousFindings: "addressed"}),
      "apache/foo#3": d("approve"; {effort: "S", reviewFile: "reviews/2026-10-03/apache__foo__3.md"}),
      "apache/foo#5": d("comment"; {lowEffort: true}),
      "apache/foo#6": d("request_changes"; {}),
      "apache/foo#7": d("approve"; {reason: "fine | but\nsplit"}),
      "apache/foo#8": (d("approve"; {}) | .reviewedHeadSha = "stale")
    }}'
  jq -n --arg h "$H" "$prog" >"$QUILL_HOME/state.json"
  printf '%s\n' '[{"pr": "apache/foo#4", "slug": "apache__foo__4", "status": "rejected", "reason": "SUMMARY head mismatch"}]' >"$RUN/results.json"
}

render() {
  run "$SCRIPTS/render-queue.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  Q="$QUILL_HOME/reviews/2026-10-04/QUEUE.md"
}

main_order() { # the PR numbers of the main table, in order
  sed -n '/^| # | PR/,/^$/p' "$Q" | sed -n 's/^| [0-9]* | \[apache\/foo#\([0-9]*\)\].*/\1/p' | tr '\n' ' '
}

@test "render-queue.sh writes reviews/<date>/QUEUE.md and prints its path" {
  render
  [ "$(printf '%s\n' "$output" | tail -1)" = "$QUILL_HOME/reviews/2026-10-04/QUEUE.md" ]
  [ -f "$Q" ]
  [ "$(head -1 "$Q")" = "# Review queue" ]
}

@test "ranking: security, addressed re-review, small CI-green approval, then longest waiting; groups together" {
  render
  # 1 security; 2 re-review with feedback addressed; 3 small approve;
  # then by waiting: 8 (no current draft), 6 with its group member 7, 4; 5 is low effort
  [ "$(main_order)" = "1 2 3 8 6 7 4 " ]
}

@test "low-effort PRs get their own section, not the main table" {
  render
  run sed -n '/^## Likely low-effort/,$p' "$Q"
  [[ "$output" == *"apache/foo#5"* ]] || false
  run sed -n '/^| # | PR/,/^$/p' "$Q"
  [[ "$output" != *"apache/foo#5]"* ]] || false
}

@test "waiting on author lists my last review and how long ago" {
  render
  run sed -n '/^## Waiting on author/,/^## Likely/p' "$Q"
  [[ "$output" == *"[apache/foo#9](https://github.com/apache/foo/pull/9)"*"| changes requested | 2d |"* ]] || false
}

@test "cells: verdicts, reasons, effort, review links, waiting time" {
  render
  run grep -F '[apache/foo#3]' "$Q"
  [[ "$output" == *"| Approve | reason approve | S | [review](../2026-10-03/apache__foo__3.md) |"* ]] || false
  [[ "$output" == *"| passing | 5d |"* ]] || false
  run grep -F '[apache/foo#7]' "$Q"
  [[ "$output" == *"| <1h |"* ]] || false
}

@test "a draft for an older head or a rejected review shows as not reviewed" {
  render
  run grep -F '[apache/foo#8]' "$Q"
  [[ "$output" == *"| not reviewed |"* ]] || false
  run grep -F '[apache/foo#4]' "$Q"
  [[ "$output" == *"| not reviewed | rejected: SUMMARY head mismatch |"* ]] || false
}

@test "author and size cells: first-time contributors, merged counts, partial file lists" {
  render
  run grep -F '[apache/foo#7]' "$Q"
  [[ "$output" == *"@newbie (FIRST_TIME_CONTRIBUTOR, first-time)"* ]] || false
  [[ "$output" == *"| +5/-0* |"* ]] || false
  run grep -F '[apache/foo#1]' "$Q"
  [[ "$output" == *"@dev1 (CONTRIBUTOR, 3 merged)"* ]] || false
}

@test "PR text can't break the table: pipes are escaped, line breaks flattened" {
  render
  run grep -F '[apache/foo#7]' "$Q"
  [[ "$output" == *'a \| piped title (FOO-9)'* ]] || false
  [[ "$output" == *'fine \| but split'* ]] || false
  # every table row has the same number of unescaped pipes
  run sh -c "sed -n '/^| # | PR/,/^\$/p' '$Q' | sed 's/\\\\|//g' | awk -F'|' 'NF > 0 {print NF}' | sort -u"
  [ "$output" = "12" ]
}

@test "the summary line counts every court; no em dashes anywhere" {
  render
  grep -q '7 PR(s) in your court, 1 likely low-effort, 1 waiting on the author, 1 skipped' "$Q"
  run grep -c $'\xe2\x80\x94' "$Q"
  [ "$output" = "0" ]
}

@test "works without state or results, and refuses run dirs outside the workspace" {
  rm -f "$QUILL_HOME/state.json" "$RUN/results.json"
  render
  [ "$(main_order)" = "1 8 6 7 5 4 3 2 " ]
  run "$SCRIPTS/render-queue.sh" --run-dir "$TEST_TMP/elsewhere"
  [ "$status" -ne 0 ]
}

@test "PR text can't add live links, images or HTML to QUEUE.md" {
  # shellcheck disable=SC2016 # literal markdown, not expansions
  run jq -rn -L "$SCRIPTS/lib" 'include "render";
    "Fix ![x](https://evil.example/p.png) <img src=x> [click](http://e) `c`" | cell(200)'
  [ "$status" -eq 0 ]
  [ "$output" = 'Fix !\[x\](https://evil.example/p.png) &lt;img src=x&gt; \[click\](http://e) \`c\`' ]
}
