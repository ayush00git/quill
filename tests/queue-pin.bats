#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# queue.sh --at (lib/pin.sh): a single-PR review pinned to one of the PR's
# commits shows the PR as it was then.

load helpers/common

setup() {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/pin.sh
  source "$SCRIPTS/lib/pin.sh"
  C0="0000000000000000000000000000000000000000"
  C1="1bbcabb50588c22ddb19fa6ee4ce14b5e0506ca8"
  C2="ad484f7000000000000000000000000000000000"
  printf '%s\n' "$C0" "$C1" "$C2" | gh_respond 'api --method GET repos/apache/foo/pulls/1/commits?per_page=100 --paginate --jq .[].sha'
  jq -n --arg o "$C1" '{data: {repository: {object: {oid: $o,
    statusCheckRollup: {state: "FAILURE", contexts: {totalCount: 77}}, checkSuites: {nodes: []}}}}}' |
    gh_respond "api graphql --method POST -f query=* -f owner=apache -f name=foo -f oid=$C1"
  gh_respond "api --method GET repos/apache/foo/compare/main...$C1 --jq *" <<'JSON'
{"files": [{"filename": "src/a.go", "additions": 10, "deletions": 2, "status": "modified"},
           {"filename": "src/b.go", "additions": 5, "deletions": 0, "status": "added"}]}
JSON
  # the queue item as enrich leaves it: the PR's current, merged state
  jq -n --arg c0 "$C0" --arg c1 "$C1" --arg c2 "$C2" '[{repo: "apache/foo", number: 1, state: "MERGED",
    base: {ref: "main", sha: "b"}, head: {sha: $c2, repo: "alice/foo"},
    ci: {state: "passing"}, reviewDecision: "APPROVED", mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN",
    updatedAt: "2026-09-30T08:02:20Z", files: [{path: "x", additions: 1, deletions: 1, changeType: "MODIFIED"}],
    size: {additions: 1, deletions: 1, files: 1},
    myReviews: [{state: "COMMENTED", submittedAt: "2026-09-29T00:00:00Z", commit: $c0},
                {state: "APPROVED", submittedAt: "2026-09-30T07:43:07Z", commit: $c1},
                {state: "APPROVED", submittedAt: "2026-09-30T07:50:00Z", commit: $c2}]}]' >"$TEST_TMP/enriched.json"
}

teardown() {
  teardown_tmp
}

pin() { run pin_to_commit apache/foo 1 "$1" "$TEST_TMP/enriched.json"; }
field() { jq -c ".[0] | $1" "$TEST_TMP/enriched.json"; }

@test "pinning: that commit's head, CI, files and size; the current outcome cleared" {
  pin 1BBCABB
  [ "$status" -eq 0 ]
  [ "$(field '.head.sha')" = "\"$C1\"" ]
  [ "$(field '.reviewAt')" = "\"$C1\"" ]
  [ "$(field '.ci | {state, checks}')" = '{"state":"failing","checks":77}' ]
  [ "$(field '[.files[] | "\(.path):\(.changeType)"]')" = '["src/a.go:MODIFIED","src/b.go:ADDED"]' ]
  [ "$(field '.size')" = '{"additions":15,"deletions":2,"files":2}' ]
  [ "$(field '[.reviewDecision, .mergeable, .mergeStateStatus, .updatedAt]')" = '[null,null,null,null]' ]
  # the real state stays on the item (bundle.sh shows the reviewer OPEN)
  [ "$(field '.state')" = '"MERGED"' ]
}

@test "the SHA must be hex, 7 to 40 digits, and one of the PR's commits" {
  local bad
  for bad in "" "HEAD" "1bbcab" "1bbcabb-" "g000000" "$C1"0; do
    pin "$bad"
    [ "$status" -eq 64 ] || {
      echo "accepted: $bad"
      false
    }
  done
  pin 2222222
  [ "$status" -eq 64 ]
  [[ "$output" == *"2222222 isn't one of apache/foo#1's commits"* ]] || false
  # the item is untouched after a refusal
  [ "$(field '.head.sha')" = "\"$C2\"" ]
}

@test "a prefix that matches two of the PR's commits is refused" {
  printf '%s\n' "$C0" "0000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | gh_respond 'api --method GET repos/apache/foo/pulls/2/commits?per_page=100 --paginate --jq .[].sha'
  run pin_to_commit apache/foo 2 0000000 "$TEST_TMP/enriched.json"
  [ "$status" -eq 64 ]
  [[ "$output" == *"matches 2 of apache/foo#2's commits"* ]] || false
}

@test "queue.sh --at works only with --pr" {
  run "$SCRIPTS/queue.sh" --run-dir "$QUILL_HOME/reviews/2026-10-04/.run/t1" --at "$C1"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--at works only with --pr"* ]] || false
}
