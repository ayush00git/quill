#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# digest.sh: what matters in this run's reviews, short enough for the chat.
#
#   digest.sh --run-dir <dir> [--max <N>]
#
# For each review saved in this run (<run-dir>/results.json), most severe
# verdict first, prints:
#   - the PR, its title and header facts (author, size, CI, head)
#   - the verdict, effort, inline comment count and review scope (full, or
#     only the changes since the last reviewed commit)
#   - the decisive reason, from state.json
#   - the Attention and Previous findings lead lines, when present
#   - every Blocking, Should fix and Question item's headline, numbered as
#     in the review, and how many nits there are
#   - the review file
# Expected answers, contributor signals and the suggested reply stay in the
# review file. Text comes from the reviews (which read untrusted PR content):
# control characters are removed and each line is capped at 220 characters.
# At most --max reviews are shown (default 5); the rest are counted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

# sections <review.md>: one "<kind>\t<text>" line per thing the digest uses.
# kinds: title, facts, verdict, attention, previous, blocking, should,
# question, nit.
sections() {
  awk '
    function lead(s) { sub(/^[ \t]+/, "", s); return s }
    !title && /^# / { print "title\t" substr($0, 3); title = 1; facts = 1; next }
    facts && NF { print "facts\t" $0; facts = 0; next }
    /^## Verdict: / { print "verdict\t" substr($0, 13); sec = ""; next }
    /^## Attention/ { sec = "attention"; first = 1; next }
    /^## Previous findings/ { sec = "previous"; first = 1; next }
    /^## Blocking/ { sec = "blocking"; next }
    /^## Should fix/ { sec = "should"; next }
    /^## Questions for the author/ { sec = "question"; next }
    /^## Nits/ { sec = "nit"; next }
    /^## / { sec = ""; next }
    (sec == "attention" || sec == "previous") && first && NF && $0 != "None." {
      print sec "\t" lead($0); first = 0; next
    }
    (sec == "blocking" || sec == "should" || sec == "question" || sec == "nit") && /^[0-9]+\. / {
      print sec "\t" $0
    }
  ' "$1"
}

main() {
  local run_dir="" max=5 home results item slug pr md shown_md task state_file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
      --max)
        max="${2:-}"
        case "$max" in '' | 0* | *[!0123456789]*) die "--max wants a positive number" 64 ;; esac
        shift 2
        ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  require_cmd jq
  run_dir="$(require_run_dir "$run_dir")" || exit 1
  results="$run_dir/results.json"
  [ -f "$results" ] || exit 0
  home="$(quill_home)"
  state_file="$home/state.json"
  [ -f "$state_file" ] || state_file="$QUILL_LIB_DIR/empty-state.json"

  local tmp n=0 shown=0 total
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-digest.XXXXXX")" || exit 1
  # Saved reviews, most severe verdict first, then in the order they were saved.
  jq -c '[to_entries[] | .value + {i: .key} | select(.status == "saved")]
    | sort_by(({request_changes: 0, comment: 1, approve: 2}[.verdict] // 3), .i) | .[]' "$results" >"$tmp/saved"
  total="$(wc -l <"$tmp/saved" | tr -d ' ')"

  while IFS= read -r item; do
    n=$((n + 1))
    [ "$n" -le "$max" ] || continue
    slug="$(jq -r .slug <<<"$item")"
    pr="$(jq -r .pr <<<"$item")"
    case "$slug" in */* | .* | *..* | '') continue ;; esac
    md="$home/$(jq -r .reviewFile <<<"$item")"
    path_within "$md" "$home/reviews" || continue
    [ -f "$md" ] || continue
    case "$md" in "$HOME"/*) shown_md="~/${md#"$HOME"/}" ;; *) shown_md="$md" ;; esac
    task="$run_dir/ctx/$slug/task.json"
    [ -f "$task" ] || task="$QUILL_LIB_DIR/empty-results.json"
    sections "$md" >"$tmp/sections"
    [ "$shown" -eq 0 ] || printf '\n'
    jq -r -R -s --argjson r "$item" --arg pr "$pr" --arg md "$shown_md" \
      --slurpfile st "$state_file" --slurpfile t "$task" '
      def clean: gsub("\t"; " ") | gsub("[[:cntrl:]]"; "") | if length > 220 then .[0:217] + "..." else . end;
      def strip_label: sub("^(?<n>[0-9]+\\. )(issue|suggestion|question|nitpick|todo|chore|praise|thought|note)( \\([^)]*\\))?: "; "\(.n)");
      def items($k): [.[] | select(.k == $k) | .v | strip_label | clean];
      [split("\n")[] | select(length > 0) | split("\t") | {k: .[0], v: (.[1:] | join("\t"))}]
      | (first(.[] | select(.k == "title") | .v | clean) // $pr) as $title
      | (first(.[] | select(.k == "facts") | .v | clean) // "") as $facts
      | (first(.[] | select(.k == "verdict") | .v | clean) // $r.verdict) as $verdict
      | (($st[0].prs[$pr].reason // "") | clean) as $why
      | ($t[0] | if type != "object" then "" elif .mode == "incremental" then "changes since \((.last_reviewed // "")[0:7]) only"
          elif .mode == "range-diff" then "range-diff against \((.last_reviewed // "")[0:7])"
          elif .mode == "full" then "full review" else "" end) as $scope
      | items("blocking") as $blocking
      | items("should") as $should
      | items("question") as $questions
      | (items("nit") | length) as $nits
      # Markdown blocks, one blank line apart (a list starting at 2 cannot
      # follow a paragraph line directly).
      | def block(lines): if (lines | length) > 0 then (lines | join("\n")) else empty end;
      [ block(["### \($title)"] + (if $facts != "" then [$facts] else [] end)),
        block(["**\($verdict)** | effort \($r.effort // "?") | \($r.comments // 0) inline comment(s)"
               + (if $scope != "" then " | \($scope)" else "" end)]),
        block(if $why != "" then [$why] else [] end),
        block(items("attention") | map("**Attention:** \(.)")),
        block(items("previous") | map("**Previous findings:** \(.)")),
        (if ($blocking | length) == 0 then "**Blocking:** none" else "**Blocking**", block($blocking) end),
        (if ($should | length) > 0 then "**Should fix**", block($should) else empty end),
        (if ($questions | length) > 0 then "**Questions for the author**", block($questions) else empty end),
        ((if $nits > 0 then "\($nits) nit(s) | " else "" end) + "Review: \($md)")
      ] | join("\n\n")' "$tmp/sections"
    shown=$((shown + 1))
  done <"$tmp/saved"
  if [ "$total" -gt "$shown" ]; then
    printf '\n%d more review(s) in QUEUE.md.\n' "$((total - shown))"
  fi
  rm -rf "$tmp"
}

main "$@"
