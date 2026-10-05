#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# digest.sh: what matters in this run's reviews, short enough for the chat.
#
#   digest.sh --run-dir <dir> [--max <N>]
#
# For each review saved in this run (<run-dir>/results.json), most severe
# verdict first, prints:
#   - the PR and its title, and the decisive reason (state.json)
#   - the Attention and Previous findings lead lines, when present
#   - every Blocking and Should fix item, numbered as in the review, as its
#     first sentence without the label or file:line references
#   - the Questions for the author the same way, only when the verdict is
#     "Comment (needs answers)"
#   - up to 3 suggested comments, most severe first: each drafted inline
#     comment's summary (or the start of its body), without the label
#   - how many nits there are, and the review file
# Then, outside headless runs, it offers to post the drafts of open PRs as
# a pending review. Expected answers, contributor signals and the suggested
# reply stay in the review file. Text comes from the reviews (which read
# untrusted PR content): control characters are removed and lines capped.
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
  local run_dir="" max=5 home results item slug pr md cm shown_md state_file pr_state
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

  local tmp n=0 shown=0 total postable=""
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
    # shellcheck disable=SC2088 # a literal ~ for display
    case "$md" in "$HOME"/*) shown_md="~/${md#"$HOME"/}" ;; *) shown_md="$md" ;; esac
    cm="$home/$(jq -r '.commentsFile // ""' <<<"$item")"
    if ! path_within "$cm" "$home/reviews" || [ ! -f "$cm" ]; then cm="$QUILL_LIB_DIR/empty-results.json"; fi
    sections "$md" >"$tmp/sections"
    [ "$shown" -eq 0 ] || printf '\n'
    jq -r -R -s --argjson r "$item" --arg pr "$pr" --arg md "$shown_md" \
      --slurpfile st "$state_file" --slurpfile cm "$cm" '
      def cap($n): gsub("\t"; " ") | gsub("[[:cntrl:]]"; "") | if length > $n then .[0:$n - 3] + "..." else . end;
      def label_re: "(issue|suggestion|question|nitpick|todo|chore|praise|thought|note)( \\([^)]*\\))?: ";
      def unlabel: sub("^" + label_re; "");
      # No file:line references: a leading `path:line`: goes, and path:line
      # inside the text keeps only the path.
      def no_refs: sub("^(`[^`]+`(, )?)+:\\s+"; "")
        | gsub("`(?<p>[^`\\s]+):[0-9]+(-[0-9]+)?`"; "`\(.p)`")
        | gsub("(?<f>[A-Za-z0-9_./-]+\\.[A-Za-z][A-Za-z0-9]*):[0-9]+(-[0-9]+)?"; "\(.f)")
        | gsub(" ?\\(L[0-9]+(-[0-9]+)?\\)"; "");
      def first_sentence: (capture("^(?<s>.*?[.?!])(\\s|$)") | .s) // .;
      # Whole sentences, as many as fit in $n characters, in order.
      def fit($n): [scan("[^ ].*?[.?!](?=\\s|$)|[^ ].+$")]
        | reduce .[] as $x ({t: "", full: false};
            if .full then . elif .t == "" then .t = $x
            elif (.t + " " + $x | length) <= $n then .t += " " + $x else .full = true end)
        | .t | cap($n);
      def upcase_first: (.[0:1] | ascii_upcase) + .[1:];
      def item: capture("^(?<n>[0-9]+)\\. (?<t>.*)$") as $m
        | "\($m.n). \($m.t | unlabel | no_refs | first_sentence | upcase_first | cap(220))";
      def items($k): [.[] | select(.k == $k) | .v | item];
      def leads($k): [.[] | select(.k == $k) | .v | no_refs | cap(220)];
      # A comment body as one paragraph: no code blocks, list items as sentences.
      def flat: gsub("```[^`]*```"; "") | gsub("\n\\s*[-*] "; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
      [split("\n")[] | select(length > 0) | split("\t") | {k: .[0], v: (.[1:] | join("\t"))}]
      | (first(.[] | select(.k == "title") | .v | cap(220)) // $pr) as $title
      | (($st[0].prs[$pr].reason // "") | cap(300)) as $why
      | items("blocking") as $blocking
      | items("should") as $should
      | (if $r.verdict == "comment" then items("question") else [] end) as $questions
      | ([.[] | select(.k == "nit")] | length) as $nits
      # Suggested comments: the drafted inline comments, most severe first.
      | ([($cm[0] | if type == "array" then .[] else empty end) | select(type == "object" and (.body | type) == "string")
          | (.body | capture("^(?<l>issue \\(blocking\\)|issue|suggestion|question|todo|nitpick)") | .l) as $l
          | {rank: ({"issue (blocking)": 0, issue: 1, suggestion: 2, question: 3, todo: 4, nitpick: 6}[$l // ""] // 5),
             text: (if (.summary | type) == "string" and (.summary | length) > 0 then .summary
                    else (.body | unlabel | flat | no_refs | upcase_first) end
                    | fit(300))}]
         | to_entries | sort_by(.value.rank, .key) | map(.value.text) | .[0:3]) as $suggested
      # Markdown blocks, one blank line apart (a list starting at 2 cannot
      # follow a paragraph line directly).
      | def block(lines): if (lines | length) > 0 then (lines | join("\n")) else empty end;
      [ "### \($title)",
        block(if $why != "" then [$why] else [] end),
        block(leads("attention") | map("**Attention:** \(.)")),
        block(leads("previous") | map("**Previous findings:** \(.)")),
        (if ($blocking | length) == 0 then "**Blocking:** none" else "**Blocking**", block($blocking) end),
        (if ($should | length) > 0 then "**Should fix**", block($should) else empty end),
        (if ($questions | length) > 0 then "**Questions for the author**", block($questions) else empty end),
        (if ($suggested | length) > 0 then "**Suggested comments**", block($suggested | map("- \(.)")) else empty end),
        ((if $nits > 0 then "\($nits) nit(s) | " else "" end) + "Review: \($md)")
      ] | join("\n\n")' "$tmp/sections"
    shown=$((shown + 1))
    # Postable: open on GitHub (as the queue saw it) with drafted comments.
    pr_state=""
    if [ -f "$run_dir/queue.json" ]; then
      pr_state="$(jq -r --arg pr "$pr" 'first(.items[] | select("\(.repo)#\(.number)" == $pr) | .state) // ""' \
        "$run_dir/queue.json")" || pr_state=""
    fi
    if [ "$pr_state" = OPEN ] && [ "$(jq -r '.comments // 0' <<<"$item")" -gt 0 ]; then
      postable="$postable $pr"
    fi
  done <"$tmp/saved"
  if [ "$total" -gt "$shown" ]; then
    printf '\n%d more review(s) in QUEUE.md.\n' "$((total - shown))"
  fi
  # Headless runs never post, so they never offer to.
  if [ -z "${QUILL_HEADLESS:-}" ] && [ -n "$postable" ]; then
    # shellcheck disable=SC2086 # split into PRs (owner/repo#N has no spaces or globs)
    set -- $postable
    if [ "$#" -eq 1 ]; then
      printf '\nWant me to add these as a pending review on GitHub? It holds all the drafted comments, and only you will see it until you submit it there. Reply **post** to go ahead.\n'
    else
      printf '\nWant me to add any of these as pending reviews on GitHub? Only you will see them until you submit them there. Reply **post** with the PR, for example **post %s**.\n' "$1"
    fi
  fi
  rm -rf "$tmp"
}

main "$@"
