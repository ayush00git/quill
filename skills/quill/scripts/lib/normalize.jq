# SPDX-License-Identifier: Apache-2.0
#
# normalize.jq: a jq module. `normalize` turns one GraphQL PullRequest
# (pr-fields.graphql) into the fields quill keeps on a queue item.

def ci_state:
  (.commits.nodes[0].commit // {}) as $c
  | ($c.statusCheckRollup.state // null) as $rollup
  | ([($c.checkSuites.nodes // [])[] | select(.conclusion == "ACTION_REQUIRED")] | length > 0) as $awaiting
  | {
      state: (
        if $awaiting then "not run (awaiting approval)"
        elif $rollup == null then "not run"
        elif $rollup == "SUCCESS" then "passing"
        elif ($rollup == "FAILURE" or $rollup == "ERROR") then "failing"
        else "pending"
        end),
      rollup: $rollup,
      checks: ($c.statusCheckRollup.contexts.totalCount // 0),
      awaitingApproval: $awaiting
    };

def requested_reviewer:
  if . == null then null
  elif .__typename == "Team" then {team: .slug}
  else {user: .login}
  end;

def normalize:
  {
    title,
    body: (.body // ""),
    url,
    state,
    isDraft,
    createdAt,
    updatedAt,
    author: {
      login: (.author.login // "ghost"),
      isBot: ((.author.__typename // "") == "Bot" or ((.author.login // "") | endswith("[bot]"))),
      association: .authorAssociation
    },
    base: {ref: .baseRefName, sha: .baseRefOid},
    head: {sha: .headRefOid, repo: (.headRepository.nameWithOwner // null)},
    size: {additions, deletions, files: .changedFiles},
    files: [.files.nodes[] | {path, additions, deletions, changeType}],
    filesTruncated: (.files.totalCount > (.files.nodes | length)),
    labels: [.labels.nodes[].name],
    linkedIssues: [.closingIssuesReferences.nodes[] | {repo: .repository.nameWithOwner, number}],
    ci: ci_state,
    mergeable,
    mergeStateStatus,
    reviewDecision,
    myReviews: [.myReviews.nodes[] | select(.state != "PENDING")
      | {state, submittedAt, commit: (.commit.oid // null)}] | sort_by(.submittedAt),
    myPendingReview: ([.myReviews.nodes[] | select(.state == "PENDING")] | length > 0),
    reviewRequests: [.reviewRequests.nodes[].requestedReviewer | requested_reviewer | select(. != null)],
    timeline: [.timelineItems.nodes[] |
      if .__typename == "PullRequestCommit" then {type: "commit", sha: .commit.oid, at: .commit.committedDate}
      elif .__typename == "HeadRefForcePushedEvent" then {type: "force_push", at: .createdAt}
      elif .__typename == "IssueComment" then {type: "comment", by: (.author.login // "ghost"), at: .createdAt}
      elif .__typename == "PullRequestReview" then {type: "review", by: (.author.login // "ghost"), state, at: .submittedAt}
      elif .__typename == "ReviewRequestedEvent" then {type: "review_requested", reviewer: (.requestedReviewer | requested_reviewer), at: .createdAt}
      else empty
      end]
  };
