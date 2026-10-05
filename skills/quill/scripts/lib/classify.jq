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

# A review request that reaches me: by name, or through a team while the PR
# is in my review-requested search results (GitHub doesn't say which teams
# I'm on, so a team request alone isn't proof).
def _request_for_me($me; $requested_now):
  .type == "review_requested"
  and ((.reviewer.user // null) == $me or ((.reviewer.team // null) != null and $requested_now));

def _skip($why): . + {court: "skip", courtReason: $why, reReview: false, waitingSince: null};

def classify($me; $cfg; $state; $force):
  (.repo + "#" + (.number | tostring)) as $key
  | ($state.prs[$key] // null) as $qs
  | ([.myReviews[]? | select(.state != "DISMISSED")] | last) as $last
  | ((.sources | index("review-requested")) != null) as $requested_now
  | . + {lastMyReview: $last, quillState: $qs}
  | (
      if (.sources | index("explicit")) then
        # Asked for by name: reviewed whatever the queue's filters would say
        # (closed, merged, draft, my own, a bot's, approved). post.sh still
        # never posts to a PR that isn't open.
        . + {court: "mine",
             courtReason: ("requested on the command line"
               + (if .state == "OPEN" then "" else " (\(.state | ascii_downcase))" end)),
             reReview: ($last != null), waitingSince: .createdAt}
      elif .author.login == $me then _skip("my own PR")
      elif .state != "OPEN" then _skip("closed or merged")
      elif .isDraft then _skip("draft")
      elif (if ($cfg | has("skipBots")) then $cfg.skipBots else true end) and .author.isBot then _skip("bot author")
      elif (.author.login as $a | ($cfg.skipAuthors // []) | index($a)) then _skip("author in skipAuthors")
      elif $last == null then
        # waiting since the PR opened or I was (last) asked to review, whichever is later
        . + {court: "mine", courtReason: "not reviewed yet", reReview: false,
             waitingSince: ([.createdAt] + [.timeline[]? | select(_request_for_me($me; $requested_now)) | .at] | max)}
      else
        $last.submittedAt as $t
        | .author.login as $author
        | [.timeline[] | select(_after($t))] as $since
        # Pushed = the head moved off the commit I reviewed, or a force-push since.
        # Commit dates are set by the author (they can be back- or forward-dated),
        # so they only date the push for waitingSince, never decide it.
        | ([$since[] | select(.type == "force_push")] | first) as $force_push
        | (.head.sha != $last.commit or $force_push != null) as $pushed
        | (if $pushed then ([$since[] | select(.type == "commit" or .type == "force_push")] | first) else null end) as $push_event
        | ([$since[] | select((.type == "comment" or .type == "review") and .by == $author)] | first) as $reply
        | ([$since[] | select(_request_for_me($me; $requested_now))] | first) as $rerequest
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
