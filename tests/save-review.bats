#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_git_sandbox
  export QUILL_HOME="$TEST_TMP/ws"
  "$SCRIPTS/init.sh" >/dev/null 2>&1
  export QUILL_GIT_BASE_URL="file://$TEST_TMP/remotes"
  HEAD_SHA="$(make_remote apache/foo)"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  GD="$(ensure_clone apache/foo)"
  fetch_pr apache/foo 1 main >/dev/null
  BASE_SHA="$(git --git-dir="$GD" rev-parse refs/quill/base/main)"
  NONCE="0123456789abcdef0123456789abcdef"
  RUN="$QUILL_HOME/reviews/2026-10-04/.run/r1"
  CTX="$RUN/ctx/apache__foo__1"
  mkdir -p "$CTX"
  jq -n --arg n "$NONCE" --arg h "$HEAD_SHA" --arg b "$BASE_SHA" \
    '{pr: "apache/foo#1", slug: "apache__foo__1", nonce: $n, head_sha: $h, merge_base: $b, mode: "full"}' >"$CTX/task.json"
  jq -n '{version: 1, prs: [{pr: "apache/foo#1", slug: "apache__foo__1"}]}' >"$RUN/dispatch.json"
  # src/a.go's hunk covers RIGHT lines 1-3 and LEFT line 1.
  SUMMARY="$(jq -cn --arg h "$HEAD_SHA" '{pr: "apache/foo#1", head: $h, verdict: "request_changes",
    reason: "F has no test.", effort: "M", fixes: "none", lowEffort: false,
    previousFindings: "n/a", aiDirectedText: false, blocking: 1}')"
  COMMENTS='[{"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "issue (blocking): F has no test."}]'
  write_review_md "Request changes"
}

teardown() {
  teardown_tmp
}

write_review_md() { # write_review_md <verdict heading text>
  cat >"$TEST_TMP/review.md" <<MD
# apache/foo#1: Add F
https://github.com/apache/foo/pull/1 | @alice (CONTRIBUTOR, 3 merged here) | +2/-0 in 1 files | CI: passing | head ${HEAD_SHA:0:7}

## Verdict: $1
F has no test.

## Blocking
1. issue (blocking): \`src/a.go:3\` F has no test.

## Should fix
None.

## Questions for the author
2. question: why F?
   Expected answer: because.

## Nits (max 3)
None.

## Tests
Not run. CI: passing.

## Contributor signals (private, never posted)
- Description matches the diff.
Read: likely understands it
MD
}

# write_report [nonce]: output.raw from $SUMMARY, the review and $COMMENTS.
write_report() {
  local n="${1:-$NONCE}"
  {
    printf 'Preamble the parser ignores.\n'
    printf '<<<QUILL %s SUMMARY>>>\n%s\n' "$n" "$SUMMARY"
    printf '<<<QUILL %s REVIEW>>>\n' "$n"
    cat "$TEST_TMP/review.md"
    printf '<<<QUILL %s COMMENTS>>>\n%s\n<<<QUILL %s END>>>\n' "$n" "$COMMENTS" "$n"
  } >"$CTX/output.raw"
}

save() {
  run "$SCRIPTS/save-review.sh" --run-dir "$RUN" --slug apache__foo__1
}

result() { # result <jq filter over this PR's result>
  jq -r ".[] | select(.slug == \"apache__foo__1\") | $1" "$RUN/results.json"
}

@test "a valid report is saved: review, comments, state, reviewed ref" {
  write_report
  save
  [ "$status" -eq 0 ]
  [ "$output" = "saved apache/foo#1: request_changes (M), 1 comment(s)" ]
  local d="$QUILL_HOME/reviews/2026-10-04"
  cmp -s "$d/apache__foo__1.md" "$TEST_TMP/review.md"
  [ "$(jq -c . "$d/apache__foo__1.comments.json")" = '[{"path":"src/a.go","line":3,"side":"RIGHT","body":"issue (blocking): F has no test."}]' ]
  run jq -r '.prs["apache/foo#1"] | [.reviewedHeadSha, .verdict, .effort, .reviewFile, .commentsFile, .run] | join(" ")' "$QUILL_HOME/state.json"
  [ "$output" = "$HEAD_SHA request_changes M reviews/2026-10-04/apache__foo__1.md reviews/2026-10-04/apache__foo__1.comments.json r1" ]
  [ "$(git --git-dir="$GD" rev-parse refs/quill/pr/1/reviewed)" = "$HEAD_SHA" ]
  [ "$(result .status)" = "saved" ]
}

@test "comments outside the diff are dropped with a warning; the review keeps the finding" {
  COMMENTS='[{"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "ok"},
             {"path": "src/a.go", "line": 40, "side": "RIGHT", "body": "far away"},
             {"path": "README.md", "line": 1, "side": "RIGHT", "body": "unchanged file"},
             {"path": "src/a.go", "line": 2, "side": "LEFT", "body": "no such old line"}]'
  write_report
  save
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 comment(s); warnings: dropped a comment: line 40 (RIGHT) of src/a.go is outside the diff"* ]] || false
  [ "$(jq length "$QUILL_HOME/reviews/2026-10-04/apache__foo__1.comments.json")" = "1" ]
  [ "$(result '.warnings | length')" = "3" ]
  grep -q 'src/a.go:3' "$QUILL_HOME/reviews/2026-10-04/apache__foo__1.md"
}

@test "comments carrying private text or bad fields are dropped" {
  COMMENTS='[{"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "question: why?\nExpected answer: because"},
             {"path": "src/a.go", "line": 2, "side": "RIGHT", "body": "Contributor signals: weak"},
             {"path": "../etc/passwd", "line": 1, "side": "RIGHT", "body": "x"},
             {"path": "/abs", "line": 1, "side": "RIGHT", "body": "x"},
             {"path": "src/a.go", "line": "2", "side": "RIGHT", "body": "x"},
             {"path": "src/a.go", "line": 2, "side": "MIDDLE", "body": "x"},
             {"path": "src/a.go", "line": 2, "side": "RIGHT", "body": "   "},
             {"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "question: why?\nexpected answer: because"},
             {"path": "src/a.go", "line": 3, "side": "RIGHT", "body": "issue: x\nRead: likely understands it"},
             "not an object"]'
  write_report
  save
  [ "$status" -eq 0 ]
  [ "$(jq length "$QUILL_HOME/reviews/2026-10-04/apache__foo__1.comments.json")" = "0" ]
  [ "$(result '.warnings | length')" = "10" ]
  [[ "$(result '.warnings | join("|")')" == *"private text"* ]] || false
}

@test "multi-line comments inside one hunk are kept with their start fields" {
  COMMENTS='[{"path": "src/a.go", "start_line": 1, "line": 3, "side": "RIGHT", "body": "x"}]'
  write_report
  save
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | {start_line, start_side}' "$QUILL_HOME/reviews/2026-10-04/apache__foo__1.comments.json")" = '{"start_line":1,"start_side":"RIGHT"}' ]
}

@test "no captured report: missing, nothing written" {
  save
  [ "$status" -eq 0 ]
  [[ "$output" == "missing apache/foo#1: "* ]] || false
  [ ! -e "$QUILL_HOME/reviews/2026-10-04/apache__foo__1.md" ]
  [ "$(jq -c '.prs' "$QUILL_HOME/state.json")" = "{}" ]
}

@test "markers with another nonce are ordinary text: rejected" {
  write_report "ffffffffffffffffffffffffffffffff"
  save
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejected apache/foo#1: no SUMMARY marker"* ]] || false
  [ ! -e "$QUILL_HOME/reviews/2026-10-04/apache__foo__1.md" ]
}

@test "text after END, repeated or out-of-order markers are rejected" {
  write_report
  printf 'trailing text\n' >>"$CTX/output.raw"
  save
  [[ "$output" == *"rejected apache/foo#1: text after the END marker"* ]] || false
  write_report
  printf '<<<QUILL %s SUMMARY>>>\n' "$NONCE" >>"$CTX/output.raw"
  save
  [[ "$output" == *"rejected"* ]] || false
  write_report
  grep -v "COMMENTS>>>" "$CTX/output.raw" >"$CTX/x" && mv "$CTX/x" "$CTX/output.raw"
  save
  [[ "$output" == *"rejected"* ]] || false
}

@test "a quoted marker line inside the review with the right nonce is rejected, not mis-split" {
  write_report
  { head -3 "$CTX/output.raw"; printf '<<<QUILL %s END>>>\n' "$NONCE"; tail -n +4 "$CTX/output.raw"; } >"$CTX/x"
  mv "$CTX/x" "$CTX/output.raw"
  save
  [[ "$output" == *"rejected"* ]] || false
}

@test "SUMMARY must match the task and the contract" {
  local bad
  for bad in '.pr = "apache/foo#2"' '.head = "1111111111111111111111111111111111111111"' \
    '.verdict = "lgtm"' '.effort = "XL"' '.fixes = "perf"' '.reason = ""' \
    '.reason = ("x" * 201)' '.reason = "two\nlines"' '.lowEffort = "no"' \
    '.previousFindings = "some"' '.aiDirectedText = 0' '.blocking = -1' '.blocking = 1.5'; do
    SUMMARY="$(jq -c "$bad" <<<"$SUMMARY")"
    write_report
    save
    echo "checking: $bad -> $output"
    [[ "$output" == "rejected apache/foo#1: SUMMARY"* ]] || false
    SUMMARY="$(jq -cn --arg h "$HEAD_SHA" '{pr: "apache/foo#1", head: $h, verdict: "request_changes",
      reason: "F has no test.", effort: "M", fixes: "none", lowEffort: false,
      previousFindings: "n/a", aiDirectedText: false, blocking: 1}')"
  done
}

@test "the review layout is enforced" {
  write_review_md "Approve"
  write_report
  save
  [[ "$output" == *"must read \"Request changes\""* ]] || false
  write_review_md "Request changes"
  sed -i.bak '1s/.*/# apache\/foo#2: wrong PR/' "$TEST_TMP/review.md"
  write_report
  save
  [[ "$output" == *"must start with"* ]] || false
  write_review_md "Request changes"
  sed -i.bak '/^## Tests$/d' "$TEST_TMP/review.md"
  write_report
  save
  [[ "$output" == *"missing section(s): Tests"* ]] || false
  write_review_md "Request changes"
  printf '\n## Blocking\nagain\n' >>"$TEST_TMP/review.md"
  write_report
  save
  [[ "$output" == *"rejected"* ]] || false
}

@test "a needs-answers review without a suggested reply is saved with a warning" {
  SUMMARY="$(jq -c '.verdict = "comment" | .blocking = 0' <<<"$SUMMARY")"
  write_review_md "Comment (needs answers)"
  write_report
  save
  [ "$status" -eq 0 ]
  [[ "$output" == "saved apache/foo#1: comment (M)"*"no Suggested reply section"* ]] || false
}

@test "style warnings: em dashes and banned phrases" {
  COMMENTS="$(jq -cn '[{path: "src/a.go", line: 3, side: "RIGHT", body: "Consider adding tests — please"}]')"
  write_report
  save
  [ "$status" -eq 0 ]
  [[ "$output" == *"em dashes"* ]] || false
  [[ "$output" == *"banned phrase in a comment: \"consider adding tests\""* ]] || false
}

@test "--all saves every dispatched PR; a re-save replaces its result; a new head drops posted" {
  write_report
  run "$SCRIPTS/save-review.sh" --run-dir "$RUN" --all
  [ "$status" -eq 0 ]
  jq '.prs["apache/foo#1"].posted = {reviewId: 9}' "$QUILL_HOME/state.json" >"$TEST_TMP/s" && mv "$TEST_TMP/s" "$QUILL_HOME/state.json"
  run "$SCRIPTS/save-review.sh" --run-dir "$RUN" --all
  [ "$(jq length "$RUN/results.json")" = "1" ]
  [ "$(jq -r '.prs["apache/foo#1"].posted.reviewId' "$QUILL_HOME/state.json")" = "9" ] # same head keeps it
  jq '.prs["apache/foo#1"].reviewedHeadSha = "old"' "$QUILL_HOME/state.json" >"$TEST_TMP/s" && mv "$TEST_TMP/s" "$QUILL_HOME/state.json"
  run "$SCRIPTS/save-review.sh" --run-dir "$RUN" --all
  [ "$(jq -r '.prs["apache/foo#1"] | has("posted")' "$QUILL_HOME/state.json")" = "false" ]
}

@test "CRLF line endings are tolerated" {
  write_report
  sed -i.bak 's/$/\r/' "$CTX/output.raw"
  save
  [[ "$output" == "saved apache/foo#1:"* ]] || false
}

@test "usage errors and bad slugs" {
  run "$SCRIPTS/save-review.sh" --run-dir "$RUN"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/save-review.sh" --run-dir "$RUN" --slug ../x
  [ "$status" -ne 0 ]
  run "$SCRIPTS/save-review.sh" --run-dir "$TEST_TMP/nowhere" --all
  [ "$status" -ne 0 ]
}

@test "a rejected report is moved aside, so a retried reviewer's report can be captured and saved" {
  local bad good
  bad="$(jq -c '.verdict = "approve"' <<<"$SUMMARY")" # disagrees with the review's verdict line
  good="$SUMMARY"
  SUMMARY="$bad"
  write_report
  save
  [[ "$output" == "rejected apache/foo#1: "* ]] || false
  [ ! -e "$CTX/output.raw" ]
  [ -s "$CTX/output.rejected.raw" ]
  # the retried reviewer's report goes through capture.sh, which keeps only the first one
  SUMMARY="$good"
  write_report
  mv "$CTX/output.raw" "$TEST_TMP/retry.txt"
  jq -cn --rawfile m "$TEST_TMP/retry.txt" '{hook_event_name: "SubagentStop", agent_type: "quill:pr-reviewer",
    agent_id: "retry1", last_assistant_message: $m}' >"$TEST_TMP/stop.json"
  run "$REPO_ROOT/hooks/capture.sh" <"$TEST_TMP/stop.json"
  [ -s "$CTX/output.raw" ]
  save
  [ "$output" = "saved apache/foo#1: request_changes (M), 1 comment(s)" ]
}
