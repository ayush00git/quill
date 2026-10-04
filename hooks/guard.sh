#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# guard.sh: PreToolUse hook. Plugin hooks fire in every session, so this
# returns immediately for anything that isn't quill's own business.
#
# Reviewer branch (agent_type == "quill:pr-reviewer"): the reviewer reads
# untrusted PR content, so it gets read-only access to the workspace and
# nothing else.
#   Read / Grep / Glob  only under $QUILL_HOME/worktrees and $QUILL_HOME/reviews,
#                       never instruction files (CLAUDE.md, AGENTS.md, .claude/)
#   Bash                one plain `git -C <worktree> <sub> ...` with sub in
#                       diff|log|show|blame|range-diff|grep, relative paths only,
#                       and no option that writes, runs or reads other files
#   SubagentHandback    passes through (that's how it reports in auto mode)
#   anything else       denied
# Allowed calls get permissionDecision "allow" so parallel reviewers don't
# stall on prompts. Denials exit 2, which blocks before permission rules run.
#
# Input: the hook JSON on stdin. Output: nothing, an allow decision, or exit 2.

set -Euo pipefail

REVIEWER_AGENT='quill:pr-reviewer'
MAX_COMMAND_LEN=4096
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

deny() {
  printf 'quill guard: %s\n' "$1" >&2
  exit 2
}

# Any exit other than 0 (allow, or pass-through) and 2 (deny) is a non-blocking
# hook error, and Claude Code would run the tool. In the reviewer branch, turn
# every such exit (set -u aborts, a failing jq, ...) into a deny.
guard_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    printf 'quill guard: internal error (exit %s), denying\n' "$rc" >&2
    exit 2
  fi
}

allow() {
  jq -cn --arg r "quill guard: $1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: $r}}'
  exit 0
}

# --- path rules ------------------------------------------------------------

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# is_instruction_path <path>: CLAUDE.md, CLAUDE.local.md, AGENTS.md or
# anything under a .claude directory, in any letter case.
is_instruction_path() {
  case "/$(lower "$1")/" in
    */claude.md/* | */claude.local.md/* | */agents.md/* | */.claude/*) return 0 ;;
  esac
  return 1
}

# check_read_path <path> <what>: absolute or cwd-relative path that must
# resolve inside the reviewer's roots.
check_read_path() {
  local p="$1" what="$2" root ok=1
  [ -n "$p" ] || deny "$what: a path is required (pass the worktree or context path)"
  is_instruction_path "$p" && deny "$what: instruction files are off limits: $p"
  case "$p" in
    /*) ;;
    *) p="$CWD/$p" ;;
  esac
  for root in "$HOME_DIR/worktrees" "$HOME_DIR/reviews"; do
    if path_within "$p" "$root"; then ok=0; fi
  done
  [ "$ok" -eq 0 ] || deny "$what: only paths under $HOME_DIR/worktrees or $HOME_DIR/reviews are readable: $1"
  is_instruction_path "$(resolve_path "$p")" && deny "$what: instruction files are off limits: $1"
  return 0
}

# check_relative_pattern <value> <what>: glob patterns must stay relative.
check_relative_pattern() {
  local v="$1" what="$2"
  [ -n "$v" ] || return 0
  case "$v" in
    /* | '~'*) deny "$what must be relative: $v" ;;
  esac
  case "$v" in
    *..*) deny "$what can't contain '..': $v" ;;
  esac
  is_instruction_path "$v" && deny "$what can't target instruction files: $v"
  return 0
}

# --- git command rules -------------------------------------------------------

# tokenize <command>: split into words the way the shell would, into TOKENS.
# Denies anything the shell would expand or interpret, so every accepted
# word means exactly what it says:
#   unquoted        ; & | < > ( ) { } $ ` \ * ? [ ] ~ and a leading #
#   "double quoted" $ ` \ (the only characters special inside them)
#   'single quoted' literal
tokenize() {
  local s="$1" i=0 n c q="" cur="" in_tok=0
  TOKENS=()
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    i=$((i + 1))
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=""; else cur="$cur$c"; fi
      continue
    fi
    if [ "$q" = '"' ]; then
      case "$c" in
        '"') q="" ;;
        '$' | '`' | "\\") deny "\$, backticks and backslashes aren't allowed inside double quotes; use single quotes" ;;
        *) cur="$cur$c" ;;
      esac
      continue
    fi
    case "$c" in
      ' ')
        if [ "$in_tok" -eq 1 ]; then
          TOKENS+=("$cur")
          cur=""
          in_tok=0
        fi
        ;;
      "'" | '"')
        q="$c"
        in_tok=1
        ;;
      ';' | '&' | '|' | '<' | '>' | '(' | ')' | '{' | '}' | '$' | '`' | "\\")
        deny "only one plain git command is allowed (unquoted $c)"
        ;;
      '*' | '?' | '[' | ']')
        deny "unquoted glob characters aren't allowed; quote the argument"
        ;;
      '~')
        # bash expands ~ at the start of a word and after = or : (HEAD~1 is fine)
        case "$in_tok:${cur: -1}" in
          0:* | 1:= | 1::) deny "'~' isn't allowed; use paths relative to the worktree" ;;
        esac
        cur="$cur$c"
        ;;
      '#')
        [ "$in_tok" -eq 1 ] || deny "comments aren't allowed in commands"
        cur="$cur$c"
        ;;
      *)
        cur="$cur$c"
        in_tok=1
        ;;
    esac
  done
  [ -z "$q" ] || deny "unterminated quote"
  if [ "$in_tok" -eq 1 ]; then TOKENS+=("$cur"); fi
  return 0
}

# Long options that write files, run programs or read files outside the
# repo. Git accepts unambiguous prefixes of long options, so a token is
# rejected when it is a prefix of any of these (e.g. --out, --no-ind).
DENIED_LONG='--output --ext-diff --textconv --no-index --contents --ignore-revs-file
--file --orderfile --open-files-in-pager --stdin --exec-path --git-dir --work-tree
--config-env --show-signature --help'

check_git_token() {
  local sub="$1" t="$2" name d flags
  case "$t" in
    /* | '~'*) deny "absolute paths are only allowed right after -C: $t" ;;
  esac
  case "$t" in
    .. | ../* | */.. | *'/../'* | *=/* | *'=~'*) deny "paths must stay inside the worktree: $t" ;;
  esac
  case "$t" in
    --*)
      name="${t%%=*}"
      [ "$name" != "--" ] || return 0
      for d in $DENIED_LONG; do
        case "$d" in
          "$name"*) deny "git option $name is not allowed (it writes, runs or reads other files)" ;;
        esac
      done
      ;;
    -?*)
      flags="${t#-}"
      [ "$t" != "-o" ] || deny "git option -o is not allowed"
      case "$sub" in
        diff | log | show | range-diff)
          case "$flags" in *O*) deny "git option -O (orderfile) is not allowed: $t" ;; esac
          ;;
        grep)
          case "$flags" in
            *O*) deny "git grep -O (open in pager) is not allowed: $t" ;;
            *f*) deny "git grep -f (patterns from a file) is not allowed: $t" ;;
          esac
          ;;
        blame)
          case "$flags" in *S*) deny "git blame -S (revs file) is not allowed: $t" ;; esac
          ;;
      esac
      ;;
  esac
  return 0
}

check_bash() {
  local cmd="$1" dir sub i
  [ -n "$cmd" ] || deny "empty command"
  # The tokenizer is quadratic in bash, and a PreToolUse hook that times out
  # lets the call through, so cap the length well below that.
  [ "${#cmd}" -le "$MAX_COMMAND_LEN" ] || deny "command too long (max $MAX_COMMAND_LEN characters)"
  # Newlines, tabs and other control characters are never part of a plain command.
  case "$cmd" in
    *[[:cntrl:]]*) deny "control characters (newlines, tabs) aren't allowed in commands" ;;
  esac
  tokenize "$cmd"
  [ "${#TOKENS[@]}" -ge 4 ] || deny "use: git -C <worktree> <diff|log|show|blame|range-diff|grep> ..."
  [ "${TOKENS[0]}" = "git" ] || deny "only git is allowed, as: git -C <worktree> <subcommand> ..."
  i=1
  if [ "${TOKENS[1]}" = "--no-pager" ]; then i=2; fi
  [ "${TOKENS[$i]}" = "-C" ] || deny "start with: git -C <worktree> (no other global options)"
  dir="${TOKENS[$((i + 1))]:-}"
  [ -n "$dir" ] || deny "missing worktree after -C"
  case "$dir" in
    *..*) deny "the -C path can't contain '..': $dir" ;;
    /*) ;;
    *) dir="$CWD/$dir" ;;
  esac
  path_within "$dir" "$HOME_DIR/worktrees" || deny "-C must name a worktree under $HOME_DIR/worktrees: ${TOKENS[$((i + 1))]}"
  # Exactly a worktree root, never a directory inside one: git treats a PR
  # directory shaped like a bare repo (HEAD, objects/, refs/, config) as the
  # repository and obeys its config, e.g. a textconv command run by log -p.
  [ "$(dirname "$(resolve_path "$dir")")" = "$(resolve_path "$HOME_DIR/worktrees")" ] ||
    deny "-C must name a worktree root, $HOME_DIR/worktrees/<name>, not a directory inside it"
  i=$((i + 2))
  sub="${TOKENS[$i]:-}"
  case "$sub" in
    diff | log | show | blame | range-diff | grep) ;;
    *) deny "git $sub is not allowed; use diff, log, show, blame, range-diff or grep" ;;
  esac
  i=$((i + 1))
  while [ "$i" -lt "${#TOKENS[@]}" ]; do
    check_git_token "$sub" "${TOKENS[$i]}"
    i=$((i + 1))
  done
  return 0
}

# --- dispatch ----------------------------------------------------------------

reviewer_branch() {
  local tool="$1"
  case "$tool" in
    Read)
      check_read_path "$(jq -r '.file_path // ""' <<<"$INPUT_TOOL")" "Read"
      allow "read-only workspace read"
      ;;
    Grep)
      check_read_path "$(jq -r '.path // ""' <<<"$INPUT_TOOL")" "Grep path"
      check_relative_pattern "$(jq -r '.glob // ""' <<<"$INPUT_TOOL")" "Grep glob"
      allow "read-only workspace search"
      ;;
    Glob)
      check_read_path "$(jq -r '.path // ""' <<<"$INPUT_TOOL")" "Glob path"
      check_relative_pattern "$(jq -r '.pattern // ""' <<<"$INPUT_TOOL")" "Glob pattern"
      allow "read-only workspace glob"
      ;;
    Bash)
      [ "$(jq -r '.run_in_background // false' <<<"$INPUT_TOOL")" != "true" ] ||
        deny "background commands aren't allowed"
      check_bash "$(jq -r '.command // ""' <<<"$INPUT_TOOL")"
      allow "read-only git"
      ;;
    SubagentHandback)
      exit 0
      ;;
    *)
      deny "pr-reviewer may only use Read, Grep, Glob and read-only git (tried $tool)"
      ;;
  esac
}

main() {
  local raw agent tool
  raw="$(cat)"
  # One jq call on the hot path: this hook runs before every tool call.
  if ! agent="$(jq -er 'if type == "object" then (.agent_type // "") else error("not an object") end' 2>/dev/null <<<"$raw")"; then
    # Can't parse the event. Fail closed for the reviewer, stay out of the way otherwise.
    case "$raw" in *"$REVIEWER_AGENT"*) deny "couldn't parse hook input" ;; esac
    exit 0
  fi
  [ "$agent" = "$REVIEWER_AGENT" ] || exit 0

  # From here on every failure denies.
  trap guard_exit EXIT
  trap 'deny "internal error"' ERR
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$GUARD_DIR/../skills/quill/scripts/lib/common.sh"
  HOME_DIR="$(quill_home)"
  CWD="$(jq -r '.cwd // ""' <<<"$raw")"
  [ -n "$CWD" ] || CWD="$PWD"
  tool="$(jq -r '.tool_name // ""' <<<"$raw")"
  INPUT_TOOL="$(jq -c '.tool_input // {}' <<<"$raw")"
  reviewer_branch "$tool"
}

# Run only when executed, so tests can source the helpers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
