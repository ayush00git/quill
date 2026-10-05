#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# save-review.sh: turn each captured reviewer report into review files.
#
#   save-review.sh --run-dir <dir> (--slug <owner__repo__N> | --all)
#
# For each PR: reads ctx/<slug>/output.raw (written by hooks/capture.sh),
# checks it against references/output-contract.md, and writes
#   reviews/<date>/<slug>.md              the review (private)
#   reviews/<date>/<slug>.comments.json   postable inline comments only
# then records the result in state.json and refs/quill/pr/<N>/reviewed.
# Comments outside the diff, or carrying private text, are dropped with a
# warning; anything else that breaks the contract rejects the report.
# Results go to <run-dir>/results.json and one line per PR on stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"
# shellcheck source=lib/mode.sh
source "$SCRIPT_DIR/lib/mode.sh"
# shellcheck source=lib/diffmap.sh
source "$SCRIPT_DIR/lib/diffmap.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

# Phrases comment-style.md bans unless tied to a line; reported as warnings.
BANNED_PHRASES='consider adding tests
improve error handling
add comments
follow best practices
ensure thread safety
could be optimized
for better readability'

# split_report <raw> <nonce> <out dir>: writes summary.json, review.md and
# comments.json from the four marker-delimited blocks. Fails with a reason.
split_report() {
  local raw="$1" nonce="$2" out="$3"
  awk -v n="$nonce" -v out="$out" '
    BEGIN {
      ms = "<<<QUILL " n " SUMMARY>>>"; mr = "<<<QUILL " n " REVIEW>>>"
      mc = "<<<QUILL " n " COMMENTS>>>"; me = "<<<QUILL " n " END>>>"
      state = 0
    }
    { sub(/\r$/, "") }
    state == 0 { if ($0 == ms) state = 1; next }
    $0 == ms || ($0 == mr && state != 1) || ($0 == mc && state != 2) || ($0 == me && state != 3) {
      print "marker out of order or repeated: " $0 > "/dev/stderr"; bad = 1; exit 1
    }
    state == 1 { if ($0 == mr) { state = 2; next } print > (out "/summary.json"); next }
    state == 2 { if ($0 == mc) { state = 3; next } print > (out "/review.md"); next }
    state == 3 { if ($0 == me) { state = 4; next } print > (out "/comments.json"); next }
    state == 4 { if ($0 !~ /^[ \t]*$/) { print "text after the END marker" > "/dev/stderr"; bad = 1; exit 1 } }
    END {
      if (bad) exit 1
      if (state == 0) { print "no SUMMARY marker with this task'"'"'s nonce" > "/dev/stderr"; exit 1 }
      if (state != 4) { print "missing REVIEW, COMMENTS or END marker" > "/dev/stderr"; exit 1 }
    }
  ' "$raw" || return 1
  touch "$out/summary.json" "$out/review.md" "$out/comments.json"
}

# check_summary <summary.json> <task.json>: prints the normalized summary.
check_summary() {
  jq -e -s --slurpfile task "$2" '
    def fail($m): error($m);
    if length != 1 then fail("SUMMARY must be exactly one JSON object") else .[0] end
    | if type != "object" then fail("SUMMARY must be a JSON object") else . end
    | ($task[0]) as $t
    | if .pr != $t.pr then fail("SUMMARY pr \(.pr | tojson) is not \($t.pr)")
      elif .head != $t.head_sha then fail("SUMMARY head \(.head | tojson) is not the reviewed head \($t.head_sha)")
      elif ([.verdict] | inside(["request_changes", "approve", "comment"]) | not) then fail("SUMMARY verdict must be request_changes, approve or comment")
      elif (.reason | type) != "string" or (.reason | length) == 0 or (.reason | length) > 200 or (.reason | test("\n")) then fail("SUMMARY reason must be one line of 1 to 200 characters")
      elif ([.effort] | inside(["S", "M", "L"]) | not) then fail("SUMMARY effort must be S, M or L")
      elif ([.fixes] | inside(["security", "regression", "none"]) | not) then fail("SUMMARY fixes must be security, regression or none")
      elif (.lowEffort | type) != "boolean" then fail("SUMMARY lowEffort must be a boolean")
      elif ([.previousFindings] | inside(["n/a", "addressed", "partly", "not_addressed"]) | not) then fail("SUMMARY previousFindings must be n/a, addressed, partly or not_addressed")
      elif (.aiDirectedText | type) != "boolean" then fail("SUMMARY aiDirectedText must be a boolean")
      elif (.blocking | type) != "number" or .blocking < 0 or .blocking != (.blocking | floor) then fail("SUMMARY blocking must be a non-negative integer")
      else {pr, head, verdict, reason, effort, fixes, lowEffort, previousFindings, aiDirectedText, blocking}
      end' "$1"
}

# check_review <review.md> <summary json file>: prints warnings (one per
# line); fails with a reason when the layout is broken.
check_review() {
  local md="$1" summary="$2" pr verdict want headings
  pr="$(jq -r .pr "$summary")"
  verdict="$(jq -r .verdict "$summary")"
  case "$(head -1 "$md")" in
    "# $pr: "*) ;;
    *) echo "the review must start with \"# $pr: <title>\"" >&2; return 1 ;;
  esac
  case "$verdict" in
    request_changes) want="Request changes" ;;
    approve) want="Approve" ;;
    comment) want="Comment (needs answers)" ;;
  esac
  grep -qxF "## Verdict: $want" "$md" || {
    echo "the review's \"## Verdict:\" line must read \"$want\" to match the SUMMARY" >&2
    return 1
  }
  headings="$(grep '^## ' "$md" | sed -e 's/^## //' -e 's/^Verdict: .*/Verdict/')"
  jq -r -R -s --argjson low "$(jq .lowEffort "$summary")" --arg verdict "$verdict" '
    split("\n") | map(select(length > 0)) as $h
    | ["Verdict", "Attention", "Previous findings", "Blocking", "Should fix", "Questions for the author",
       "Nits (max 3)", "Tests", "Contributor signals (private, never posted)",
       "Suggested reply (low-effort or needs-answers PRs only)"] as $order
    | ["Verdict", "Blocking", "Should fix", "Questions for the author", "Nits (max 3)", "Tests",
       "Contributor signals (private, never posted)"] as $required
    | ([$required[] | select(. as $r | $h | index($r) | not)]) as $missing
    | if ($missing | length) > 0 then error("the review is missing section(s): \($missing | join(", "))")
      elif ([$h[] | select(. as $x | $order | index($x) | not)] | length) > 0 then
        error("unknown section(s): \([$h[] | select(. as $x | $order | index($x) | not)] | join(", "))")
      elif ($h | map(. as $x | $order | index($x))) != ($h | map(. as $x | $order | index($x)) | sort) then
        error("sections are out of order")
      elif ($h | length) != ($h | unique | length) then error("a section appears twice")
      else
        (if ($verdict == "comment" or $low) and ($h | index("Suggested reply (low-effort or needs-answers PRs only)") | not)
         then "no Suggested reply section, though the PR needs answers or is low effort" else empty end)
      end' <<<"$headings" || return 1
}

# check_comments <comments.json> <diff map file>: prints {kept, dropped}.
check_comments() {
  jq -e -s -L "$SCRIPT_DIR/lib" --slurpfile map "$2" '
    include "diffmap";
    if length != 1 then error("COMMENTS must be exactly one JSON array") else .[0] end
    | if type != "array" then error("COMMENTS must be a JSON array") else . end
    | $map[0] as $m
    | map(
        if type != "object" then {drop: "not an object", c: .}
        elif (.path | type) != "string" or (.path | startswith("/")) or (.path | test("(^|/)\\.\\.(/|$)")) then {drop: "bad path", c: .}
        elif (.body | type) != "string" or (.body | test("^\\s*$")) then {drop: "empty body", c: .}
        elif ([.side // "RIGHT"] | inside(["RIGHT", "LEFT"]) | not) then {drop: "side must be RIGHT or LEFT", c: .}
        elif (.line | type) != "number" or .line < 1 or .line != (.line | floor) then {drop: "line must be a positive integer", c: .}
        elif (.body | length) > 65000 then {drop: "body over GitHub'"'"'s comment size limit", c: .}
        # case-insensitive, and Read: at the start of any line (jq'"'"'s ^ only anchors the whole string)
        elif (.body | test("expected answer|contributor signals|(^|\n)\\s*read: *(likely understands|unclear|low effort)"; "i")) then {drop: "private text (expected answers or signals) in the body", c: .}
        else
          ({path, line, side: (.side // "RIGHT"), body}
            + (if .start_line == null then {} else {start_line, start_side: (.start_side // .side // "RIGHT")} end)) as $c
          | if ($c | comment_in_diff($m)) then {keep: $c}
            else {drop: "line \(.line) (\($c.side)) of \(.path) is outside the diff", c: .}
            end
        end)
    | {kept: [.[] | select(.keep) | .keep], dropped: [.[] | select(.drop) | {reason: .drop, path: (.c.path? // null), line: (.c.line? // null)}]}' "$1"
}

# style_warnings <review.md> <kept comments json file>
style_warnings() {
  local phrase
  if grep -q $'\xe2\x80\x94' "$1" || jq -r '.[].body' "$2" | grep -q $'\xe2\x80\x94'; then
    echo "em dashes in the review or comments (comment-style.md)"
  fi
  while IFS= read -r phrase; do
    if jq -r '.[].body' "$2" | grep -qiF "$phrase"; then
      echo "banned phrase in a comment: \"$phrase\""
    fi
  done <<<"$BANNED_PHRASES"
  return 0
}

# save_one <run dir> <slug>: prints one result object (JSON).
save_one() {
  local run_dir="$1" slug="$2" ctx task raw tmp repo number gd date_dir home rel_md rel_cm warnings err
  ctx="$run_dir/ctx/$slug"
  task="$ctx/task.json"
  raw="$ctx/output.raw"
  [ -f "$task" ] || { jq -cn --arg s "$slug" '{slug: $s, status: "rejected", reason: "no task.json"}'; return 0; }
  if [ ! -s "$raw" ]; then
    jq -c '{pr, slug, status: "missing", reason: "the reviewer delivered no report (nothing captured)"}' "$task"
    return 0
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-save.XXXXXX")" || return 1

  reject() {
    jq -c --arg r "$1" '{pr, slug, status: "rejected", reason: $r}' "$task"
    rm -rf "$tmp"
  }
  # The report itself broke the contract: move it aside, because capture.sh
  # keeps the first report it sees and a retried reviewer must get through.
  reject_report() {
    mv -f "$raw" "$ctx/output.rejected.raw" 2>/dev/null || true
    reject "$1"
  }

  if ! err="$(split_report "$raw" "$(jq -r .nonce "$task")" "$tmp" 2>&1)"; then
    [ -n "$err" ] || err="the report does not follow the output contract"
    reject_report "$err"
    return 0
  fi
  if ! err="$(check_summary "$tmp/summary.json" "$task" 2>&1 >"$tmp/summary.norm.json")"; then
    reject_report "$(printf '%s' "$err" | sed -e 's/^jq: error ([^)]*): //' | head -1)"
    return 0
  fi
  if ! err="$(check_review "$tmp/review.md" "$tmp/summary.norm.json" 2>&1 >"$tmp/review-warnings.txt")"; then
    reject_report "$(printf '%s' "$err" | sed -e 's/^jq: error ([^)]*): //' | head -1)"
    return 0
  fi

  repo="$(jq -r '.pr | split("#")[0]' "$task")"
  number="$(jq -r '.pr | split("#")[1]' "$task")"
  gd="$(repo_git_dir "$repo")" || { reject "no cached clone for $repo"; return 0; }
  if ! diff_map "$gd" "$(jq -r .merge_base "$task")" "$(jq -r .head_sha "$task")" >"$tmp/map.json"; then
    reject "couldn't compute the PR diff to check comment lines"
    return 0
  fi
  if ! err="$(check_comments "$tmp/comments.json" "$tmp/map.json" 2>&1 >"$tmp/comments.checked.json")"; then
    reject_report "$(printf '%s' "$err" | sed -e 's/^jq: error ([^)]*): //' | head -1)"
    return 0
  fi
  jq '.kept' "$tmp/comments.checked.json" >"$tmp/comments.kept.json"

  {
    cat "$tmp/review-warnings.txt"
    jq -r '.dropped[] | "dropped a comment: \(.reason)"' "$tmp/comments.checked.json"
    style_warnings "$tmp/review.md" "$tmp/comments.kept.json"
  } >"$tmp/warnings.txt"
  warnings="$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$tmp/warnings.txt")"

  # reviews/<date>/ is two levels above <run-dir> (reviews/<date>/.run/<run>).
  home="$(resolve_path "$(quill_home)")"
  date_dir="$(resolve_path "$run_dir/../..")"
  path_within "$date_dir" "$home/reviews" || { reject "the run directory isn't inside $home/reviews"; return 0; }
  write_atomic "$date_dir/$slug.md" <"$tmp/review.md"
  write_atomic "$date_dir/$slug.comments.json" <"$tmp/comments.kept.json"
  rel_md="${date_dir#"$home"/}/$slug.md"
  rel_cm="${date_dir#"$home"/}/$slug.comments.json"

  update_state "$home" "$tmp/summary.norm.json" "$rel_md" "$rel_cm" "$(basename "$run_dir")" "$warnings"
  mark_reviewed "$repo" "$number" "$(jq -r .head_sha "$task")"

  jq -c --arg md "$rel_md" --arg cm "$rel_cm" --argjson w "$warnings" \
    --argjson kept "$(jq length "$tmp/comments.kept.json")" \
    '{pr, slug: ($md | split("/") | last | rtrimstr(".md")), status: "saved", verdict, effort,
      reviewFile: $md, commentsFile: $cm, comments: $kept, warnings: $w}' "$tmp/summary.norm.json"
  rm -rf "$tmp"
}

# update_state <home> <summary file> <review file> <comments file> <run id> <warnings json>
update_state() {
  local home="$1" state="$1/state.json" lock="$1/.state.lock"
  lock_acquire "$lock" 30
  [ -f "$state" ] || printf '{"version": 1, "prs": {}}\n' >"$state"
  if ! jq --slurpfile s "$2" --arg md "$3" --arg cm "$4" --arg run "$5" --argjson w "$6" --arg at "$(now_iso)" '
      $s[0] as $sum
      | .prs[$sum.pr] = ((.prs[$sum.pr] // {})
          | if .reviewedHeadSha != $sum.head then del(.posted) else . end
          | . + {reviewedHeadSha: $sum.head, reviewedAt: $at, reviewFile: $md, commentsFile: $cm, run: $run,
                 warnings: $w}
          + ($sum | {verdict, reason, effort, fixes, lowEffort, previousFindings, aiDirectedText, blocking}))' \
    "$state" >"$state.tmp.$$"; then
    rm -f "$state.tmp.$$"
    lock_release "$lock"
    die "couldn't update $state"
  fi
  mv -f "$state.tmp.$$" "$state"
  lock_release "$lock"
}

main() {
  local run_dir="" slug="" all=false slugs results line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
      --slug) slug="${2:-}"; shift 2 || usage ;;
      --all) all=true; shift ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  [ -n "$slug" ] || [ "$all" = true ] || usage
  require_cmd git jq
  run_dir="$(require_run_dir "$run_dir")" || exit 1
  [ -d "$run_dir/ctx" ] || die "no context bundles in $run_dir (run prepare.sh first)"

  if [ "$all" = true ]; then
    [ -f "$run_dir/dispatch.json" ] || die "no dispatch.json in $run_dir"
    slugs="$(jq -r '.prs[] | select(.error | not) | .slug' "$run_dir/dispatch.json")"
  else
    case "$slug" in
      */* | .* | '') die "not a PR slug: $slug" 64 ;;
    esac
    slugs="$slug"
  fi

  results="$run_dir/.results-$$"
  : >"$results"
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if ! line="$(save_one "$run_dir" "$slug")"; then
      line="$(jq -cn --arg s "$slug" '{slug: $s, status: "rejected", reason: "internal error while saving"}')"
    fi
    printf '%s\n' "$line" >>"$results"
  done <<<"$slugs"

  jq -s . "$results" >"$results.this"
  # Merge with earlier results for this run; a re-saved PR replaces its entry
  # (group_by is stable, so the later one is last). Saves for different PRs
  # can run in parallel, so the read-merge-write happens under a lock.
  lock_acquire "$run_dir/.results.lock" 30
  if [ -f "$run_dir/results.json" ]; then
    jq -s '(.[0] + .[1]) | group_by(.slug) | map(last)' "$run_dir/results.json" "$results.this" >"$results.merged"
  else
    cp "$results.this" "$results.merged"
  fi
  write_atomic "$run_dir/results.json" <"$results.merged"
  lock_release "$run_dir/.results.lock"

  jq -r '.[] | if .status == "saved" then
      "saved \(.pr): \(.verdict) (\(.effort)), \(.comments) comment(s)"
      + (if (.warnings | length) > 0 then "; warnings: " + (.warnings | join("; ")) else "" end)
    else "\(.status) \(.pr // .slug): \(.reason)" end' "$results.this"
  rm -f "$results" "$results.this" "$results.merged"
}

main "$@"
