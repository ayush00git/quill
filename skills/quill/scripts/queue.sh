#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# queue.sh: build the review queue for one run.
#
#   queue.sh --run-dir <dir> [--pr <owner/repo#N | PR URL>]
#
# Writes <run-dir>/queue.json:
#   {version: 1, generatedAt, viewer, items: [{repo, number, url, sources}]}
# and prints a one-line summary. With --pr, the queue is just that PR.
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
  local run_dir="" pr_ref=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
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
    local requested reviewed
    requested="$(discover_requested)" || die "searching for review-requested PRs failed"
    reviewed="$(discover_reviewed)" || die "searching for PRs I reviewed failed"
    items="$(merge_candidates "$requested" "$reviewed")"
  fi

  jq -n --arg at "$(now_iso)" --arg viewer "$viewer" --argjson items "$items" \
    '{version: 1, generatedAt: $at, viewer: $viewer, items: $items}' |
    write_atomic "$run_dir/queue.json"

  jq -r '"queue: \(.items | length) open PR(s) found"
    + " (review requested: \([.items[] | select(.sources | index("review-requested"))] | length),"
    + " reviewed before: \([.items[] | select(.sources | index("reviewed-by"))] | length))"' \
    "$run_dir/queue.json"
}

main "$@"
