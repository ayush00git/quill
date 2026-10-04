# SPDX-License-Identifier: Apache-2.0
#
# classify.jq: a jq module. `classify($me; $cfg; $state; $force)` decides
# whose court a normalized queue item is in and whether quill should review
# it this run.
#
# Adds to the item:
#   court        "mine" | "waiting_on_author" | "skip"
#   courtReason  why (shown in QUEUE.md and the run summary)
#   reReview     true when I reviewed before and something changed since
#   lastMyReview my latest submitted review, or null
#   waitingSince when the ball came into my court (ISO time)
#   quillState   this PR's entry in state.json, or null
#   needsReview  court is mine and the head moved since quill's last draft
#                (or --force)

def _after($t): (.at // "") > $t;

def _reviewer_is_me($me):
  (.reviewer.user // null) == $me or (.reviewer.team // null) != null;

def _skip($why): . + {court: "skip", courtReason: $why, reReview: false, waitingSince: null};

def classify($me; $cfg; $state; $force):
  (.repo + "#" + (.number | tostring)) as $key
  | ($state.prs[$key] // null) as $qs
  | ([.myReviews[]? | select(.state != "DISMISSED")] | last) as $last
  | . + {lastMyReview: $last, quillState: $qs}
  | (
      if .state != "OPEN" then _skip("closed or merged")
      elif .author.login == $me then _skip("my own PR")
      elif (.sources | index("explicit")) then
        . + {court: "mine", courtReason: "requested on the command line", reReview: ($last != null), waitingSince: .createdAt}
      elif .isDraft then _skip("draft")
      elif (if ($cfg | has("skipBots")) then $cfg.skipBots else true end) and .author.isBot then _skip("bot author")
      elif (.author.login as $a | ($cfg.skipAuthors // []) | index($a)) then _skip("author in skipAuthors")
      elif $last == null then
        . + {court: "mine", courtReason: "not reviewed yet", reReview: false, waitingSince: .createdAt}
      else
        $last.submittedAt as $t
        | .author.login as $author
        | [.timeline[] | select(_after($t))] as $since
        | ([$since[] | select(.type == "commit" or .type == "force_push")] | first) as $push_event
        | (.head.sha != $last.commit or $push_event != null) as $pushed
        | ([$since[] | select((.type == "comment" or .type == "review") and .by == $author)] | first) as $reply
        | ([$since[] | select(.type == "review_requested" and _reviewer_is_me($me))] | first) as $rerequest
        | ([$push_event, $reply, $rerequest] | map(select(. != null) | .at) | sort | first) as $first_activity
        | if $pushed or $reply != null or $rerequest != null then
            . + {
              court: "mine",
              courtReason: (
                [ (if $pushed then "author pushed" else empty end),
                  (if $reply != null then "author replied" else empty end),
                  (if $rerequest != null then "review re-requested" else empty end)
                ] | join(", ") | "re-review: " + .),
              reReview: true,
              waitingSince: ($first_activity // .updatedAt)
            }
          elif $last.state == "APPROVED" then _skip("approved, nothing new since")
          else
            . + {court: "waiting_on_author", courtReason: "my \($last.state | ascii_downcase | gsub("_"; " ")) review has no reply yet",
                 reReview: false, waitingSince: null}
          end
      end
    )
  | . + {needsReview: (.court == "mine" and ($force or ($qs.reviewedHeadSha // null) != .head.sha))};
