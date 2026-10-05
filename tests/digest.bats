#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# digest.sh: the chat digest of the reviews saved in a run.

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  unset QUILL_HEADLESS
  D="$QUILL_HOME/reviews/2026-10-05"
  RUN="$D/.run/r1"
  mkdir -p "$RUN/ctx"
  printf '{"version": 1, "prs": {}}\n' >"$QUILL_HOME/state.json"
  printf '[]\n' >"$RUN/results.json"
  printf '{"version": 1, "items": []}\n' >"$RUN/queue.json"
}

teardown() {
  teardown_tmp
}

# saved <n> <verdict> <comment count> <PR state> <reason>: a saved result for
# apache/foo#<n>, with its state reason and queue state. The caller writes the
# review to $D/apache__foo__<n>.md and the comments to .comments.json.
saved() {
  jq --arg n "$1" --arg v "$2" --argjson c "$3" '. + [{pr: "apache/foo#\($n)", slug: "apache__foo__\($n)",
    status: "saved", verdict: $v, effort: "M", comments: $c,
    reviewFile: "reviews/2026-10-05/apache__foo__\($n).md",
    commentsFile: "reviews/2026-10-05/apache__foo__\($n).comments.json"}]' \
    "$RUN/results.json" >"$TEST_TMP/r.json" && mv "$TEST_TMP/r.json" "$RUN/results.json"
  jq --arg k "apache/foo#$1" --arg r "$5" '.prs[$k] = {reason: $r}' "$QUILL_HOME/state.json" >"$TEST_TMP/s.json" &&
    mv "$TEST_TMP/s.json" "$QUILL_HOME/state.json"
  jq --argjson n "$1" --arg s "$4" '.items += [{repo: "apache/foo", number: $n, state: $s}]' "$RUN/queue.json" >"$TEST_TMP/q.json" &&
    mv "$TEST_TMP/q.json" "$RUN/queue.json"
  [ -f "$D/apache__foo__$1.comments.json" ] || printf '[]\n' >"$D/apache__foo__$1.comments.json"
}

digest() { run "$SCRIPTS/digest.sh" --run-dir "$RUN" "$@"; }

shown() { # shown <path>: the review path as digest.sh prints it
  case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

full_review() { # the review of apache/foo#7
  cat >"$D/apache__foo__7.md" <<'MD'
# apache/foo#7: Add F
https://github.com/apache/foo/pull/7 | @alice (CONTRIBUTOR, 2 merged here) | +40/-2 in 3 files | CI: failing | head abc1234

## Verdict: Request changes
F panics on empty input, and nothing tests it.

## Blocking
1. issue (blocking): `src/f.go:12`: F indexes `xs[0]` without a length check. It panics on an empty slice.
   - Fix: return early when `len(xs) == 0`.

## Should fix
2. suggestion: `src/f_test.go:1`: add a case for an empty slice, as AGENTS.md:40 asks (L1-9).

## Questions for the author
3. question: `src/f.go:30`: why a global cache here?
   Expected answer: to avoid recomputing per call.

## Nits (max 3)
4. nitpick (non-blocking): `src/f.go:5`: unused import.
5. nitpick (non-blocking): `src/f.go:9`: typo.

## Tests
Not run.

## Contributor signals (private, never posted)
- PRIVATE SIGNAL
Read: unclear

## Suggested reply (low-effort or needs-answers PRs only)
SUGGESTED REPLY
MD
  cat >"$D/apache__foo__7.comments.json" <<'JSON'
[{"path": "src/f.go", "line": 5, "side": "RIGHT", "body": "nitpick (non-blocking): unused import."},
 {"path": "src/f.go", "line": 30, "side": "RIGHT", "body": "question: why a global cache here?",
  "summary": "Why keep a global cache here instead of one per call?"},
 {"path": "src/f.go", "line": 12, "side": "RIGHT", "body": "issue (blocking): F indexes xs[0] without a length check.",
  "summary": "F panics on an empty slice because it reads xs[0] first. Please return early when the slice is empty."},
 {"path": "src/f_test.go", "line": 1, "side": "RIGHT", "body": "suggestion: add a test for an empty slice.",
  "summary": "Please add a test for an empty slice."}]
JSON
}

@test "a review: reason, findings without labels or file:line references, suggested comments, and the post offer" {
  full_review
  saved 7 request_changes 4 OPEN "F panics on empty input."
  digest
  [ "$status" -eq 0 ]
  local want
  want="$(cat <<OUT
### apache/foo#7: Add F

F panics on empty input.

**Blocking**

1. F indexes \`xs[0]\` without a length check.

**Should fix**

2. Add a case for an empty slice, as AGENTS.md asks.

**Suggested comments**

- F panics on an empty slice because it reads xs[0] first. Please return early when the slice is empty.
- Please add a test for an empty slice.
- Why keep a global cache here instead of one per call?

2 nit(s) | Review: $(shown "$D/apache__foo__7.md")

Want me to add these as a pending review on GitHub? It holds all the drafted comments, and only you will see it until you submit it there. Reply **post** to go ahead.
OUT
)"
  [ "$output" = "$want" ] || {
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$output")
    false
  }
  # what stays in the file
  local hidden
  for hidden in "Expected answer" "PRIVATE SIGNAL" "SUGGESTED REPLY" "Fix: return early" "https://github.com" \
    "CI: failing" "Request changes" "Questions for the author" "unused import" "f.go:12" "(L1-9)"; do
    if [[ "$output" == *"$hidden"* ]]; then
      echo "shown: $hidden"
      false
    fi
  done
}

@test "questions for the author appear only when the PR needs answers" {
  full_review
  sed -i.bak 's/^## Verdict: Request changes$/## Verdict: Comment (needs answers)/' "$D/apache__foo__7.md"
  saved 7 comment 4 OPEN "Unclear why there is a cache."
  digest
  [[ "$output" == *$'**Questions for the author**\n\n3. Why a global cache here?'* ]] || false
}

@test "without summaries, suggested comments are the bodies as whole sentences, at most three, most severe first" {
  printf '# apache/foo#8: T\nfacts\n\n## Verdict: Request changes\nx\n\n## Blocking\nNone.\n' >"$D/apache__foo__8.md"
  jq -n '[
    {path: "a", line: 1, body: "question: is this needed?"},
    {path: "a", line: 2, body: "nitpick: rename it."},
    {path: "a", line: 3, body: "issue: `a.go:3`: the loop never ends.\n\n- It reads `i` but never updates it.\n- See `b.go:9` (L9-12).\n\n```go\nfor i < n {}\n```\nPlease increment `i`."},
    {path: "a", line: 4, body: "suggestion: extract a helper."}]' >"$D/apache__foo__8.comments.json"
  saved 8 request_changes 4 OPEN "loop"
  digest
  [ "$status" -eq 0 ]
  local s
  s="$(sed -n '/^\*\*Suggested comments\*\*$/,/nit(s)\|^Review:/p' <<<"$output" | grep '^- ')"
  [ "$s" = "$(printf '%s\n' \
    '- The loop never ends. It reads `i` but never updates it. See `b.go`. Please increment `i`.' \
    '- Extract a helper.' \
    '- Is this needed?')" ]
}

@test "long suggested comments keep whole sentences within 300 characters" {
  printf '# apache/foo#9: T\nfacts\n\n## Verdict: Request changes\nx\n\n## Blocking\nNone.\n' >"$D/apache__foo__9.md"
  local s120
  s120="$(printf 'w%.0s' $(seq 1 118))"
  jq -n --arg s "$s120" '[{path: "a", line: 1, body: "issue: \($s). \($s). \($s)."}]' >"$D/apache__foo__9.comments.json"
  saved 9 request_changes 1 OPEN "x"
  digest
  local line
  line="$(grep '^- ' <<<"$output")"
  [ "$line" = "- $(printf '%s. %s.' "$s120" "$s120" | sed 's/^w/W/')" ]
}

@test "the post offer: one PR, several PRs, never for merged PRs, PRs without comments, or headless runs" {
  local n
  for n in 1 2; do
    printf '# apache/foo#%s: T\nfacts\n\n## Verdict: Request changes\nx\n\n## Blocking\nNone.\n' "$n" >"$D/apache__foo__$n.md"
  done
  saved 1 request_changes 2 OPEN "a"
  digest
  [ "${lines[${#lines[@]} - 1]}" = "Want me to add these as a pending review on GitHub? It holds all the drafted comments, and only you will see it until you submit it there. Reply **post** to go ahead." ]
  saved 2 request_changes 1 OPEN "b"
  digest
  [ "${lines[${#lines[@]} - 1]}" = "Want me to add any of these as pending reviews on GitHub? Only you will see them until you submit them there. Reply **post** with the PR, for example **post apache/foo#1**." ]
  QUILL_HEADLESS=1 digest
  [[ "$output" != *"Want me to"* ]] || false
  jq '.items |= map(.state = "MERGED")' "$RUN/queue.json" >"$TEST_TMP/q.json" && mv "$TEST_TMP/q.json" "$RUN/queue.json"
  digest
  [[ "$output" != *"Want me to"* ]] || false
  jq '.items |= map(.state = "OPEN")' "$RUN/queue.json" >"$TEST_TMP/q.json" && mv "$TEST_TMP/q.json" "$RUN/queue.json"
  jq 'map(.comments = 0)' "$RUN/results.json" >"$TEST_TMP/r.json" && mv "$TEST_TMP/r.json" "$RUN/results.json"
  digest
  [[ "$output" != *"Want me to"* ]] || false
}

@test "a re-review after a retrospective note: previous findings, no blocking" {
  cat >"$D/apache__foo__4095.md" <<'MD'
> PR is merged; review is retrospective.

# apache/foo#4095: feat(json): null handling
https://github.com/apache/foo/pull/4095 | @bob (MEMBER, 9 merged here) | +3/-1 in 1 file | CI: passing | head ad484f7

## Verdict: Approve
Only tests changed.

## Previous findings
My earlier review at `src/a.go:3` had no findings, so nothing was left open.

## Blocking
None.

## Should fix
None.

## Questions for the author
None.

## Nits (max 3)
None.
MD
  saved 4095 approve 0 MERGED "The new commit only swaps test fixtures."
  digest
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "### apache/foo#4095: feat(json): null handling" ]
  [[ "$output" == *"**Previous findings:** My earlier review at \`src/a.go\` had no findings, so nothing was left open."* ]] || false
  [[ "$output" == *"**Blocking:** none"* ]] || false
  [[ "$output" != *"Should fix"* ]] || false
  [[ "$output" != *"Suggested comments"* ]] || false
  [[ "$output" != *"Want me to"* ]] || false
}

minimal_review() { # minimal_review <n> <verdict label>
  printf '# apache/foo#%s: PR %s\nfacts\n\n## Verdict: %s\nx\n\n## Blocking\nNone.\n' "$1" "$1" "$2" >"$D/apache__foo__$1.md"
}

@test "most severe first, at most --max, the rest counted; unsaved results are skipped" {
  saved 1 approve 0 OPEN "fine"
  minimal_review 1 Approve
  saved 2 request_changes 0 OPEN "broken"
  minimal_review 2 "Request changes"
  saved 3 comment 0 OPEN "unclear"
  minimal_review 3 "Comment (needs answers)"
  jq '. + [{pr: "apache/foo#9", slug: "apache__foo__9", status: "rejected", reason: "bad"}]' "$RUN/results.json" >"$TEST_TMP/r.json"
  mv "$TEST_TMP/r.json" "$RUN/results.json"
  digest --max 2
  [ "$status" -eq 0 ]
  [ "$(grep '^### ' <<<"$output" | tr '\n' '|')" = "### apache/foo#2: PR 2|### apache/foo#3: PR 3|" ]
  [ "${lines[${#lines[@]} - 1]}" = "1 more review(s) in QUEUE.md." ]
  [[ "$output" != *"apache/foo#9"* ]] || false
}

@test "nothing reviewed in the run: no output" {
  rm -f "$RUN/results.json"
  digest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "review text is cleaned: no control characters, findings capped at 220 characters" {
  saved 5 request_changes 0 OPEN "$(printf 'reason with \033[31mcolor\033[0m')"
  local long
  long="$(printf 'x%.0s' $(seq 1 400))"
  printf '# apache/foo#5: T\nfacts\n\n## Verdict: Request changes\nx\n\n## Blocking\n1. issue (blocking): %s\n' "$long" >"$D/apache__foo__5.md"
  digest
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]] || false
  [[ "$output" == *"reason with [31mcolor[0m"* ]] || false
  local item
  item="$(grep '^1\. ' <<<"$output")"
  [ "${#item}" -eq 223 ]
  [[ "$item" == *"..." ]] || false
}

@test "review and comment files outside reviews/ are not read" {
  saved 6 request_changes 1 OPEN "x"
  printf '# apache/foo#6: SECRET\n' >"$TEST_TMP/secret.md"
  printf '[{"path": "a", "line": 1, "body": "issue: LEAK"}]\n' >"$TEST_TMP/secret.json"
  # relative to the workspace, ../secret.* is in $TEST_TMP: outside reviews/
  jq '.[0].reviewFile = "../secret.md"' "$RUN/results.json" >"$TEST_TMP/r.json"
  mv "$TEST_TMP/r.json" "$RUN/results.json"
  digest
  [ "$status" -eq 0 ]
  [[ "$output" != *"SECRET"* ]] || false
  minimal_review 6 "Request changes"
  jq '.[0].reviewFile = "reviews/2026-10-05/apache__foo__6.md" | .[0].commentsFile = "../secret.json"' "$RUN/results.json" >"$TEST_TMP/r.json"
  mv "$TEST_TMP/r.json" "$RUN/results.json"
  digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"### apache/foo#6"* ]] || false
  [[ "$output" != *"LEAK"* ]] || false
}

@test "usage errors" {
  run "$SCRIPTS/digest.sh"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/digest.sh" --run-dir "$RUN" --max 0
  [ "$status" -eq 64 ]
  run "$SCRIPTS/digest.sh" --run-dir "$TEST_TMP"
  [ "$status" -ne 0 ]
}
