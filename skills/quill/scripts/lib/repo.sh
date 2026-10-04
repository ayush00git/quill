# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Cached clones: one bare, blob-less partial clone per repo under
# $QUILL_HOME/repos/<owner>__<repo>.git. PR content is untrusted, so every
# git call goes through qgit and the clone is configured so that nothing in
# a PR can make git run code or follow links:
#   safe.bareRepository=explicit   git never adopts a bare repo it merely
#                                  finds (a PR can commit one); the cached
#                                  clone is always named with --git-dir
#   core.hooksPath=/dev/null       no hooks, ever
#   core.symlinks=false            PR symlinks check out as plain text files
#   info/attributes                PR .gitattributes can't pick diff drivers,
#                                  filters, export rules or encodings
#   GIT_LFS_SKIP_SMUDGE=1          no LFS downloads on checkout
# Clones come from $QUILL_GIT_BASE_URL/<owner>/<repo>.git (default
# https://github.com; tests point it at local fixtures).
# Requires lib/common.sh.

# Highest-precedence attributes: '!attr' makes each one unspecified, which
# beats any in-tree .gitattributes and keeps git's binary autodetection.
QUILL_INFO_ATTRIBUTES='* !diff !filter !export-subst !export-ignore !working-tree-encoding'

# qgit <git args>: git with quill's safety settings.
qgit() {
  GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 \
    git -c safe.bareRepository=explicit -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# qgit_net <git args>: qgit for clone/fetch, using gh's credentials so
# private repos work without a global credential setup.
qgit_net() {
  qgit -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
}

# repo_git_dir <owner/name>: path of the cached clone.
repo_git_dir() {
  valid_repo "$1" || die "not a repository (want owner/name): $1"
  printf '%s/repos/%s.git\n' "$(quill_home)" "$(repo_slug "${1%%/*}" "${1#*/}")"
}

# _harden_clone <git dir>: (re)apply the safety configuration. Idempotent.
_harden_clone() {
  local gd="$1"
  qgit --git-dir="$gd" config core.symlinks false
  qgit --git-dir="$gd" config core.hooksPath /dev/null
  qgit --git-dir="$gd" config core.fsmonitor false
  qgit --git-dir="$gd" config fetch.recurseSubmodules false
  qgit --git-dir="$gd" config submodule.recurse false
  mkdir -p "$gd/info"
  printf '%s\n' "$QUILL_INFO_ATTRIBUTES" >"$gd/info/attributes"
}

# ensure_clone <owner/name>: create the cached clone if needed; prints its
# git dir. An existing clone is reused without touching the network.
ensure_clone() {
  local repo="$1" gd tmp
  gd="$(repo_git_dir "$repo")"
  if [ -d "$gd" ]; then
    [ "$(qgit --git-dir="$gd" rev-parse --is-bare-repository 2>/dev/null)" = "true" ] ||
      die "$gd exists but isn't a bare git repository; remove it and rerun"
  else
    mkdir -p "$(dirname "$gd")"
    tmp="$gd.tmp.$$"
    rm -rf "$tmp"
    if ! qgit_net clone --quiet --bare --filter=blob:none --no-tags \
      "${QUILL_GIT_BASE_URL:-https://github.com}/$repo.git" "$tmp" >&2; then
      rm -rf "$tmp"
      die "cloning $repo failed"
    fi
    mv "$tmp" "$gd"
  fi
  _harden_clone "$gd"
  printf '%s\n' "$gd"
}

# fetch_pr <owner/name> <N> <base branch>: fetch the base branch and the
# PR head into refs/quill/; prints the head SHA.
#   refs/quill/base/<branch>   the base branch tip
#   refs/quill/pr/<N>/head     the PR head
fetch_pr() {
  local repo="$1" number="$2" base="$3" gd
  case "$number" in '' | 0* | *[!0-9]*) die "not a PR number: $number" ;; esac
  case "$base" in -*) die "not a branch name: $base" ;; esac
  git check-ref-format --branch "$base" >/dev/null 2>&1 || die "not a branch name: $base"
  gd="$(repo_git_dir "$repo")"
  [ -d "$gd" ] || die "no cached clone for $repo (run ensure_clone first)"
  qgit_net --git-dir="$gd" fetch --quiet --no-tags origin \
    "+refs/heads/$base:refs/quill/base/$base" \
    "+refs/pull/$number/head:refs/quill/pr/$number/head" >&2 ||
    die "fetching $repo#$number failed"
  qgit --git-dir="$gd" rev-parse --verify --quiet "refs/quill/pr/$number/head^{commit}"
}
