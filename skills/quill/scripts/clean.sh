#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# clean.sh: remove what quill keeps for PRs that are closed or merged.
#
#   clean.sh [--dry-run]
#
# For every PR quill knows about (state.json entries and worktrees), asks
# GitHub for its state. For closed and merged ones it removes the worktree,
# quill's refs in the cached clone (refs/quill/pr/<N>/*), the state.json
# entry and any unposted payload. Review files under reviews/ stay as a
# record. A PR GitHub can't tell us about is left alone with a warning; so is
# a worktree whose name isn't owner__repo__N. Also drops reviewer bindings
# (.agents/) older than three days. --dry-run only lists what would go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"
# shellcheck source=lib/worktree.sh
source "$SCRIPT_DIR/lib/worktree.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

# slug_to_key <owner__repo__N>: "owner/repo#N", or nothing if it isn't one.
# Owners can't contain "_", so the first "__" ends the owner; the last one
# starts the number.
slug_to_key() {
  local s="$1" owner rest repo n
  owner="${s%%__*}"
  rest="${s#*__}"
  n="${rest##*__}"
  repo="${rest%__*}"
  if [ "$owner" = "$s" ] || [ "$repo" = "$rest" ]; then return 0; fi
  case "$n" in '' | 0* | *[!0123456789]*) return 0 ;; esac
  valid_repo "$owner/$repo" || return 0
  printf '%s/%s#%s\n' "$owner" "$repo" "$n"
}

# pr_states < keys json array: {"owner/repo#N": "OPEN|CLOSED|MERGED|UNKNOWN"}
pr_states() {
  local keys tmp total i=0 n=0 q
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-clean.XXXXXX")" || return 1
  cat >"$tmp/keys.json"
  total="$(jq length "$tmp/keys.json")"
  printf '{}\n' >"$tmp/states.json"
  while [ "$i" -lt "$total" ]; do
    keys="$(jq -c --argjson i "$i" '.[$i:$i + 20]' "$tmp/keys.json")"
    # Keys come from validated slugs and state.json; checked again before splicing.
    q="$(jq -r '
      def parts: capture("^(?<o>[A-Za-z0-9][A-Za-z0-9-]*)/(?<r>[A-Za-z0-9._-]+)#(?<n>[1-9][0-9]*)$");
      if all(.[]; test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+#[1-9][0-9]*$")) | not
      then error("invalid PR key") else . end
      | "query {\n" + (to_entries | map((.value | parts) as $p
          | "p\(.key): repository(owner: \"\($p.o)\", name: \"\($p.r)\") { pullRequest(number: \($p.n)) { state } }")
        | join("\n")) + "\n}"' <<<"$keys")" || {
      rm -rf "$tmp"
      return 1
    }
    gh api graphql --method POST -f query="$q" >"$tmp/resp-$n.json" 2>"$tmp/err-$n.txt" || true
    # Every PR in the batch stays UNKNOWN (and untouched) without data; say why.
    if ! jq -e '.data | type == "object"' "$tmp/resp-$n.json" >/dev/null 2>&1; then
      warn "couldn't get PR states from GitHub: $(jq -r '[.errors[]?.message] | join("; ")' "$tmp/resp-$n.json" 2>/dev/null || true)$(head -1 "$tmp/err-$n.txt")"
    fi
    jq --argjson keys "$keys" --slurpfile r "$tmp/resp-$n.json" '
      . + ($keys | to_entries | map({key: .value,
        value: (($r[0].data // {})["p\(.key)"].pullRequest.state // "UNKNOWN")}) | from_entries)' \
      "$tmp/states.json" >"$tmp/states.next" 2>/dev/null || cp "$tmp/states.json" "$tmp/states.next"
    mv -f "$tmp/states.next" "$tmp/states.json"
    i=$((i + 20))
    n=$((n + 1))
  done
  cat "$tmp/states.json"
  rm -rf "$tmp"
}

main() {
  local dry=false home key slug wt owner repo number gd states keys removed=0 kept=0 unknown=0
  case "${1:-}" in
    --dry-run) dry=true ;;
    "") ;;
    *) usage ;;
  esac
  [ "$#" -le 1 ] || usage
  require_cmd gh jq git
  home="$(quill_home)"
  [ -d "$home" ] || die "no workspace at $home (run init.sh first)"

  # Every PR quill holds something for.
  keys="$(mktemp "${TMPDIR:-/tmp}/quill-keys.XXXXXX")" || die "can't create a temp file"
  {
    [ ! -f "$home/state.json" ] || jq -r '.prs | keys[]' "$home/state.json"
    if [ -d "$home/worktrees" ]; then
      for wt in "$home/worktrees"/*; do
        [ -d "$wt" ] || continue
        key="$(slug_to_key "$(basename "$wt")")"
        if [ -n "$key" ]; then
          printf '%s\n' "$key"
        else
          warn "leaving $wt alone: its name isn't owner__repo__N"
        fi
      done
    fi
  } | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))' >"$keys"

  states="$(pr_states <"$keys")" || die "couldn't check PR states on GitHub"
  rm -f "$keys"

  while IFS=' ' read -r key state; do
    [ -n "$key" ] || continue
    case "$state" in
      OPEN) kept=$((kept + 1)); continue ;;
      CLOSED | MERGED) ;;
      *)
        warn "leaving $key alone: GitHub didn't say whether it's open"
        unknown=$((unknown + 1))
        continue
        ;;
    esac
    owner="${key%%/*}"
    repo="${key#*/}"
    repo="${repo%%#*}"
    number="${key##*#}"
    slug="$(pr_slug "$owner" "$repo" "$number")"
    if [ "$dry" = true ]; then
      printf 'would remove %s (%s)\n' "$key" "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
      removed=$((removed + 1))
      continue
    fi
    remove_worktree "$owner/$repo" "$number"
    gd="$(repo_git_dir "$owner/$repo")" || continue
    if [ -d "$gd" ]; then
      qgit --git-dir="$gd" for-each-ref --format='%(refname)' "refs/quill/pr/$number/" |
        while IFS= read -r ref; do qgit --git-dir="$gd" update-ref -d "$ref"; done
    fi
    rm -f "$home/post/$slug.json"
    if [ -f "$home/state.json" ]; then
      lock_acquire "$home/.state.lock" 30
      jq --arg k "$key" 'del(.prs[$k])' "$home/state.json" >"$home/state.json.tmp.$$" &&
        mv -f "$home/state.json.tmp.$$" "$home/state.json"
      lock_release "$home/.state.lock"
    fi
    printf 'removed %s (%s)\n' "$key" "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
    removed=$((removed + 1))
  done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$states")

  # Reviewer bindings only matter during a run.
  if [ "$dry" = false ] && [ -d "$home/.agents" ]; then
    find "$home/.agents" -type f -mtime +3 -exec rm -f {} + 2>/dev/null || true
  fi

  printf 'clean: %s %d closed or merged PR(s), kept %d open, %d unknown\n' \
    "$(if [ "$dry" = true ]; then echo "would remove"; else echo removed; fi)" "$removed" "$kept" "$unknown"
}

# Run only when executed, so tests can source the helpers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
