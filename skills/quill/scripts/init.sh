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
# Prints the workspace path on stdout.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

POST_ASK_RULE='Bash(*post.sh --submit*)'

main() {
  require_cmd jq
  local home
  home="$(quill_home)"
  case "$home" in
    *'*'* | *'?'* | *'['* | *']'*)
      die "QUILL_HOME can't contain glob characters (* ? [ ]): $home"
      ;;
  esac

  mkdir -p "$home"
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

  merge_settings "$home"
  printf '%s\n' "$home"
}

# merge_settings <home>: add the keys quill needs to the workspace's
# .claude/settings.json, keeping everything already there.
merge_settings() {
  local home="$1" settings current merged
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
    --argjson excludes "$(jq -n --arg h "$home" '[$h + "/repos/**", $h + "/worktrees/**", $h + "/reviews/**"]')" '
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
