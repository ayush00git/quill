#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# render-queue.sh: write the ranked review queue for a run.
#
#   render-queue.sh --run-dir <dir>
#
# Reads <run-dir>/queue.json, state.json (drafts for each PR's current head)
# and <run-dir>/results.json (this run's saves, if any), and writes
# reviews/<date>/QUEUE.md (lib/render.jq). Prints the file's path last.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

main() {
  local run_dir="" state results out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  require_cmd jq
  run_dir="$(require_run_dir "$run_dir")" || exit 1
  [ -f "$run_dir/queue.json" ] || die "no queue.json in $run_dir (run queue.sh first)"

  state="$(quill_home)/state.json"
  [ -f "$state" ] || state="$QUILL_LIB_DIR/empty-state.json"
  results="$run_dir/results.json"
  [ -f "$results" ] || results="$QUILL_LIB_DIR/empty-results.json"
  # reviews/<date>/ is two levels above the run dir (reviews/<date>/.run/<id>).
  out="$(dirname "$(dirname "$run_dir")")/QUEUE.md"

  jq -r -L "$QUILL_LIB_DIR" --slurpfile state "$state" --slurpfile results "$results" \
    'include "render"; render($state[0]; $results[0])' "$run_dir/queue.json" | write_atomic "$out"

  jq -r '"queue: \([.items[] | select(.court == "mine")] | length) in your court, \([.items[] | select(.court == "waiting_on_author")] | length) waiting on the author"' \
    "$run_dir/queue.json"
  printf '%s\n' "$out"
}

main "$@"
