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
  HEAD_SHA="$(make_remote apache/foo)"
  D="$QUILL_HOME/reviews/2026-10-04"
  mkdir -p "$D"
  jq -n --arg h "$HEAD_SHA" '{version: 1, prs: {"apache/foo#1": {reviewedHeadSha: $h,
    reviewFile: "reviews/2026-10-04/apache__foo__1.md", commentsFile: "reviews/2026-10-04/apache__foo__1.comments.json",
    verdict: "request_changes"}}}' >"$QUILL_HOME/state.json"
  # src/a.go: GitHub's hunk covers new lines 1-3.
  cat >"$D/apache__foo__1.comments.json" <<'JSON'
[
  {"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "issue (blocking): F has no test."},
  {"path": "src/a.go", "start_line": 1, "line": 2, "side": "RIGHT", "body": "suggestion: rename."},
  {"path": "src/a.go", "line": 40, "side": "RIGHT", "body": "question: far away?"}
]
JSON
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond 'api --method GET repos/apache/foo/pulls/1/reviews --paginate --slurp' <<'JSON'
[[{"id": 1, "state": "PENDING", "user": {"login": "someone-else"}}, {"id": 2, "state": "COMMENTED", "user": {"login": "me"}}]]
JSON
  files_with_patch
  pr_state open "$HEAD_SHA"
}

teardown() {
  teardown_tmp
}

files_with_patch() {
  gh_respond 'api --method GET repos/apache/foo/pulls/1/files --paginate --slurp' <<'JSON'
[[{"filename": "src/a.go", "status": "modified", "patch": "@@ -1 +1,3 @@\n package a\n+\n+func F() {}"}]]
JSON
}

pr_state() { # pr_state <open|closed> <head sha> [merged]
  local f="$TEST_TMP/pr.json"
  jq -n --arg s "$1" --arg h "$2" --argjson m "${3:-false}" \
    '{state: $s, merged: $m, head: {sha: $h}, base: {ref: "main"}}' >"$f"
  gh_respond 'api --method GET repos/apache/foo/pulls/1' <"$f"
}

payload() { cat "$QUILL_HOME/post/apache__foo__1.json"; }

@test "dry run: a pending-review payload at the reviewed head, never an event" {
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 0 ]
  [ "$(payload | jq -r .commit_id)" = "$HEAD_SHA" ]
  [ "$(payload | jq 'has("event")')" = "false" ]
  [ "$(payload | jq -c '[.comments[] | [.path, .line, .side, (.start_line // 0)]]')" = '[["src/a.go",3,"RIGHT",0],["src/a.go",2,"RIGHT",1]]' ]
}

@test "dry run: comments outside GitHub's diff move into the review body" {
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 0 ]
  [ "$(payload | jq -r .body)" = "$(printf 'Comments on lines outside the diff:\n\n- `src/a.go:40`: question: far away?')" ]
}

@test "dry run: prints every comment exactly as it would be posted, and the payload's sha256" {
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pending review for apache/foo#1 at ${HEAD_SHA:0:7}: 2 inline comment(s), plus comments on lines outside the diff"* ]] || false
  [[ "$output" == *"### src/a.go:3 (RIGHT)"*"issue (blocking): F has no test."* ]] || false
  [[ "$output" == *"### src/a.go:1-2 (RIGHT)"* ]] || false
  [[ "$output" == *"### Review body"*"question: far away?"* ]] || false
  local sha
  sha="$( (sha256sum 2>/dev/null || shasum -a 256) <"$QUILL_HOME/post/apache__foo__1.json" | cut -d' ' -f1)"
  [[ "$output" == *"sha256: $sha"* ]] || false
}

@test "the head moved since the review: stop with exit 3" {
  : >"$GH_STUB_DIR/routes"
  pr_state open "1111111111111111111111111111111111111111"
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 3 ]
  [[ "$output" == *"review it again with /quill:quill apache/foo#1"* ]] || false
  [ ! -e "$QUILL_HOME/post/apache__foo__1.json" ]
}

@test "a review pinned with --at to an earlier commit of an open PR can't be posted (exit 3)" {
  # state.json records the pinned commit; GitHub's head is the PR's later one
  local pinned="1bbcabb50588c22ddb19fa6ee4ce14b5e0506ca8"
  jq --arg p "$pinned" '.prs["apache/foo#1"].reviewedHeadSha = $p' "$QUILL_HOME/state.json" >"$TEST_TMP/s.json"
  mv "$TEST_TMP/s.json" "$QUILL_HOME/state.json"
  pr_state open "$HEAD_SHA"
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 3 ]
  [[ "$output" == *"moved from 1bbcabb to ${HEAD_SHA:0:7}"* ]] || false
  [ ! -e "$QUILL_HOME/post/apache__foo__1.json" ]
}

@test "I already have a pending review: stop with exit 4" {
  : >"$GH_STUB_DIR/routes"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond 'api --method GET repos/apache/foo/pulls/1/reviews --paginate --slurp' <<'JSON'
[[{"id": 2, "state": "COMMENTED", "user": {"login": "me"}}], [{"id": 3, "state": "PENDING", "user": {"login": "me"}}]]
JSON
  files_with_patch
  pr_state open "$HEAD_SHA"
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 4 ]
  [[ "$output" == *"already have a pending review"* ]] || false
}

@test "a closed or merged PR has nothing to post" {
  : >"$GH_STUB_DIR/routes"
  pr_state closed "$HEAD_SHA" true
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -ne 0 ]
  [[ "$output" == *"apache/foo#1 is merged"* ]] || false
}

@test "no drafted review: exit 6" {
  run "$SCRIPTS/post.sh" --dry-run apache/foo#2
  [ "$status" -eq 6 ]
  [[ "$output" == *"run /quill:quill apache/foo#2 first"* ]] || false
}

@test "anything that looks like a credential or private notes is refused (exit 5)" {
  local body
  for body in "token ghp_abcdefghijklmnopqrstuvwxyz0123" "github_pat_11ABC" "AKIAABCDEFGHIJKLMNOP" \
    "-----BEGIN OPENSSH PRIVATE KEY-----" "xoxb-1234-5678" "Expected answer: because" "contributor signals: weak" \
    "refresh ghr_abcdefghijklmnopqrstuvwxyz0123" "key sk-ant-api03-abcdef"; do
    jq -n --arg b "$body" '[{path: "src/a.go", line: 3, side: "RIGHT", body: $b}]' >"$D/apache__foo__1.comments.json"
    rm -f "$QUILL_HOME/post/apache__foo__1.json"
    run "$SCRIPTS/post.sh" --dry-run apache/foo#1
    echo "body: $body -> $status"
    [ "$status" -eq 5 ]
    [ ! -e "$QUILL_HOME/post/apache__foo__1.json" ]
  done
}

@test "a file GitHub sends no patch for is checked against the local diff" {
  : >"$GH_STUB_DIR/routes"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond 'api --method GET repos/apache/foo/pulls/1/reviews --paginate --slurp' <<'JSON'
[[]]
JSON
  gh_respond 'api --method GET repos/apache/foo/pulls/1/files --paginate --slurp' <<'JSON'
[[{"filename": "src/a.go", "status": "modified"}]]
JSON
  pr_state open "$HEAD_SHA"
  # without a local clone the comments can't be placed: all go to the body
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 0 ]
  [ "$(payload | jq '.comments | length')" = "0" ]
  # with the cached clone (as prepare.sh leaves it) the local diff places them
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  ensure_clone apache/foo >/dev/null
  fetch_pr apache/foo 1 main >/dev/null
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -eq 0 ]
  [ "$(payload | jq '.comments | length')" = "2" ]
}

@test "a failed GitHub request stops with gh's message" {
  : >"$GH_STUB_DIR/routes"
  gh_respond 'api --method GET repos/apache/foo/pulls/1' 1 </dev/null
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1
  [ "$status" -ne 0 ]
  [[ "$output" == *"GitHub request failed"* ]] || false
}

@test "usage: only --dry-run with exactly one PR reference" {
  run "$SCRIPTS/post.sh"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --dry-run
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --dry-run apache/foo#1 extra
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --sub apache/foo#1
  [ "$status" -eq 64 ]
  run "$SCRIPTS/post.sh" --dry-run 'apache/foo#1;id'
  [ "$status" -ne 0 ]
}
