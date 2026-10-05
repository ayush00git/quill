#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Ball-in-court rules (lib/classify.jq), driven by normalized items.

load helpers/common

setup() {
  LIB="$SCRIPTS/lib"
  CFG='{"skipBots": true, "skipAuthors": ["noisy"]}'
  STATE='{"version": 1, "prs": {}}'
  HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  OLD="1111111111111111111111111111111111111111"
}

# item <jq update applied to a base item>: prints the item JSON.
item() {
  jq -cn --arg head "$HEAD" "{
    repo: \"apache/foo\", number: 7, sources: [\"review-requested\"], state: \"OPEN\", isDraft: false,
    createdAt: \"2026-09-01T00:00:00Z\", updatedAt: \"2026-09-05T00:00:00Z\",
    author: {login: \"alice\", isBot: false, association: \"CONTRIBUTOR\"},
    head: {sha: \$head, repo: \"alice/foo\"}, myReviews: [], timeline: []
  } | $1"
}

# classify <item json> [force]: prints court|reason|reReview|waitingSince|needsReview
classify() {
  jq -L "$LIB" -r --argjson cfg "$CFG" --argjson state "$STATE" --argjson force "${2:-false}" \
    'include "classify"; classify("me"; $cfg; $state; $force)
     | [.court, .courtReason, .reReview, .waitingSince, .needsReview] | map(tostring) | join("|")' <<<"$1"
}

# Build jq updates in a single-quoted variable ($upd) and splice it in. Escaped
# quotes inside a nested "$(...)" are unquoted by bash 3.2 (macOS), and the
# braces in {type: ..., at: ...} then brace-expand into broken jq.
reviewed() { # reviewed <state> <commit> <at>
  printf '.myReviews = [{state: "%s", submittedAt: "%s", commit: "%s"}]' "$1" "$3" "$2"
}

@test "never reviewed: mine, waiting since creation" {
  run classify "$(item '.')"
  [ "$output" = "mine|not reviewed yet|false|2026-09-01T00:00:00Z|true" ]
}

@test "skips: closed, my own, draft, bot, skipAuthors" {
  run classify "$(item '.state = "MERGED"')"
  [ "$output" = "skip|closed or merged|false|null|false" ]
  run classify "$(item '.author.login = "me"')"
  [ "$output" = "skip|my own PR|false|null|false" ]
  run classify "$(item '.isDraft = true')"
  [ "$output" = "skip|draft|false|null|false" ]
  run classify "$(item '.author = {login: "dependabot[bot]", isBot: true}')"
  [ "$output" = "skip|bot author|false|null|false" ]
  run classify "$(item '.author.login = "noisy"')"
  [ "$output" = "skip|author in skipAuthors|false|null|false" ]
}

@test "skipBots: false keeps bot PRs" {
  CFG='{"skipBots": false}'
  run classify "$(item '.author = {login: "dependabot[bot]", isBot: true}')"
  [ "$output" = "mine|not reviewed yet|false|2026-09-01T00:00:00Z|true" ]
}

@test "changes requested and nothing since: waiting on author, not reviewed again" {
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$HEAD" 2026-09-02T00:00:00Z)")"
  [ "$output" = "waiting_on_author|my changes requested review has no reply yet|false|null|false" ]
  run classify "$(item "$(reviewed COMMENTED "$HEAD" 2026-09-02T00:00:00Z)")"
  [ "$output" = "waiting_on_author|my commented review has no reply yet|false|null|false" ]
}

@test "approved and nothing since: skipped" {
  run classify "$(item "$(reviewed APPROVED "$HEAD" 2026-09-02T00:00:00Z)")"
  [ "$output" = "skip|approved, nothing new since|false|null|false" ]
}

@test "author pushed after my review: re-review, waiting since the push" {
  upd=' | .timeline = [
    {type: "commit", sha: "'"$OLD"'", at: "2026-09-01T00:00:00Z"},
    {type: "commit", sha: "'"$HEAD"'", at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$OLD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: author pushed|true|2026-09-03T00:00:00Z|true" ]
}

@test "head moved with no dated event (old commit pushed late): still a re-review" {
  run classify "$(item "$(reviewed COMMENTED "$OLD" 2026-09-02T00:00:00Z)")"
  [ "$output" = "mine|re-review: author pushed|true|2026-09-05T00:00:00Z|true" ]
}

@test "force-push after my review counts as a push" {
  upd=' | .timeline = [
    {type: "force_push", at: "2026-09-04T00:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: author pushed|true|2026-09-04T00:00:00Z|true" ]
}

@test "author replied (comment or review reply) after my review: re-review" {
  upd=' | .timeline = [
    {type: "comment", by: "bob", at: "2026-09-03T00:00:00Z"},
    {type: "comment", by: "alice", at: "2026-09-04T00:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: author replied|true|2026-09-04T00:00:00Z|true" ]
  upd=' | .timeline = [
    {type: "review", by: "alice", state: "COMMENTED", at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed COMMENTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: author replied|true|2026-09-03T00:00:00Z|true" ]
}

@test "someone else commenting doesn't hand the ball back" {
  upd=' | .timeline = [
    {type: "comment", by: "bob", at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "waiting_on_author|my changes requested review has no reply yet|false|null|false" ]
}

@test "activity before my review doesn't count" {
  upd=' | .timeline = [
    {type: "comment", by: "alice", at: "2026-09-01T12:00:00Z"},
    {type: "force_push", at: "2026-09-01T13:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "waiting_on_author|my changes requested review has no reply yet|false|null|false" ]
}

@test "review re-requested from me or a team: re-review" {
  upd=' | .timeline = [
    {type: "review_requested", reviewer: {user: "me"}, at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed APPROVED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: review re-requested|true|2026-09-03T00:00:00Z|true" ]
  upd=' | .timeline = [
    {type: "review_requested", reviewer: {team: "committers"}, at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed COMMENTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: review re-requested|true|2026-09-03T00:00:00Z|true" ]
  upd=' | .timeline = [
    {type: "review_requested", reviewer: {user: "bob"}, at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed COMMENTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "waiting_on_author|my commented review has no reply yet|false|null|false" ]
}

@test "a forward-dated commit with an unchanged head is not a push" {
  # commit dates are author-controlled; only a moved head or a force-push counts
  upd=' | .timeline = [
    {type: "commit", sha: "'"$HEAD"'", at: "2030-01-01T00:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "waiting_on_author|my changes requested review has no reply yet|false|null|false" ]
}

@test "a team re-request counts only while the PR is in my review-requested results" {
  upd=' | .sources = ["repo"] | .timeline = [
    {type: "review_requested", reviewer: {team: "other-team"}, at: "2026-09-03T00:00:00Z"}]'
  run classify "$(item "$(reviewed COMMENTED "$HEAD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "waiting_on_author|my commented review has no reply yet|false|null|false" ]
}

@test "never reviewed: waiting since the latest request for me, if after creation" {
  run classify "$(item '.timeline = [
    {type: "review_requested", reviewer: {user: "bob"}, at: "2026-09-04T00:00:00Z"},
    {type: "review_requested", reviewer: {user: "me"}, at: "2026-09-03T00:00:00Z"}]')"
  [ "$output" = "mine|not reviewed yet|false|2026-09-03T00:00:00Z|true" ]
}

@test "several kinds of activity: all named, waiting since the earliest" {
  upd=' | .timeline = [
    {type: "comment", by: "alice", at: "2026-09-03T00:00:00Z"},
    {type: "commit", sha: "'"$HEAD"'", at: "2026-09-04T00:00:00Z"}]'
  run classify "$(item "$(reviewed CHANGES_REQUESTED "$OLD" 2026-09-02T00:00:00Z)$upd")"
  [ "$output" = "mine|re-review: author pushed, author replied|true|2026-09-03T00:00:00Z|true" ]
}

@test "a dismissed review counts as no review" {
  run classify "$(item "$(reviewed DISMISSED "$HEAD" 2026-09-02T00:00:00Z)")"
  [ "$output" = "mine|not reviewed yet|false|2026-09-01T00:00:00Z|true" ]
}

@test "explicit --pr is always mine unless it's my own: drafts, closed and merged included" {
  run classify "$(item '.sources = ["explicit"] | .isDraft = true')"
  [ "$output" = "mine|requested on the command line|false|2026-09-01T00:00:00Z|true" ]
  upd='.sources = ["explicit"] | '
  run classify "$(item "$upd$(reviewed APPROVED "$HEAD" 2026-09-02T00:00:00Z)")"
  [ "$output" = "mine|requested on the command line|true|2026-09-01T00:00:00Z|true" ]
  run classify "$(item '.sources = ["explicit"] | .state = "CLOSED"')"
  [ "$output" = "mine|requested on the command line (closed)|false|2026-09-01T00:00:00Z|true" ]
  run classify "$(item '.sources = ["explicit"] | .state = "MERGED"')"
  [ "$output" = "mine|requested on the command line (merged)|false|2026-09-01T00:00:00Z|true" ]
  run classify "$(item '.sources = ["explicit"] | .state = "MERGED" | .author.login = "me"')"
  [ "$output" = "skip|my own PR|false|null|false" ]
}

@test "unchanged head since quill's last draft: mine but not reviewed again, unless --force" {
  STATE="$(jq -cn --arg h "$HEAD" '{version: 1, prs: {"apache/foo#7": {reviewedHeadSha: $h}}}')"
  run classify "$(item '.')"
  [ "$output" = "mine|not reviewed yet|false|2026-09-01T00:00:00Z|false" ]
  run classify "$(item '.')" true
  [ "$output" = "mine|not reviewed yet|false|2026-09-01T00:00:00Z|true" ]
  STATE="$(jq -cn --arg h "$OLD" '{version: 1, prs: {"apache/foo#7": {reviewedHeadSha: $h}}}')"
  run classify "$(item '.')"
  [ "$output" = "mine|not reviewed yet|false|2026-09-01T00:00:00Z|true" ]
}

@test "queue.sh applies classification and state, and --force" {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
  jq -n --arg h "$HEAD" '{version: 1, prs: {"apache/foo#1": {reviewedHeadSha: $h}}}' >"$QUILL_HOME/state.json"
  run "$SCRIPTS/queue.sh" --run-dir "$QUILL_HOME/reviews/2026-10-04/.run/t1" --pr apache/foo#1
  [ "$status" -eq 0 ]
  [ "$output" = "queue: 1 PR(s): 0 to review (0 re-reviews), 1 unchanged since the last draft, 0 waiting on author, 0 skipped" ]
  run "$SCRIPTS/queue.sh" --run-dir "$QUILL_HOME/reviews/2026-10-04/.run/t1" --pr apache/foo#1 --force
  [ "$output" = "queue: 1 PR(s): 1 to review (0 re-reviews), 0 unchanged since the last draft, 0 waiting on author, 0 skipped" ]
  teardown_tmp
}
