#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# queue.sh: build the review queue for one run.
#
#   queue.sh --run-dir <dir> [--repo owner/name]... [--pr <owner/repo#N | PR URL>]
#
# Writes <run-dir>/queue.json:
#   {version: 1, generatedAt, viewer, items: [{repo, number, url, sources}]}
# and prints a one-line summary. Repos come from --repo (repeatable) plus
# config.json "repos". With --pr, the queue is just that PR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/discover.sh
source "$SCRIPT_DIR/lib/discover.sh"

usage() {
  sed -n '4,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

main() {
  local run_dir="" pr_ref="" repos="[]"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
      --repo)
        [ -n "${2:-}" ] || usage
        valid_repo "$2" || die "not a repository (want owner/name): $2" 64
        repos="$(jq -c --arg r "$2" '. + [$r]' <<<"$repos")"
        shift 2
        ;;
      --pr) pr_ref="${2:-}"; shift 2 || usage ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  require_cmd gh jq
  mkdir -p "$run_dir"

  local viewer items
  viewer="$(viewer_login)"
  if [ -n "$pr_ref" ]; then
    local parsed owner repo number
    parsed="$(parse_pr_ref "$pr_ref")"
    read -r owner repo number <<<"$parsed"
    items="$(jq -n --arg r "$owner/$repo" --argjson n "$number" \
      '[{repo: $r, number: $n, url: "https://github.com/\($r)/pull/\($n)", sources: ["explicit"]}]')"
  else
    # One assignment per search, so a failed search stops the run (set -e
    # doesn't see failures inside a command substitution used as an argument).
    local requested reviewed all_repos repo watched="[]" found
    requested="$(discover_requested)" || die "searching for review-requested PRs failed"
    reviewed="$(discover_reviewed)" || die "searching for PRs I reviewed failed"
    all_repos="$(config_json | jq -c --argjson cli "$repos" '
      if (.repos | type) == "array" then (.repos + $cli | unique) else error("repos must be an array") end')" ||
      die "config.json: \"repos\" must be an array of owner/name strings"
    while IFS= read -r repo; do
      valid_repo "$repo" || die "not a repository (want owner/name): $repo"
      found="$(discover_repo "$repo")" || die "listing open PRs in $repo failed"
      watched="$(merge_candidates "$watched" "$found")"
    done < <(jq -r '.[] | tostring' <<<"$all_repos")
    items="$(merge_candidates "$requested" "$reviewed" "$watched")"
  fi

  jq -n --arg at "$(now_iso)" --arg viewer "$viewer" --argjson items "$items" \
    '{version: 1, generatedAt: $at, viewer: $viewer, items: $items}' |
    write_atomic "$run_dir/queue.json"

  jq -r '"queue: \(.items | length) open PR(s) found"
    + " (review requested: \([.items[] | select(.sources | index("review-requested"))] | length),"
    + " reviewed before: \([.items[] | select(.sources | index("reviewed-by"))] | length),"
    + " in watched repos: \([.items[] | select(.sources | index("repo"))] | length))"' \
    "$run_dir/queue.json"
}

main "$@"
