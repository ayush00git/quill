# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Discovery: which open PRs might be waiting on me. Each function prints a
# JSON array of candidates: [{repo, number, url, sources: [...]}].
# Requires lib/common.sh.

# GitHub search returns at most 1000 results per query; ask for all of them
# (gh defaults to 30, which would silently truncate the queue).
QUILL_SEARCH_LIMIT="${QUILL_SEARCH_LIMIT:-1000}"

# viewer_login: the authenticated GitHub login.
viewer_login() {
  local login
  login="$(gh api --method GET user --jq .login)" || die "gh isn't authenticated (run: gh auth login)"
  [ -n "$login" ] || die "couldn't read the GitHub login from gh"
  printf '%s\n' "$login"
}

# _search_candidates <source tag> <gh search prs flags...>
_search_candidates() {
  local source="$1"
  shift
  gh search prs "$@" --state=open --draft=false --archived=false \
    --limit "$QUILL_SEARCH_LIMIT" --json number,repository,url |
    jq --arg s "$source" '[.[] | {repo: .repository.nameWithOwner, number, url, sources: [$s]}]'
}

# discover_requested: PRs requesting my review, directly or through a team.
discover_requested() {
  _search_candidates review-requested --review-requested=@me
}

# discover_reviewed: open PRs I've already reviewed. GitHub drops me from the
# review requests once I review, so re-reviews only show up here.
discover_reviewed() {
  _search_candidates reviewed-by --reviewed-by=@me
}

# merge_candidates <json array>...: one entry per repo#number, sources merged,
# sorted by repo then number.
merge_candidates() {
  printf '%s\n' "$@" | jq -s '
    add // []
    | group_by([.repo, .number])
    | map(.[0] + {sources: (map(.sources[]) | unique)})
    | sort_by(.repo, .number)'
}
