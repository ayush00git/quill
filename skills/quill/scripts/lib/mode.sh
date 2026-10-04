# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Review modes: what the reviewer should diff.
#   full         first review (or the earlier head is gone): merge base..head
#   incremental  re-review, author added commits on top: last reviewed..head
#   range-diff   re-review after a force-push or a merge of the base branch:
#                git range-diff <old base>..<last reviewed> <merge base>..<head>
# The SHA quill last reviewed is kept reachable at refs/quill/pr/<N>/reviewed
# (mark_reviewed), so a force-push can't garbage-collect it.
# Requires lib/common.sh and lib/repo.sh.

_is_sha() {
  case "$1" in *[!0-9a-f]* | '') return 1 ;; esac
  [ "${#1}" -eq 40 ]
}

# review_mode <owner/name> <N> <base branch> <head sha> [<last reviewed sha>]
# Prints a JSON object: {mode, reason, base, mergeBase, head, lastReviewed,
# diff: [from, to] | null, rangeDiff: [old range, new range] | null}.
review_mode() {
  local repo="$1" number="$2" base="$3" head="$4" last="${5:-}" gd mb old_mb mode reason
  _is_sha "$head" || die "not a full commit SHA: $head"
  [ -z "$last" ] || _is_sha "$last" || die "not a full commit SHA: $last"
  git check-ref-format --branch "$base" >/dev/null 2>&1 || die "not a branch name: $base"
  gd="$(repo_git_dir "$repo")" || return 1
  mb="$(qgit --git-dir="$gd" merge-base "refs/quill/base/$base" "$head")" ||
    die "no merge base between $base and $repo#$number (fetch first)"

  if [ -z "$last" ]; then
    mode=full
    reason="first review"
  elif ! qgit --git-dir="$gd" cat-file -e "$last^{commit}" 2>/dev/null; then
    mode=full
    reason="the previously reviewed head $last is no longer available"
    last=""
  elif [ "$last" = "$head" ]; then
    mode=full
    reason="same head as the last review (forced)"
  elif qgit --git-dir="$gd" merge-base --is-ancestor "$last" "$head"; then
    if [ -n "$(qgit --git-dir="$gd" rev-list --merges "$last..$head")" ]; then
      mode=range-diff
      reason="the base branch was merged into the PR since the last review"
    else
      mode=incremental
      reason="new commits on top of the last reviewed head"
    fi
  else
    mode=range-diff
    reason="force-pushed since the last review"
  fi

  old_mb=""
  if [ "$mode" = range-diff ]; then
    old_mb="$(qgit --git-dir="$gd" merge-base "refs/quill/base/$base" "$last")" ||
      die "no merge base for the previously reviewed head"
  fi

  jq -n --arg mode "$mode" --arg reason "$reason" --arg base "$base" --arg mb "$mb" \
    --arg head "$head" --arg last "$last" --arg old_mb "$old_mb" '
    {mode: $mode, reason: $reason, base: $base, mergeBase: $mb, head: $head,
     lastReviewed: (if $last == "" then null else $last end),
     diff: (if $mode == "full" then [$mb, $head]
            elif $mode == "incremental" then [$last, $head] else null end),
     rangeDiff: (if $mode == "range-diff" then ["\($old_mb)..\($last)", "\($mb)..\($head)"] else null end)}'
}

# mark_reviewed <owner/name> <N> <sha>: remember (and keep reachable) the
# head quill reviewed.
mark_reviewed() {
  local gd
  _is_sha "$3" || die "not a full commit SHA: $3"
  case "$2" in '' | 0* | *[!0-9]*) die "not a PR number: $2" ;; esac
  gd="$(repo_git_dir "$1")" || return 1
  qgit --git-dir="$gd" update-ref "refs/quill/pr/$2/reviewed" "$3"
}

# last_reviewed <owner/name> <N>: the SHA from mark_reviewed, or nothing.
last_reviewed() {
  local gd
  case "$2" in '' | 0* | *[!0-9]*) die "not a PR number: $2" ;; esac
  gd="$(repo_git_dir "$1")" || return 1
  qgit --git-dir="$gd" rev-parse --verify --quiet "refs/quill/pr/$2/reviewed^{commit}" || true
}
