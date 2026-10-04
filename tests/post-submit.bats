#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# post.sh --submit: the one GitHub write quill makes, and every reason it
# refuses to make it.

load helpers/common

setup() {
  setup_tmp
  use_git_sandbox
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  "$SCRIPTS/init.sh" >/dev/null 2>&1
  unset QUILL_HEADLESS CLAUDE_PROJECT_DIR
  HEAD_SHA="$(make_remote apache/foo)"
  D="$QUILL_HOME/reviews/2026-10-04"
  mkdir -p "$D"
  jq -n --arg h "$HEAD_SHA" '{version: 1, prs: {"apache/foo#1": {reviewedHeadSha: $h,
    commentsFile: "reviews/2026-10-04/apache__foo__1.comments.json", verdict: "request_changes"}}}' >"$QUILL_HOME/state.json"
  printf '%s\n' '[{"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "issue (blocking): F has no test."}]' \
    >"$D/apache__foo__1.comments.json"
  routes "$HEAD_SHA" '[[]]'
  cd "$QUILL_HOME"
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 0 ]
  SHA="$(printf '%s\n' "$output" | sed -n 's/^sha256: //p')"
  [ -n "$SHA" ]
  : >"$GH_STUB_LOG"
}

teardown() {
  teardown_tmp
}

# routes <head sha> <reviews pages json> [post exit] [post state]
routes() {
  : >"$GH_STUB_DIR/routes"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  printf '%s\n' "$2" | gh_respond 'api --method GET repos/apache/foo/pulls/1/reviews --paginate --slurp'
  gh_respond 'api --method GET repos/apache/foo/pulls/1/files --paginate --slurp' <<'JSON'
[[{"filename": "src/a.go", "status": "modified", "patch": "@@ -1 +1,3 @@\n package a\n+\n+func F() {}"}]]
JSON
  jq -n --arg h "$1" '{state: "open", merged: false, head: {sha: $h}, base: {ref: "main"}}' |
    gh_respond 'api --method GET repos/apache/foo/pulls/1'
  jq -n --arg s "${4:-PENDING}" '{id: 77, state: $s, html_url: "https://github.com/apache/foo/pull/1#pullrequestreview-77"}' |
    gh_respond 'api --method POST repos/apache/foo/pulls/1/reviews --input *' "${3:-0}"
}

submit() {
  run "$SCRIPTS/post.sh" --submit apache/foo#1 --sha "${1:-$SHA}"
}

posts() { grep -c '^api --method POST' "$GH_STUB_LOG" || true; }

@test "submit creates the pending review once and records it" {
  submit
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created a pending review on apache/foo#1 with 1 inline comment(s). Only you can see it until you submit it on GitHub: https://github.com/apache/foo/pull/1#pullrequestreview-77"* ]] || false
  [ "$(posts)" = "1" ]
  grep -q "^api --method POST repos/apache/foo/pulls/1/reviews --input $QUILL_HOME/post/apache__foo__1.json" "$GH_STUB_LOG"
  run jq -c '.prs["apache/foo#1"].posted | {reviewId, state, comments, commitId}' "$QUILL_HOME/state.json"
  [ "$output" = "{\"reviewId\":77,\"state\":\"PENDING\",\"comments\":1,\"commitId\":\"$HEAD_SHA\"}" ]
  [ -f "$QUILL_HOME/post/apache__foo__1.posted.json" ]
  [ ! -e "$QUILL_HOME/post/apache__foo__1.json" ]
}

@test "a second submit finds no payload and posts nothing" {
  submit
  [ "$status" -eq 0 ]
  submit
  [ "$status" -eq 6 ]
  [ "$(posts)" = "1" ]
}

@test "headless runs never post" {
  QUILL_HEADLESS=1 submit
  [ "$status" -eq 5 ]
  [[ "$output" == *"headless runs never post"* ]] || false
  [ "$(posts)" = "0" ]
}

@test "only from a session in the workspace" {
  cd "$TEST_TMP"
  submit
  [ "$status" -eq 5 ]
  [[ "$output" == *"run this from a Claude Code session started in"* ]] || false
  cd "$QUILL_HOME"
  CLAUDE_PROJECT_DIR="$TEST_TMP" submit
  [ "$status" -eq 5 ]
  [ "$(posts)" = "0" ]
}

@test "the workspace's explicit ask rule must still be there" {
  jq '.permissions.ask = []' "$QUILL_HOME/.claude/settings.json" >"$TEST_TMP/s" && mv "$TEST_TMP/s" "$QUILL_HOME/.claude/settings.json"
  submit
  [ "$status" -eq 5 ]
  [[ "$output" == *"lacks the ask rule"* ]] || false
  [ "$(posts)" = "0" ]
}

@test "the payload must be exactly what the dry run showed" {
  submit "0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -eq 5 ]
  [[ "$output" == *"the payload changed since the dry run"* ]] || false
  jq '.comments[0].body = "edited"' "$QUILL_HOME/post/apache__foo__1.json" >"$TEST_TMP/p" &&
    mv "$TEST_TMP/p" "$QUILL_HOME/post/apache__foo__1.json"
  submit
  [ "$status" -eq 5 ]
  [ "$(posts)" = "0" ]
}

@test "a tampered payload with a matching sha is still scanned" {
  local p="$QUILL_HOME/post/apache__foo__1.json" sha
  jq '.comments[0].body = "token ghp_abcdefghijklmnopqrstuvwxyz0123"' "$p" >"$TEST_TMP/p" && mv "$TEST_TMP/p" "$p"
  sha="$( (sha256sum 2>/dev/null || shasum -a 256) <"$p" | cut -d' ' -f1)"
  submit "$sha"
  [ "$status" -eq 5 ]
  jq '.comments[0].body = "fine" | .event = "APPROVE"' "$p" >"$TEST_TMP/p" && mv "$TEST_TMP/p" "$p"
  sha="$( (sha256sum 2>/dev/null || shasum -a 256) <"$p" | cut -d' ' -f1)"
  submit "$sha"
  [ "$status" -eq 5 ]
  [[ "$output" == *"would submit the review"* ]] || false
  [ "$(posts)" = "0" ]
}

@test "the head moved after the dry run: exit 3, nothing posted" {
  routes "1111111111111111111111111111111111111111" '[[]]'
  submit
  [ "$status" -eq 3 ]
  [ "$(posts)" = "0" ]
}

@test "a pending review appeared after the dry run: exit 4, nothing posted" {
  routes "$HEAD_SHA" '[[{"state": "PENDING", "user": {"login": "me"}}]]'
  submit
  [ "$status" -eq 4 ]
  [ "$(posts)" = "0" ]
}

@test "GitHub refusing the review is reported, state untouched" {
  routes "$HEAD_SHA" '[[]]' 1
  submit
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub refused the review"* ]] || false
  [ "$(jq '.prs["apache/foo#1"] | has("posted")' "$QUILL_HOME/state.json")" = "false" ]
  [ -f "$QUILL_HOME/post/apache__foo__1.json" ]
}

@test "a review GitHub didn't keep pending is flagged loudly" {
  routes "$HEAD_SHA" '[[]]' 0 COMMENTED
  submit
  [ "$status" -eq 0 ]
  [[ "$output" == *"not PENDING; check it on GitHub now"* ]] || false
}

@test "only the literal --submit and --sha are accepted" {
  run "$SCRIPTS/post.sh" --submit apache/foo#1
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --submit apache/foo#1 --SHA "$SHA"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --submi apache/foo#1 --sha "$SHA"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --submit apache/foo#1 --sha "$SHA" extra
  [ "$status" -eq 64 ]
  [ "$(posts)" = "0" ]
}
