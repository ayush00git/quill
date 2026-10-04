#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# queue.sh: build the review queue for one run.
#
#   queue.sh --run-dir <dir> [--repo owner/name]... [--pr <owner/repo#N | PR URL>] [--force]
#
# Writes <run-dir>/queue.json:
#   {version: 1, generatedAt, viewer, items: [...]}
# where each item has {repo, number, url, sources} plus the PR details from
# lib/normalize.jq (title, author, base/head, size, files, CI, reviews, ...)
# and the ball-in-court verdict from lib/classify.jq (court, needsReview, ...).
# --force marks every PR in my court for review even if quill already drafted
# a review for its current head.
# and prints a one-line summary. Repos come from --repo (repeatable) plus
# config.json "repos". With --pr, the queue is just that PR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/discover.sh
source "$SCRIPT_DIR/lib/discover.sh"
# shellcheck source=lib/enrich.sh
source "$SCRIPT_DIR/lib/enrich.sh"

usage() {
  sed -n '4,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

main() {
  local run_dir="" pr_ref="" repos="[]" force=false
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
      --force) force=true; shift ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  require_cmd gh jq
  run_dir="$(require_run_dir "$run_dir")" || exit 1

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

  printf '%s\n' "$items" | write_atomic "$run_dir/candidates.json"
  enrich_items "$run_dir/candidates.json" "$viewer" "$run_dir/enriched.json"

  local state_file
  state_file="$(quill_home)/state.json"
  [ -f "$state_file" ] || state_file="$QUILL_LIB_DIR/empty-state.json"
  config_json >"$run_dir/config.effective.json"
  jq -L "$QUILL_LIB_DIR" --arg at "$(now_iso)" --arg viewer "$viewer" --argjson force "$force" \
    --slurpfile cfg "$run_dir/config.effective.json" --slurpfile state "$state_file" '
    include "classify";
    {version: 1, generatedAt: $at, viewer: $viewer,
     items: map(classify($viewer; $cfg[0]; $state[0]; $force))}' "$run_dir/enriched.json" |
    write_atomic "$run_dir/queue.json"
  rm -f "$run_dir/candidates.json" "$run_dir/enriched.json" "$run_dir/config.effective.json"

  jq -r '
    def n(f): [.items[] | select(f)] | length;
    "queue: \(.items | length) open PR(s): \(n(.needsReview)) to review"
    + " (\(n(.needsReview and .reReview)) re-reviews),"
    + " \(n(.court == "mine" and (.needsReview | not))) unchanged since the last draft,"
    + " \(n(.court == "waiting_on_author")) waiting on author,"
    + " \(n(.court == "skip")) skipped"' \
    "$run_dir/queue.json"
}

main "$@"
