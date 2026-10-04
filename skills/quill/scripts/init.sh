#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# init.sh: create or repair the quill workspace. Safe to run on every
# invocation: it only adds what is missing and never removes your keys.
#
#   <QUILL_HOME>/
#     config.json  state.json  notes/  references/  repos/  worktrees/
#     logs/  reviews/
#     .claude/settings.json   claudeMdExcludes for repos/, worktrees/ and
#                             reviews/, plus an explicit ask rule for
#                             `post.sh --submit` (the human gate on posting)
#
# Prints the workspace path on stdout. With --new-run it also creates a run
# directory, reviews/<YYYY-MM-DD>/.run/<YYYYMMDDTHHMMSSZ>-<random>, and
# prints that instead, for the other scripts' --run-dir.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Matches any post.sh call with --submit anywhere after it, so a quoted path
# or reordered arguments can't skip the prompt.
POST_ASK_RULE='Bash(*post.sh*--submit*)'

main() {
  local new_run=false
  case "${1:-}" in
    --new-run) new_run=true ;;
    "") ;;
    *) die "unknown argument: $1 (use --new-run or nothing)" 64 ;;
  esac
  require_cmd jq
  local home
  home="$(quill_home)"
  reject_glob_chars "$home"
  mkdir -p "$home"
  local real
  real="$(resolve_path "$home")" || die "can't resolve the workspace path: $home"
  reject_glob_chars "$real"

  local d
  for d in notes references repos worktrees logs reviews; do
    mkdir -p "$home/$d"
  done

  if [ ! -f "$home/config.json" ]; then
    printf '%s\n' '{' '  "repos": []' '}' | write_atomic "$home/config.json"
    log "created $home/config.json"
  fi
  if [ ! -f "$home/state.json" ]; then
    printf '%s\n' '{"version": 1, "prs": {}}' | write_atomic "$home/state.json"
  fi

  merge_settings "$home" "$real"
  if [ "$new_run" = true ]; then
    local id
    id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
    require_run_dir "$home/reviews/$(today)/.run/$id"
  else
    printf '%s\n' "$home"
  fi
}

# The workspace path goes into glob patterns (claudeMdExcludes), so it can't
# contain glob characters itself.
reject_glob_chars() {
  case "$1" in
    *'*'* | *'?'* | *'['* | *']'*)
      die "QUILL_HOME can't contain glob characters (* ? [ ]): $1"
      ;;
  esac
}

# merge_settings <home> <resolved home>: add the keys quill needs to the
# workspace's .claude/settings.json, keeping everything already there. When
# the workspace is reached through a symlink, the excludes cover both paths.
merge_settings() {
  local home="$1" real="$2" settings current merged
  settings="$home/.claude/settings.json"
  mkdir -p "$home/.claude"
  if [ -f "$settings" ]; then
    jq -e 'type == "object"' "$settings" >/dev/null 2>&1 ||
      die "won't touch $settings: it isn't a JSON object. Fix or remove it, then rerun."
    current="$(cat "$settings")"
  else
    current='{}'
  fi

  merged="$(printf '%s' "$current" | jq \
    --arg ask "$POST_ASK_RULE" \
    --argjson excludes "$(jq -n --arg h "$home" --arg r "$real" \
      'if $h == $r then [$h] else [$h, $r] end | map(. + "/repos/**", . + "/worktrees/**", . + "/reviews/**")')" '
    def add_missing($xs): reduce $xs[] as $x (. // []; if index([$x]) then . else . + [$x] end);
    .claudeMdExcludes |= add_missing($excludes)
    | .permissions = (.permissions // {})
    | .permissions.ask |= add_missing([$ask])
  ')"

  if [ "$merged" != "$(printf '%s' "$current" | jq .)" ]; then
    printf '%s\n' "$merged" | write_atomic "$settings"
    log "updated $settings (claudeMdExcludes, ask rule for post.sh --submit)"
  fi
}

main "$@"
