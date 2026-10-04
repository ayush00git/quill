# SPDX-License-Identifier: Apache-2.0
#
# render.jq: a jq module that turns the queue, quill's state and this run's
# results into QUEUE.md. render($state; $results) runs on queue.json.

# cell: text that is safe inside a markdown table cell. PR titles and
# reasons come from PR authors or the reviewer: no pipes, no line breaks,
# bounded length.
def cell($max):
  tostring
  | gsub("[\r\n\t]+"; " ")
  | gsub("\\|"; "\\|")
  | if length > $max then .[0:$max - 3] + "..." else . end;

def ago($now):
  if . == null then "?" else
    (($now | fromdateiso8601) - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) as $s
    | if $s < 3600 then "<1h"
      elif $s < 86400 then "\($s / 3600 | floor)h"
      else "\($s / 86400 | floor)d" end
  end;

def verdict_text:
  if . == "request_changes" then "Request changes"
  elif . == "approve" then "Approve"
  elif . == "comment" then "Comment (needs answers)"
  else "not reviewed" end;

def first_time:
  (.author.association == "FIRST_TIME_CONTRIBUTOR" or .author.association == "FIRST_TIMER"
   or (.authorHistory != null and .authorHistory.merged == 0));

def author_cell:
  "@\(.author.login) (\(.author.association // "?"), "
  + (if first_time then "first-time"
     elif .authorHistory == null then "history unknown"
     else "\(.authorHistory.merged) merged" end)
  + ")";

def size_cell:
  (.effectiveSize // {additions: .size.additions, deletions: .size.deletions, partial: false}) as $e
  | "+\($e.additions)/-\($e.deletions)" + (if $e.partial then "*" else "" end);

def security_like:
  ([.labels[]? | ascii_downcase | select(test("security|regression|vulnerab|cve"))] | length > 0)
  or ((.title // "") | test("CVE-[0-9]{4}-[0-9]+|(?i)\\bsecurity\\b|(?i)\\bregression\\b"));

# The draft quill holds for an item's current head, or null.
def draft($state):
  ($state.prs["\(.repo)#\(.number)"] // null) as $d
  | if $d != null and $d.reviewedHeadSha == .head.sha then $d else null end;

# tier: 1 security fix or regression, 2 re-review where my feedback was
# addressed, 3 small CI-green approvals, 4 everything else, 5 low effort.
def tier($d):
  if $d != null and $d.lowEffort then 5
  elif ($d != null and ($d.fixes == "security" or $d.fixes == "regression")) or security_like then 1
  elif .reReview and $d != null and $d.previousFindings == "addressed" then 2
  elif .sizeClass == "small" and .ci.state == "passing" and $d != null and $d.verdict == "approve" then 3
  else 4 end;

# order: rank by tier then longest waiting, then pull each group's members
# up to its best-ranked member.
def ranked($state):
  map(. as $i | draft($state) as $d | . + {_draft: $d, _tier: tier($d)})
  | sort_by(._tier, (.waitingSince // "9999"), .repo, .number)
  | . as $sorted
  | reduce range(0; length) as $k ([];
      $sorted[$k] as $it
      | if any(.[]; .repo == $it.repo and .number == $it.number) then .
        elif $it.group == null then . + [$it]
        else . + [$sorted[] | select(.repo == $it.repo and .group == $it.group)] end);

def review_link($d):
  if $d == null or $d.reviewFile == null then "" else
    "[review](../\($d.reviewFile | sub("^reviews/"; "")))" end;

def table_row($n; $now; $results):
  ._draft as $d
  | ($results | map(select(.pr == "\($n.repo)#\($n.number)")) | last) as $r
  | "| \(._rank) | [\(.repo)#\(.number)](\(.url)) \(.title | cell(60))"
    + (if .group != null then " (\(.group | cell(20)))" else "" end)
    + " | \(author_cell | cell(60)) | \(size_cell) | \(.ci.state // "?") | \(.waitingSince | ago($now))"
    + " | \(if $d != null then ($d.verdict | verdict_text) else "not reviewed" end)"
    + " | \(if $d != null then ($d.reason | cell(120))
             elif $r != null and $r.reason != null then ($r.status + ": " + $r.reason | cell(120))
             else "" end)"
    + " | \(if $d != null then $d.effort else "" end) | \(review_link($d)) |";

def render($state; $results):
  .generatedAt as $now
  | (.items | map(select(.court == "mine"))) as $mine
  | (.items | map(select(.court == "waiting_on_author"))) as $waiting
  | ($mine | ranked($state)) as $r
  | ([$r[] | select(._tier < 5)] | to_entries | map(.value + {_rank: (.key + 1)})) as $main
  | ([$r[] | select(._tier == 5)]) as $low
  | [
      "# Review queue",
      "",
      "Generated \($now) for @\(.viewer). \($main | length) PR(s) in your court, \($low | length) likely low-effort, \($waiting | length) waiting on the author, \([.items[] | select(.court == "skip")] | length) skipped.",
      "",
      "Order: security fixes and regressions, re-reviews where your feedback was addressed, small CI-green approvals, then the longest waiting. Competing PRs for one issue sit together. Size leaves out generated, lock and vendored files (* = partial file list).",
      "",
      "| # | PR | Author | Size | CI | Waiting | Verdict | Why | Effort | Review |",
      "|---|---|---|---|---|---|---|---|---|---|",
      ($main[] | table_row(.; $now; $results)),
      "",
      "## Waiting on author",
      "",
      (if ($waiting | length) == 0 then "None." else
        ("| PR | Author | My last review | Since |", "|---|---|---|---|",
         ($waiting[] | "| [\(.repo)#\(.number)](\(.url)) \(.title | cell(60)) | \(author_cell | cell(60)) | \(.lastMyReview.state // "?" | ascii_downcase | gsub("_"; " ")) | \(.lastMyReview.submittedAt | ago($now)) |"))
       end),
      "",
      "## Likely low-effort",
      "",
      (if ($low | length) == 0 then "None." else
        ("| PR | Author | Waiting | Why | Review |", "|---|---|---|---|---|",
         ($low[] | ._draft as $d | "| [\(.repo)#\(.number)](\(.url)) \(.title | cell(60)) | \(author_cell | cell(60)) | \(.waitingSince | ago($now)) | \($d.reason | cell(120)) | \(review_link($d)) |"))
       end)
    ]
  | join("\n") + "\n";
