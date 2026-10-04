# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Author history: how each PR author has fared in that repo before, for the
# QUEUE.md author column and the reviewer's contributor signals.
#   authorHistory: {merged, closedUnmerged, open,
#                   recent: [{number, merged, closedAt, reviews, changesRequested}]}
# One GraphQL request per batch of (repo, author) pairs, using search counts
# (GraphQL, not the REST search API, which allows only 30 requests a minute).
#
# Caveat: some ASF projects merge with scripts that close the PR instead of
# merging it on GitHub, so "merged" can undercount there.
#
# History is informational: if it can't be fetched, items get
# authorHistory: null and a warning, and the run goes on.
# Requires lib/common.sh.

QUILL_HISTORY_BATCH="${QUILL_HISTORY_BATCH:-10}"

# The rule for splicing a {repo, login} pair into a query (jq).
HISTORY_VALID_JQ='def valid: (.repo | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"))
  and ((.repo | split("/")[1]) as $n | $n != "." and $n != "..")
  and (.login | type == "string" and test("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"));'

# _history_query < pairs: the GraphQL document for a batch of
# [{repo, login}]. Both are validated before they are spliced in.
_history_query() {
  jq -r "$HISTORY_VALID_JQ"'
    if all(.[]; valid) | not then error("invalid repo or login in batch") else . end
    | "query {\n"
      + (to_entries | map(
          ("repo:\(.value.repo) is:pr author:\(.value.login)") as $q
          | "h\(.key)m: search(query: \"\($q) is:merged\", type: ISSUE, first: 0) { issueCount }\n"
          + "h\(.key)c: search(query: \"\($q) is:closed is:unmerged\", type: ISSUE, first: 0) { issueCount }\n"
          + "h\(.key)o: search(query: \"\($q) is:open\", type: ISSUE, first: 0) { issueCount }\n"
          + "h\(.key)r: search(query: \"\($q) is:closed sort:updated-desc\", type: ISSUE, first: 5) { nodes { ... on PullRequest { number merged closedAt reviews { totalCount } changesRequested: reviews(states: CHANGES_REQUESTED) { totalCount } } } }")
        | join("\n"))
      + "\n}"'
}

# add_author_history <queue.json>: adds authorHistory to the items in my court
# or waiting on the author (the ones QUEUE.md shows), in place.
add_author_history() {
  local queue="$1" tmp total i=0 n=0 query
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-history.XXXXXX")" || return 1
  jq -c '[.items[] | select(.court == "mine" or .court == "waiting_on_author")
          | select(.author.isBot | not) | {repo, login: .author.login}] | unique' "$queue" >"$tmp/all.json"
  # Drop pairs that can't be spliced safely one by one, so one odd login
  # doesn't cost the rest of its batch their history.
  jq -c "$HISTORY_VALID_JQ"' [.[] | select(valid)]' "$tmp/all.json" >"$tmp/pairs.json"
  local skipped
  skipped="$(jq -r "$HISTORY_VALID_JQ"' [.[] | select(valid | not) | "\(.repo) @\(.login)"] | join(", ")' "$tmp/all.json")"
  [ -z "$skipped" ] || warn "no author history for $skipped (unexpected repo or login)"
  total="$(jq length "$tmp/pairs.json")"
  : >"$tmp/results.jsonl"
  while [ "$i" -lt "$total" ]; do
    jq -c --argjson i "$i" --argjson n "$QUILL_HISTORY_BATCH" '.[$i:$i + $n]' "$tmp/pairs.json" >"$tmp/batch-$n.json"
    if ! query="$(_history_query <"$tmp/batch-$n.json" 2>/dev/null)"; then
      warn "skipping author history for a batch with an unexpected repo or login"
    elif gh api graphql --method POST -f query="$query" >"$tmp/resp-$n.json" 2>"$tmp/err-$n.txt" ||
      jq -e '.data | type == "object"' "$tmp/resp-$n.json" >/dev/null 2>&1; then
      jq -c --slurpfile b "$tmp/batch-$n.json" '
        . as $r | $b[0] | to_entries[]
        | {repo: .value.repo, login: .value.login,
           history: (if $r.data["h\(.key)m"] == null then null else {
             merged: $r.data["h\(.key)m"].issueCount,
             closedUnmerged: $r.data["h\(.key)c"].issueCount,
             open: $r.data["h\(.key)o"].issueCount,
             recent: [($r.data["h\(.key)r"].nodes // [])[] | select(.number != null)
               | {number, merged, closedAt, reviews: .reviews.totalCount,
                  changesRequested: .changesRequested.totalCount}]} end)}' \
        "$tmp/resp-$n.json" >>"$tmp/results.jsonl"
    else
      warn "couldn't fetch author history: $(head -1 "$tmp/err-$n.txt" 2>/dev/null)"
    fi
    i=$((i + QUILL_HISTORY_BATCH))
    n=$((n + 1))
  done
  jq --slurpfile h <(jq -s . "$tmp/results.jsonl") '
    ($h[0] | map({key: "\(.repo) \(.login)", value: .history}) | from_entries) as $m
    | .items |= map(. + {authorHistory: ($m["\(.repo) \(.author.login)"] // null)})' "$queue" >"$tmp/queue.json" &&
    mv -f "$tmp/queue.json" "$queue"
  rm -rf "$tmp"
}
