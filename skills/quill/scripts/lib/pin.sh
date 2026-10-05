# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Pinning a single-PR review to one of the PR's own commits (queue.sh --at),
# for example the commit a maintainer approved. The review shows the PR as
# it stood when that commit was its head, so nothing from later reaches the
# reviewer:
#   head.sha, reviewAt  the pinned commit, which must be one of the PR's
#                       commits (prepare.sh also checks it's in the PR's
#                       history)
#   ci                  that commit's checks, as GitHub reports them now
#   files, size         base...commit, from GitHub's compare API
#   myReviews           only my reviews of commits before it, by the PR's
#                       commit order (not by timestamps), so my review of the
#                       pinned commit itself, or anything later, isn't shown
#   reviewDecision, mergeable, mergeStateStatus, updatedAt: cleared
# The PR's real state stays on the queue item; bundle.sh shows the reviewer
# "OPEN", which it was while the commit was its head.
# Requires lib/common.sh.

# pin_to_commit <owner/repo> <N> <sha, 7 to 40 hex digits> <enriched.json>:
# rewrites the PR's item in enriched.json in place.
pin_to_commit() {
  local repo="$1" number="$2" want file="$4" tmp sha n base
  want="$(printf '%s' "$3" | tr 'ABCDEF' 'abcdef')"
  case "$want" in '' | *[!0123456789abcdef]*) die "--at wants a commit SHA (hex digits), not: $3" 64 ;; esac
  if [ "${#want}" -lt 7 ] || [ "${#want}" -gt 40 ]; then
    die "--at wants 7 to 40 hex digits: $3" 64
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-pin.XXXXXX")" || return 1

  # The PR's own commits, oldest first (GitHub lists up to 250).
  if ! gh api --method GET "repos/$repo/pulls/$number/commits?per_page=100" --paginate --jq '.[].sha' \
    >"$tmp/commits" 2>"$tmp/err"; then
    rm -rf "$tmp"
    die "listing $repo#$number's commits failed: $(head -1 "$tmp/err" 2>/dev/null)"
  fi
  n="$(grep -c "^$want" "$tmp/commits" || true)"
  case "$n" in
    0) rm -rf "$tmp"; die "$3 isn't one of $repo#$number's commits" 64 ;;
    1) ;;
    *) rm -rf "$tmp"; die "$3 matches $n of $repo#$number's commits; give more digits" 64 ;;
  esac
  sha="$(grep "^$want" "$tmp/commits")"
  _pin_is_sha "$sha" || { rm -rf "$tmp"; die "GitHub returned a malformed commit SHA for $repo#$number"; }

  # That commit's CI: the same fields as pr-fields.graphql's commits(last: 1).
  # shellcheck disable=SC2016 # GraphQL variables, not shell
  if ! gh api graphql --method POST -f query='query($owner: String!, $name: String!, $oid: GitObjectID!) {
      repository(owner: $owner, name: $name) { object(oid: $oid) { ... on Commit {
        oid statusCheckRollup { state contexts { totalCount } }
        checkSuites(first: 30) { nodes { status conclusion app { slug } } } } } } }' \
    -f owner="${repo%%/*}" -f name="${repo#*/}" -f oid="$sha" >"$tmp/commit.json" 2>"$tmp/err"; then
    rm -rf "$tmp"
    die "reading $sha's checks failed: $(head -1 "$tmp/err" 2>/dev/null)"
  fi

  # The PR's files and size as of that commit.
  base="$(jq -r --arg r "$repo" --argjson n "$number" \
    'first(.[] | select(.repo == $r and .number == $n) | .base.ref) // ""' "$file")"
  [ -n "$base" ] || { rm -rf "$tmp"; die "$repo#$number isn't in the queue"; }
  if ! gh api --method GET "repos/$repo/compare/$base...$sha" \
    --jq '{files: [.files[]? | {filename, additions, deletions, status}]}' >"$tmp/compare.json" 2>"$tmp/err"; then
    rm -rf "$tmp"
    die "comparing $base...$sha failed: $(head -1 "$tmp/err" 2>/dev/null)"
  fi

  jq -L "$QUILL_LIB_DIR" --arg r "$repo" --argjson n "$number" --arg sha "$sha" \
    --rawfile commits "$tmp/commits" --slurpfile c "$tmp/commit.json" --slurpfile cmp "$tmp/compare.json" '
    include "normalize";
    ($commits | split("\n") | map(select(length > 0))) as $all
    | ($all[:($all | index($sha))]) as $before
    | ($c[0].data.repository.object // null) as $o
    | if ($o.oid // "") != $sha then error("GitHub has no commit \($sha)") else . end
    | ($cmp[0].files) as $f
    | map(if .repo == $r and .number == $n then
        . + {head: (.head + {sha: $sha}), reviewAt: $sha,
             ci: ({commits: {nodes: [{commit: $o}]}} | ci_state),
             files: [$f[] | {path: .filename, additions, deletions,
               changeType: ({added: "ADDED", removed: "DELETED", renamed: "RENAMED", copied: "COPIED"}[.status] // "MODIFIED")}],
             filesTruncated: (($f | length) >= 300),
             size: {additions: ([$f[].additions] | add // 0), deletions: ([$f[].deletions] | add // 0), files: ($f | length)},
             myReviews: [.myReviews[] | select(.commit as $rc | $before | index($rc))],
             reviewDecision: null, mergeable: null, mergeStateStatus: null, updatedAt: null}
      else . end)' "$file" >"$tmp/pinned.json" || { rm -rf "$tmp"; die "pinning $repo#$number to $sha failed"; }
  write_atomic "$file" <"$tmp/pinned.json"
  rm -rf "$tmp"
}

_pin_is_sha() {
  case "$1" in *[!0123456789abcdef]* | '') return 1 ;; esac
  [ "${#1}" -eq 40 ]
}
