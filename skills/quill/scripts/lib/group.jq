# SPDX-License-Identifier: Apache-2.0
#
# group.jq: a jq module. Competing PRs for the same issue show up side by side
# in QUEUE.md. Two PRs in a repo belong together when they share an issue key:
#   #N        a linked (closing) issue, "fixes #N"-style keywords, or a URL to
#             the repo's issue N
#   KEY-123   a JIRA key whose project is the repo's (config jiraProjects
#             {"owner/repo": ["KEY", ...]}, default: the repo name upper-cased
#             without "incubator-" and punctuation), or any [KEY-123] in the
#             title
# Mentions like "see #10" don't count; they link related work, not rivals.

def jira_projects($cfg):
  .repo as $r
  | ($cfg.jiraProjects[$r] //
      [$r | split("/")[1] | ascii_upcase | sub("^INCUBATOR-"; "") | gsub("[^A-Z0-9]"; "")]);

# issue_keys($cfg): the item's keys, sorted and unique.
def issue_keys($cfg):
  .repo as $repo
  | jira_projects($cfg) as $projects
  | ((.title // "") + "\n" + (.body // "")) as $text
  | (
      [(.linkedIssues // [])[] | select(.repo == $repo) | "#\(.number)"]
      + [$text | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s*:?\\s+#([0-9]+)\\b") | "#" + .[0]]
      + [$text | scan("https://github\\.com/" + ($repo | gsub("\\."; "\\.")) + "/issues/([0-9]+)\\b") | "#" + .[0]]
      + [$text | scan("\\b([A-Z][A-Z0-9_]+)-([0-9]+)\\b") | select(.[0] as $p | $projects | index($p)) | "\(.[0])-\(.[1])"]
      + [(.title // "") | scan("\\[([A-Z][A-Z0-9_]+-[0-9]+)\\]") | .[0]]
    )
  | unique;

# group_items($cfg): over the array of queue items, adds issueKeys to every
# item, and group (the shared key) plus groupMembers (the PR numbers) to items
# that share a key with another PR in the same repo.
def group_items($cfg):
  map(. + {issueKeys: issue_keys($cfg)})
  | ([.[] | . as $i | .issueKeys[] | {key: "\($i.repo) \(.)", number: $i.number}]
      | group_by(.key)
      | map(select(length > 1) | {key: .[0].key, members: (map(.number) | unique)})
      | map(select(.members | length > 1))) as $groups
  | map(. as $i
      | ([$groups[] | select(.key | startswith($i.repo + " ")) | select(.members | index($i.number))] | sort_by([(.key | test(" #")), .key]) | first) as $g
      | if $g == null then . else . + {group: ($g.key | sub("^[^ ]+ "; "")), groupMembers: $g.members} end);
