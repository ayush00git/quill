# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# PR worktrees: one detached, sparse worktree per PR at
# $QUILL_HOME/worktrees/<owner>__<repo>__<N>, checked out from the cached
# clone (lib/repo.sh) at the PR head.
#
# Claude Code auto-loads CLAUDE.md, CLAUDE.local.md and AGENTS.md (and
# skills and rules under .claude/) from any directory it reads files in,
# and loaded skills persist for the session. A PR controls those files, so
# they never reach the disk: the sparse checkout leaves them out in any
# letter case, and the result is verified before anyone reads it. The
# reviewer still sees them through `git show` / `git diff`.
# Requires lib/common.sh and lib/repo.sh.

# Non-cone sparse patterns (gitignore syntax): everything except
# instruction files and .claude directories, matched case-insensitively.
QUILL_SPARSE_PATTERNS='/*
!**/[Cc][Ll][Aa][Uu][Dd][Ee].[Mm][Dd]
!**/[Cc][Ll][Aa][Uu][Dd][Ee].[Ll][Oo][Cc][Aa][Ll].[Mm][Dd]
!**/[Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd]
!**/.[Cc][Ll][Aa][Uu][Dd][Ee]/'

# worktree_path <owner/name> <N>
worktree_path() {
  valid_repo "$1" || die "not a repository (want owner/name): $1"
  printf '%s/worktrees/%s\n' "$(quill_home)" "$(pr_slug "${1%%/*}" "${1#*/}" "$2")"
}

# worktree_unsafe_entries <dir>: prints instruction files, .claude dirs and
# symlinks found in a checkout (none should exist).
worktree_unsafe_entries() {
  find "$1" -path "$1/.git" -prune -o \
    \( -iname CLAUDE.md -o -iname CLAUDE.local.md -o -iname AGENTS.md \
    -o \( -type d -iname .claude \) -o -type l \) -print
}

# remove_worktree <owner/name> <N>: drop the worktree and git's record of it.
remove_worktree() {
  local gd wt
  gd="$(repo_git_dir "$1")"
  wt="$(worktree_path "$1" "$2")"
  if [ -e "$wt" ]; then
    qgit --git-dir="$gd" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  fi
  if [ -d "$gd" ]; then
    qgit --git-dir="$gd" worktree prune
  fi
}

# add_worktree <owner/name> <N> <head sha>: a clean, detached, sparse
# worktree at the PR head; prints its path. An existing worktree already at
# that head is reused after re-checking it.
add_worktree() {
  local repo="$1" number="$2" sha="$3" gd wt unsafe
  case "$sha" in
    *[!0-9a-f]* | '') die "not a full commit SHA: $sha" ;;
  esac
  [ "${#sha}" -eq 40 ] || die "not a full commit SHA: $sha"
  gd="$(repo_git_dir "$repo")"
  wt="$(worktree_path "$repo" "$number")"
  [ -d "$gd" ] || die "no cached clone for $repo (run ensure_clone first)"

  if [ -e "$wt" ]; then
    if [ "$(qgit -C "$wt" rev-parse HEAD 2>/dev/null)" = "$sha" ] &&
      [ -z "$(worktree_unsafe_entries "$wt")" ]; then
      printf '%s\n' "$wt"
      return 0
    fi
    remove_worktree "$repo" "$number"
  fi

  mkdir -p "$(dirname "$wt")"
  qgit --git-dir="$gd" worktree add --quiet --no-checkout --detach "$wt" "$sha" >&2 ||
    die "creating the worktree for $repo#$number failed"
  # git only talks to the worktree root (never a subdirectory a PR could
  # shape like a repository).
  printf '%s\n' "$QUILL_SPARSE_PATTERNS" | qgit -C "$wt" sparse-checkout set --no-cone --stdin >&2 ||
    die "configuring the sparse checkout for $repo#$number failed"
  # Populate the index and files; blobs come lazily from the partial clone.
  qgit_net -C "$wt" read-tree -mu HEAD >&2 ||
    die "checking out $repo#$number failed"

  unsafe="$(worktree_unsafe_entries "$wt")"
  if [ -n "$unsafe" ]; then
    remove_worktree "$repo" "$number"
    die "the checkout of $repo#$number contained instruction files or symlinks; refusing to use it: $(printf '%s' "$unsafe" | head -3 | tr '\n' ' ')"
  fi
  printf '%s\n' "$wt"
}
