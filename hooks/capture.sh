#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# capture.sh: save each pr-reviewer's final report into its PR's context
# bundle, so the orchestrator never has to re-type it (and PR-derived text
# never lands on a shell command line).
#
# The report arrives in one of two ways:
#   auto mode    PreToolUse on SubagentHandback: tool_input.message
#                (last_assistant_message is then NOT the report)
#   other modes  SubagentStop: last_assistant_message
# The report's first SUMMARY marker carries the nonce from the PR's
# task.json; that's how capture finds where it belongs:
#   <run>/ctx/<slug>/output.raw   the raw final message, first valid one wins
#
# This hook observes; it never blocks anything. It always exits 0, prints
# nothing to stdout, and logs to $QUILL_HOME/logs/capture.log.
set -uo pipefail

REVIEWER_AGENT='quill:pr-reviewer'
CAPTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE_MAX_BYTES=2000000

# Whatever happens, never fail or block the tool call / subagent stop.
trap 'exit 0' EXIT

clog() {
  local logdir="$1"
  shift
  mkdir -p "$logdir" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$logdir/capture.log" 2>/dev/null || true
}

# find_ctx_for_nonce <workspace> <nonce>: the bundle dir whose task.json has
# this nonce (recent runs only).
find_ctx_for_nonce() {
  local home="$1" nonce="$2" task
  find "$home/reviews" -path '*/.run/*/ctx/*/task.json' -mtime -3 -print 2>/dev/null |
    while IFS= read -r task; do
      grep -qF "$nonce" "$task" 2>/dev/null || continue
      if [ "$(jq -r '.nonce // ""' "$task" 2>/dev/null)" = "$nonce" ]; then
        dirname "$task"
        break
      fi
    done
}

main() {
  local raw event agent tool message nonce home ctx agent_id bound out
  raw="$(head -c $((CAPTURE_MAX_BYTES * 2)) 2>/dev/null)"
  command -v jq >/dev/null 2>&1 || return 0
  agent="$(jq -r '.agent_type // ""' 2>/dev/null <<<"$raw")" || return 0
  [ "$agent" = "$REVIEWER_AGENT" ] || return 0
  event="$(jq -r '.hook_event_name // ""' <<<"$raw")" || return 0
  case "$event" in
    PreToolUse)
      tool="$(jq -r '.tool_name // ""' <<<"$raw")"
      [ "$tool" = "SubagentHandback" ] || return 0
      message="$(jq -r '.tool_input.message // ""' <<<"$raw")"
      ;;
    SubagentStop)
      message="$(jq -r '.last_assistant_message // ""' <<<"$raw")"
      ;;
    *) return 0 ;;
  esac
  agent_id="$(jq -r '.agent_id // ""' <<<"$raw")"

  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$CAPTURE_DIR/../skills/quill/scripts/lib/common.sh" || return 0
  home="$(quill_home 2>/dev/null)" || return 0

  if [ "${#message}" -gt "$CAPTURE_MAX_BYTES" ]; then
    clog "$home/logs" "event=$event agent=$agent_id rejected: report over $CAPTURE_MAX_BYTES bytes"
    return 0
  fi
  # Every SUMMARY marker in order. The reviewer may quote PR text that holds a
  # marker with some other nonce; the report belongs to the first nonce that
  # has an END marker and a bundle, so a planted marker can't hide it.
  local candidates c
  candidates="$(printf '%s\n' "$message" | sed -n 's/^<<<QUILL \([0-9a-f]\{32\}\) SUMMARY>>>$/\1/p' | head -20)"
  if [ -z "$candidates" ]; then
    # Normal for SubagentStop in auto mode: the report went through the handback.
    clog "$home/logs" "event=$event agent=$agent_id ignored: no SUMMARY marker"
    return 0
  fi
  nonce=""
  ctx=""
  for c in $candidates; do
    printf '%s\n' "$message" | grep -qxF "<<<QUILL $c END>>>" || continue
    ctx="$(find_ctx_for_nonce "$home" "$c")"
    if [ -n "$ctx" ] && path_within "$ctx" "$home/reviews"; then
      nonce="$c"
      break
    fi
    ctx=""
  done
  if [ -z "$nonce" ]; then
    clog "$home/logs" "event=$event agent=$agent_id rejected: no SUMMARY marker with an END marker and a matching bundle"
    return 0
  fi

  # If the guard bound this agent to a PR, the report must be for that PR.
  bound=""
  if [ -n "$agent_id" ] && [ -f "$home/.agents/$agent_id" ]; then
    bound="$(head -1 "$home/.agents/$agent_id")"
    # The guard records the resolved path; compare resolved to resolved, or a
    # symlinked workspace would reject every legitimate report.
    if [ "$(resolve_path "$bound" 2>/dev/null)" != "$(resolve_path "$ctx" 2>/dev/null)" ]; then
      clog "$home/logs" "event=$event agent=$agent_id nonce=$nonce rejected: agent is bound to $bound"
      return 0
    fi
  fi

  out="$ctx/output.raw"
  if [ -s "$out" ]; then
    clog "$home/logs" "event=$event agent=$agent_id nonce=$nonce ignored: $out already captured"
    return 0
  fi
  if printf '%s\n' "$message" | write_atomic "$out" 2>/dev/null; then
    clog "$home/logs" "event=$event agent=$agent_id nonce=$nonce captured: $out"
  fi
  return 0
}

main "$@"
