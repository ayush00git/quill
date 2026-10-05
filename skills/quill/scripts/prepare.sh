#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# prepare.sh: isolate every PR the queue marked for review.
#
#   prepare.sh --run-dir <dir>
#
# For each queue.json item with needsReview: cached clone, fetch, sparse
# worktree at the PR head, review mode, and a context bundle in
# <run-dir>/ctx/<slug>/. Writes <run-dir>/dispatch.json:
#   {version: 1, refsDir, prs: [{pr, slug, ctxDir, worktree, mode} | {pr, error}]}
# One PR failing doesn't stop the others; it's listed with its error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"
# shellcheck source=lib/worktree.sh
source "$SCRIPT_DIR/lib/worktree.sh"
# shellcheck source=lib/mode.sh
source "$SCRIPT_DIR/lib/mode.sh"
# shellcheck source=lib/risk.sh
source "$SCRIPT_DIR/lib/risk.sh"
# shellcheck source=lib/bundle.sh
source "$SCRIPT_DIR/lib/bundle.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

# prepare_one <run dir> <item file>: prints one dispatch entry (JSON).
# Runs in a subshell so a die() inside only fails this PR. errexit doesn't
# reach into command substitutions on older bash, so every step checks.
prepare_one() {
  local run_dir="$1" item="$2" repo number base head last gd wt mode_file ctx fetched
  repo="$(jq -r .repo "$item")" || return 1
  number="$(jq -r .number "$item")" || return 1
  base="$(jq -r .base.ref "$item")" || return 1
  head="$(jq -r .head.sha "$item")" || return 1
  # The head reviewed last: quill's own draft, else my last review on GitHub
  # (a PR I reviewed by hand before using quill still gets an incremental diff).
  last="$(jq -r '.quillState.reviewedHeadSha // .lastMyReview.commit // empty' "$item")" || return 1
  if [ -n "$last" ] && ! _is_sha "$last"; then
    warn "$repo#$number: ignoring a malformed last reviewed SHA ($last); doing a full review"
    last=""
  fi

  gd="$(ensure_clone "$repo")" || return 1
  fetched="$(fetch_pr "$repo" "$number" "$base")" || return 1
  if [ "$fetched" != "$head" ]; then
    warn "$repo#$number: head moved since the queue was built ($head -> $fetched); reviewing $fetched"
    head="$fetched"
  fi
  wt="$(add_worktree "$repo" "$number" "$head")" || return 1
  mkdir -p "$run_dir/ctx"
  mode_file="$run_dir/ctx/.mode-$number-$$.json"
  review_mode "$repo" "$number" "$base" "$head" "$last" >"$mode_file" || return 1
  ctx="$(write_bundle "$run_dir" "$item" "$gd" "$wt" "$mode_file")" || return 1
  jq -c --arg pr "$repo#$number" --arg ctx "$ctx" --arg wt "$wt" \
    '{pr: $pr, slug: ($ctx | split("/") | last), ctxDir: $ctx, worktree: $wt, mode: .mode}' "$mode_file" || return 1
  rm -f "$mode_file"
}

main() {
  local run_dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  run_dir="$(require_run_dir "$run_dir")" || exit 1
  [ -f "$run_dir/queue.json" ] || die "no queue.json in $run_dir (run queue.sh first)"
  require_cmd git gh jq

  copy_references "$run_dir"
  local entries="$run_dir/.dispatch-entries" item="$run_dir/.item.json" i=0 total key entry err
  : >"$entries"
  total="$(jq '[.items[] | select(.needsReview)] | length' "$run_dir/queue.json")"
  while [ "$i" -lt "$total" ]; do
    jq --argjson i "$i" '[.items[] | select(.needsReview)][$i]' "$run_dir/queue.json" >"$item"
    key="$(jq -r '"\(.repo)#\(.number)"' "$item")"
    if entry="$( (prepare_one "$run_dir" "$item") 2>"$run_dir/.prepare-err")"; then
      printf '%s\n' "$entry" >>"$entries"
    else
      err="$(grep 'quill: error:' "$run_dir/.prepare-err" | tail -1 | sed 's/^quill: error: //')"
      [ -n "$err" ] || err="$(tail -1 "$run_dir/.prepare-err")"
      warn "$key: not prepared: $err"
      jq -cn --arg pr "$key" --arg e "$err" '{pr: $pr, error: $e}' >>"$entries"
    fi
    grep -v 'quill: error:' "$run_dir/.prepare-err" >&2 || true
    i=$((i + 1))
  done

  jq -s --arg refs "$run_dir/refs" '{version: 1, refsDir: $refs, prs: .}' "$entries" |
    write_atomic "$run_dir/dispatch.json"
  rm -f "$entries" "$item" "$run_dir/.prepare-err"

  jq -r '"prepare: \([.prs[] | select(.error | not)] | length) PR(s) ready for review"
    + (([.prs[] | select(.error)] | length) as $f | if $f > 0 then ", \($f) failed" else "" end)' \
    "$run_dir/dispatch.json"
}

main "$@"
