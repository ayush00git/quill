# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Test plans for --run-tests: which image and command run the tests of the
# modules a PR touches. Detection reads only the base tree's file names
# (git ls-tree) and the PR's changed paths; it never runs anything.
#
#   test_plan <git dir> <head sha> <changed files file> <repo> <config file>
#     prints {image, command, modules, buildSystem} or {reason} when there's
#     no plan
#
# config.tests.repos["owner/repo"] = {image, command} overrides detection;
# "{modules}" in the command is replaced with the detected module list.
# Requires lib/common.sh and lib/repo.sh.

# _nearest_with <tree list file> <dir> <file name>...: the closest directory at
# or above <dir> that contains one of the files ("." for the root), or nothing.
_nearest_with() {
  local tree="$1" d="$2" f
  shift 2
  while :; do
    for f in "$@"; do
      if [ "$d" = . ]; then
        grep -qxF "$f" "$tree" && { printf '.\n'; return 0; }
      else
        grep -qxF "$d/$f" "$tree" && { printf '%s\n' "$d"; return 0; }
      fi
    done
    [ "$d" != . ] || return 0
    case "$d" in */*) d="${d%/*}" ;; *) d=. ;; esac
  done
}

# _modules <tree> <changed file> <build file>...: unique nearest module dirs.
_modules() {
  local tree="$1" changed="$2" p dir
  shift 2
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in */*) dir="${p%/*}" ;; *) dir=. ;; esac
    _nearest_with "$tree" "$dir" "$@"
  done <"$changed" | sort -u
}

# _go_packages <changed file>: the directory of each changed .go file, unique.
# (A function, not inline: bash 3.2 can't parse a case inside $(...).)
_go_packages() {
  local p
  grep '\.go$' "$1" | while IFS= read -r p; do
    case "$p" in */*) printf '%s\n' "${p%/*}" ;; *) printf '.\n' ;; esac
  done | sort -u
}

test_plan() {
  local gd="$1" head="$2" changed="$3" repo="$4" cfg="$5" tree mods system image cmd
  tree="$(mktemp "${TMPDIR:-/tmp}/quill-tree.XXXXXX")" || return 1
  qgit --git-dir="$gd" ls-tree -r --name-only "$head" >"$tree" || {
    rm -f "$tree"
    return 1
  }

  if grep -qx 'pom.xml' "$tree"; then
    system=maven
    mods="$(_modules "$tree" "$changed" pom.xml)"
    image="maven:3-eclipse-temurin-17"
    if [ -z "$mods" ] || printf '%s\n' "$mods" | grep -qx '\.'; then
      cmd="mvn -B -ntp test"
    else
      cmd="mvn -B -ntp -am -pl $(printf '%s\n' "$mods" | paste -sd, -) test"
    fi
  elif grep -qxE 'build\.gradle(\.kts)?|settings\.gradle(\.kts)?' "$tree"; then
    system=gradle
    mods="$(_modules "$tree" "$changed" build.gradle build.gradle.kts)"
    image="gradle:8-jdk17"
    if [ -z "$mods" ] || printf '%s\n' "$mods" | grep -qx '\.'; then
      cmd="gradle --no-daemon test"
    else
      cmd="gradle --no-daemon $(printf '%s\n' "$mods" | sed 's|/|:|g; s|^|:|; s|$|:test|' | paste -sd' ' -)"
    fi
  elif grep -qx 'go.mod' "$tree"; then
    system=go
    # Go packages are directories: test each one a changed .go file is in.
    mods="$(_go_packages "$changed")"
    [ -n "$mods" ] || mods="."
    image="golang:1"
    cmd="go test$(printf '%s\n' "$mods" | while IFS= read -r p; do
      if [ "$p" = . ]; then printf ' .'; else printf ' ./%s' "$p"; fi
    done)"
  elif grep -qxE 'pyproject\.toml|setup\.py|setup\.cfg' "$tree"; then
    system=python
    mods="."
    image="python:3"
    cmd="pip install -q -e '.[test]' || pip install -q -e . pytest; python -m pytest -q"
  elif grep -qx 'package.json' "$tree"; then
    system=node
    mods="."
    image="node:lts"
    cmd="npm ci && npm test"
  elif grep -qx 'Cargo.toml' "$tree"; then
    system=cargo
    mods="."
    image="rust:1"
    cmd="cargo test"
  fi
  rm -f "$tree"

  # A per-repo override wins: {image, command}, with {modules} filled in.
  jq -c --arg repo "$repo" --arg system "${system:-}" --arg image "${image:-}" --arg cmd "${cmd:-}" \
    --arg mods "${mods:-}" '
    (.tests.repos[$repo] // null) as $o
    | ($mods | split("\n") | map(select(length > 0))) as $m
    | if $o != null and ($o.image | type) == "string" and ($o.command | type) == "string" then
        {buildSystem: "configured", image: $o.image,
         command: ($o.command | gsub("\\{modules\\}"; ($m | join(",")))), modules: $m}
      elif $system == "" then
        {reason: "couldn'"'"'t tell how this repo runs its tests; set tests.repos[\"\($repo)\"] = {image, command} in config.json"}
      else {buildSystem: $system, image: $image, command: $cmd, modules: $m} end' "$cfg"
}
