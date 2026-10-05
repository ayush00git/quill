#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# digest.sh: the chat digest of the reviews saved in a run.

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  D="$QUILL_HOME/reviews/2026-10-05"
  RUN="$D/.run/r1"
  mkdir -p "$RUN/ctx"
  printf '{"version": 1, "prs": {}}\n' >"$QUILL_HOME/state.json"
  printf '[]\n' >"$RUN/results.json"
}

teardown() {
  teardown_tmp
}

# saved <n> <verdict> <comments> <mode> <reason>: a saved result for
# apache/foo#<n>, with its state reason and task.json; the review file is
# written by the caller to $D/apache__foo__<n>.md.
saved() {
  local slug="apache__foo__$1"
  mkdir -p "$RUN/ctx/$slug"
  jq --arg n "$1" --arg v "$2" --argjson c "$3" '. + [{pr: "apache/foo#\($n)", slug: "apache__foo__\($n)",
    status: "saved", verdict: $v, effort: "M", reviewFile: "reviews/2026-10-05/apache__foo__\($n).md", comments: $c}]' \
    "$RUN/results.json" >"$TEST_TMP/r.json" && mv "$TEST_TMP/r.json" "$RUN/results.json"
  jq --arg k "apache/foo#$1" --arg r "$5" '.prs[$k] = {reason: $r}' "$QUILL_HOME/state.json" >"$TEST_TMP/s.json" &&
    mv "$TEST_TMP/s.json" "$QUILL_HOME/state.json"
  jq -n --arg m "$4" '{mode: $m, last_reviewed: (if $m == "full" then null else "1bbcabb50588c22ddb19fa6ee4ce14b5e0506ca8" end)}' \
    >"$RUN/ctx/$slug/task.json"
}

digest() { run "$SCRIPTS/digest.sh" --run-dir "$RUN" "$@"; }

@test "a full review: header, verdict line, reason, and every blocking, should-fix and question headline" {
  saved 7 request_changes 3 full "F panics on empty input."
  cat >"$D/apache__foo__7.md" <<'MD'
# apache/foo#7: Add F
https://github.com/apache/foo/pull/7 | @alice (CONTRIBUTOR, 2 merged here) | +40/-2 in 3 files | CI: failing | head abc1234

## Verdict: Request changes
F panics on empty input, and nothing tests it.

## Attention
- `.github/workflows/ci.yml:12`: the PR changes a workflow.

## Blocking
1. issue (blocking): `src/f.go:12`: F indexes `xs[0]` without a length check.
   - Fix: return early when `len(xs) == 0`.

## Should fix
2. suggestion: `src/f_test.go:1`: add a case for an empty slice.

## Questions for the author
3. question: `src/f.go:30`: why a global cache here?
   Expected answer: to avoid recomputing per call; it is safe because writes are locked.

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
  digest
  [ "$status" -eq 0 ]
  local want
  want="$(cat <<'OUT'
### apache/foo#7: Add F
https://github.com/apache/foo/pull/7 | @alice (CONTRIBUTOR, 2 merged here) | +40/-2 in 3 files | CI: failing | head abc1234

**Request changes** | effort M | 3 inline comment(s) | full review

F panics on empty input.

**Attention:** - `.github/workflows/ci.yml:12`: the PR changes a workflow.

**Blocking**

1. `src/f.go:12`: F indexes `xs[0]` without a length check.

**Should fix**

2. `src/f_test.go:1`: add a case for an empty slice.

**Questions for the author**

3. `src/f.go:30`: why a global cache here?

2 nit(s) | Review: ~/quill/reviews/2026-10-05/apache__foo__7.md
OUT
)"
  # the review path is shown relative to the real home only when it's under it
  want="${want//\~\/quill/$QUILL_HOME}"
  [ "$output" = "$want" ] || {
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$output")
    false
  }
  # what stays in the file
  [[ "$output" != *"Expected answer"* ]] || false
  [[ "$output" != *"PRIVATE SIGNAL"* ]] || false
  [[ "$output" != *"SUGGESTED REPLY"* ]] || false
  [[ "$output" != *"Fix: return early"* ]] || false
}

@test "a re-review after a retrospective note: scope since the last review, previous findings, no blocking" {
  saved 4095 approve 0 incremental "The new commit only swaps test fixtures."
  cat >"$D/apache__foo__4095.md" <<'MD'
> PR is merged; review is retrospective.

# apache/foo#4095: feat(json): null handling
https://github.com/apache/foo/pull/4095 | @bob (MEMBER, 9 merged here) | +3/-1 in 1 file | CI: passing | head ad484f7

## Verdict: Approve
Only tests changed.

## Previous findings
My earlier review had no findings, so nothing was left open.

## Blocking
None.

## Should fix
None.

## Questions for the author
None.

## Nits (max 3)
None.
MD
  digest
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "### apache/foo#4095: feat(json): null handling" ]
  [[ "$output" == *"**Approve** | effort M | 0 inline comment(s) | changes since 1bbcabb only"* ]] || false
  [[ "$output" == *"**Previous findings:** My earlier review had no findings, so nothing was left open."* ]] || false
  [[ "$output" == *"**Blocking:** none"* ]] || false
  [[ "$output" != *"Should fix"* ]] || false
  [[ "$output" != *"Questions for the author"* ]] || false
  [[ "$output" != *"nit(s)"* ]] || false
}

minimal_review() { # minimal_review <n> <verdict label>
  printf '# apache/foo#%s: PR %s\nfacts\n\n## Verdict: %s\nx\n\n## Blocking\nNone.\n' "$1" "$1" "$2" >"$D/apache__foo__$1.md"
}

@test "most severe first, at most --max, the rest counted; unsaved results are skipped" {
  saved 1 approve 0 full "fine"
  minimal_review 1 Approve
  saved 2 request_changes 1 full "broken"
  minimal_review 2 "Request changes"
  saved 3 comment 2 full "unclear"
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

@test "review text is cleaned: no control characters, lines capped at 220 characters" {
  saved 5 request_changes 1 full "$(printf 'reason with \033[31mcolor\033[0m')"
  local long
  long="$(printf 'x%.0s' $(seq 1 400))"
  printf '# apache/foo#5: T\nfacts\n\n## Verdict: Request changes\nx\n\n## Blocking\n1. issue (blocking): %s\n' "$long" >"$D/apache__foo__5.md"
  digest
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]] || false
  [[ "$output" == *"reason with [31mcolor[0m"* ]] || false
  local item
  item="$(grep '^1\. ' <<<"$output")"
  [ "${#item}" -eq 220 ]
  [[ "$item" == *"..." ]] || false
}

@test "a review file outside reviews/ is not read" {
  saved 6 request_changes 1 full "x"
  printf '# apache/foo#6: SECRET\n' >"$TEST_TMP/secret.md"
  # relative to the workspace, ../secret.md is $TEST_TMP/secret.md: outside reviews/
  [ -f "$QUILL_HOME/../secret.md" ]
  jq '.[0].reviewFile = "../secret.md"' "$RUN/results.json" >"$TEST_TMP/r.json"
  mv "$TEST_TMP/r.json" "$RUN/results.json"
  digest
  [ "$status" -eq 0 ]
  [[ "$output" != *"SECRET"* ]] || false
}

@test "usage errors" {
  run "$SCRIPTS/digest.sh"
  [ "$status" -eq 64 ]
  run "$SCRIPTS/digest.sh" --run-dir "$RUN" --max 0
  [ "$status" -eq 64 ]
  run "$SCRIPTS/digest.sh" --run-dir "$TEST_TMP"
  [ "$status" -ne 0 ]
}
