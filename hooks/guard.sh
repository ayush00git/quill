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
# Each reviewer is bound to one PR: its first read of a bundle's task.json
# (reviews/<date>/.run/<run>/ctx/<slug>/task.json) records the binding in
# $QUILL_HOME/.agents/<agent_id>. From then on it may read only that bundle,
# that run's refs/, and the one worktree named in that task.json, and
# `git -C` must be that worktree. So a reviewer steered by one PR can't read
# another PR's bundle (its nonce) and forge that PR's review; capture.sh
# rejects reports that don't match the binding.
# Allowed calls get permissionDecision "allow" so parallel reviewers don't
# stall on prompts. Denials exit 2, which blocks before permission rules run.
#
# Every other session, Bash:
#   post.sh --submit    always "ask": creating the pending GitHub review needs
#                       the user's explicit OK, in every session and directory.
#                       Detected on the command with quotes and backslashes
#                       stripped, and also when post.sh or --submit appears
#                       next to $(...), ${...}, backticks or eval.
#   run-tests.sh        "ask": it runs the PRs' own code (in a container), so
#                       the user OKs it once per run. The one exception is a
#                       scheduled run that opted in: QUILL_HEADLESS set and
#                       config tests.headless true (run-tests.sh re-checks).
#   inside $QUILL_HOME  allow-explicit. "allow" only for exactly one simple
#                       command that is quill's own script (by real path) or a
#                       read-only ls/cat/head/tail/wc/jq on workspace files
#                       outside worktrees/ and repos/. Hard deny: printing the
#                       gh token (gh auth token, --show-token, auth status -t)
#                       and git push/send-pack/http-push. Everything else asks,
#                       so text from a PR can't run anything without a human.
# Every other session, Write / Edit / MultiEdit / NotebookEdit:
#   "ask" for the files that decide what quill and Claude Code may do in the
#   workspace: config.json and .mcp.json, and CLAUDE.md, CLAUDE.local.md,
#   AGENTS.md and .claude/ at any depth (they auto-load from subdirectories).
#   Otherwise acceptEdits or auto mode could let text from a PR opt scheduled
#   runs into running tests, or loosen the workspace's permissions.
#
# Input: the hook JSON on stdin. Output: nothing, an allow or ask decision,
# or exit 2 (deny).

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
  p="$(resolve_path "$p")" || deny "$what: can't resolve $1"
  is_instruction_path "$p" && deny "$what: instruction files are off limits: $1"
  check_binding "$p" "$what"
  return 0
}

# --- one PR per reviewer --------------------------------------------------------

# bound_ctx: the bundle this agent is bound to, or nothing.
bound_ctx() {
  [ -f "$AGENTS_DIR/$AGENT_ID" ] || return 0
  head -1 "$AGENTS_DIR/$AGENT_ID"
}

bind_to() {
  mkdir -p "$AGENTS_DIR"
  printf '%s\n' "$1" >"$AGENTS_DIR/$AGENT_ID.tmp.$$"
  mv -f "$AGENTS_DIR/$AGENT_ID.tmp.$$" "$AGENTS_DIR/$AGENT_ID"
}

# bound_worktree: the resolved worktree from the bound bundle's task.json.
bound_worktree() {
  local ctx wt
  ctx="$(bound_ctx)"
  [ -n "$ctx" ] || return 0
  wt="$(jq -r '.worktree // ""' "$ctx/task.json")" || return 1
  [ -n "$wt" ] || return 0
  resolve_path "$wt"
}

# check_binding <resolved path> <what>: the one-PR rule for a path that is
# already known to be under worktrees/ or reviews/.
check_binding() {
  local p="$1" what="$2" rel date dotrun run kind slug ctx bound wt
  bound="$(bound_ctx)"
  case "$p" in
    "$R_REVIEWS") deny "$what: name your PR's context bundle, not the whole reviews directory" ;;
    "$R_REVIEWS"/*)
      rel="${p#"$R_REVIEWS"/}"
      IFS=/ read -r date dotrun run kind slug _ <<<"$rel"
      if [ "$dotrun" != ".run" ] || [ -z "$run" ] || [ -z "$kind" ]; then
        deny "$what: only your PR's context bundle and the run's references are readable: $p"
      fi
      case "$kind" in
        refs)
          [ -n "$bound" ] || deny "$what: read your task.json first"
          [ "$(dirname "$(dirname "$bound")")" = "$R_REVIEWS/$date/.run/$run" ] ||
            deny "$what: only the references of your own run are readable"
          ;;
        ctx)
          [ -n "$slug" ] || deny "$what: name your PR's bundle, not the ctx directory"
          ctx="$R_REVIEWS/$date/.run/$run/ctx/$slug"
          if [ -z "$bound" ]; then
            [ "$p" = "$ctx/task.json" ] || deny "$what: read your task.json first ($ctx/task.json)"
            [ -f "$p" ] || deny "$what: no task.json at $p"
            bind_to "$ctx"
            bound="$ctx"
          fi
          [ "$bound" = "$ctx" ] || deny "$what: you review $(basename "$bound") only; $slug belongs to another reviewer"
          ;;
        *) deny "$what: only your PR's context bundle and the run's references are readable: $p" ;;
      esac
      ;;
    "$R_WORKTREES" | "$R_WORKTREES"/*)
      [ -n "$bound" ] || deny "$what: read your task.json first"
      wt="$(bound_worktree)" || deny "$what: can't read the worktree from your task.json"
      [ -n "$wt" ] || deny "$what: your task.json names no worktree"
      case "$p" in
        "$wt" | "$wt"/*) ;;
        *) deny "$what: only your PR's worktree ($wt) is readable" ;;
      esac
      ;;
  esac
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

# _tok_err <message>: a tokenizer failure. Denies, unless TOK_SOFT=1 (the
# session allowlist), where it only means "not a plain command".
TOK_SOFT=0
_tok_err() {
  [ "$TOK_SOFT" = 1 ] || deny "$1"
  # The caller returns 1; returning 0 here keeps an ERR trap from firing.
  return 0
}

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
        '$' | '`' | "\\") { _tok_err "\$, backticks and backslashes aren't allowed inside double quotes; use single quotes"; return 1; } ;;
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
        { _tok_err "only one plain git command is allowed (unquoted $c)"; return 1; }
        ;;
      '*' | '?' | '[' | ']')
        { _tok_err "unquoted glob characters aren't allowed; quote the argument"; return 1; }
        ;;
      '~')
        # bash expands ~ at the start of a word and after = or : (HEAD~1 is fine)
        case "$in_tok:${cur: -1}" in
          0:* | 1:= | 1::) { _tok_err "'~' isn't allowed; use paths relative to the worktree"; return 1; } ;;
        esac
        cur="$cur$c"
        ;;
      '#')
        [ "$in_tok" -eq 1 ] || { _tok_err "comments aren't allowed in commands"; return 1; }
        cur="$cur$c"
        ;;
      *)
        cur="$cur$c"
        in_tok=1
        ;;
    esac
  done
  [ -z "$q" ] || { _tok_err "unterminated quote"; return 1; }
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
  local sub="$1" t="$2" pattern="${3:-0}" name d flags
  # A pattern value (see is_pattern_option) skips only the path rules: git
  # reads it as a regex, not a file. The denied-option list still applies.
  if [ "$pattern" != 1 ]; then
    case "$t" in
      /* | '~'*) deny "absolute paths are only allowed right after -C: $t" ;;
    esac
    case "$t" in
      .. | ../* | */.. | *'/../'* | *=/* | *'=~'*) deny "paths must stay inside the worktree: $t" ;;
    esac
  fi
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

# pattern_option <sub> <token>: prints "next" when the token is an option
# whose value is the following token and is a pattern (not a path), "self"
# when the value is attached to the token, nothing otherwise. Only the forms
# git really reads as patterns: grep -e; log/show -G, -S, --grep, --author,
# --committer; diff -G, -S. (blame -S is a file and stays a path.)
pattern_option() {
  case "$1:$2" in
    grep:-e | log:-G | log:-S | log:--grep | log:--author | log:--committer | \
      show:-G | show:-S | show:--grep | show:--author | show:--committer | diff:-G | diff:-S)
      echo next ;;
    grep:-e?* | log:-G?* | log:-S?* | show:-G?* | show:-S?* | diff:-G?* | diff:-S?* | \
      log:--grep=* | log:--author=* | log:--committer=* | show:--grep=* | show:--author=* | show:--committer=*)
      echo self ;;
  esac
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
  tokenize "$cmd" || deny "couldn't parse the command"
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
  [ "$(dirname "$(resolve_path "$dir")")" = "$R_WORKTREES" ] ||
    deny "-C must name a worktree root, $HOME_DIR/worktrees/<name>, not a directory inside it"
  local wt
  wt="$(bound_worktree)" || deny "can't read the worktree from your task.json"
  [ -n "$wt" ] || deny "read your task.json first"
  [ "$(resolve_path "$dir")" = "$wt" ] || deny "-C must be your PR's worktree: $wt"
  i=$((i + 2))
  sub="${TOKENS[$i]:-}"
  case "$sub" in
    diff | log | show | blame | range-diff | grep) ;;
    *) deny "git $sub is not allowed; use diff, log, show, blame, range-diff or grep" ;;
  esac
  i=$((i + 1))
  local kind
  while [ "$i" -lt "${#TOKENS[@]}" ]; do
    kind="$(pattern_option "$sub" "${TOKENS[$i]}")"
    case "$kind" in
      next)
        check_git_token "$sub" "${TOKENS[$i]}"
        i=$((i + 1))
        # exactly one value token is a pattern; everything after is checked as usual
        [ "$i" -lt "${#TOKENS[@]}" ] || deny "${TOKENS[$((i - 1))]} needs a value"
        check_git_token "$sub" "${TOKENS[$i]}" 1
        ;;
      self) check_git_token "$sub" "${TOKENS[$i]}" 1 ;;
      *) check_git_token "$sub" "${TOKENS[$i]}" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# --- every session: the posting gate; in the workspace, allow-explicit -----------

# Quill's own scripts: the only commands the workspace allows without asking.
QUILL_SCRIPTS='init.sh queue.sh prepare.sh save-review.sh render-queue.sh run-tests.sh post.sh clean.sh'

# Options the read-only commands may use (anything else asks).
JQ_SAFE_OPTIONS='-r -c -e -s -n -S -M -j -a --raw-output --compact-output --exit-status --slurp
--null-input --sort-keys --join-output --ascii-output --tab'

ask() {
  jq -cn --arg r "quill guard: $1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# Inside the workspace an internal error asks rather than passing silently.
session_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"quill guard: internal error while checking this command"}}'
    exit 0
  fi
}

# norm_command <cmd>: the command without quotes or backslashes, so quoting
# tricks (po""st.sh, post\.sh, '--sub'mit) can't hide words from the checks.
norm_command() {
  local c="$1"
  c="${c//\"/}"
  c="${c//\'/}"
  c="${c//\\/}"
  printf '%s' "$c"
}

# check_post_gate <normalized command> [in workspace]: ask before anything
# that may run post.sh --submit. Inside the workspace any --submit asks (a
# renamed copy of post.sh), and so does --sub next to a variable.
check_post_gate() {
  local n="$1" in_ws="${2:-0}" post=0 submit=0 dynamic=0
  case "$n" in *post.sh*) post=1 ;; esac
  case "$n" in *--submit*) submit=1 ;; esac
  # shellcheck disable=SC2016 # literal $( and ${ in the command text
  case "$n" in *'$('* | *'${'* | *'`'* | *eval*) dynamic=1 ;; esac
  if [ "$in_ws" = 1 ]; then
    case "$n" in *'$'*) dynamic=1 ;; esac
    case "$n" in *--sub*) [ "$dynamic" = 0 ] || submit=1 ;; esac
    [ "$submit" = 0 ] || post=1
  fi
  if [ "$post$submit" = 11 ] || [ "$post$dynamic" = 11 ] || [ "$submit$dynamic" = 11 ]; then
    ask "this creates a pending review on GitHub. Check the exact comments quill showed you before approving."
  fi
  return 0
}

# hard_deny <normalized command>: never in the workspace, even if approved:
# printing the gh token (curl could then write with it) and pushing.
hard_deny() {
  local words w prev="" git=0 auth_status=0
  local -a W
  # , [ ] split list literals like system("gh","auth","token").
  # shellcheck disable=SC2020 # equal-length sets: BSD tr doesn't pad
  words="$(printf '%s\n' "$1" | tr ';&|(){}`<>,\133\135\t' '              ')" ||
    deny "couldn't parse the command"
  read -r -a W <<<"$(printf '%s' "$words" | tr '\n' ' ')" || true
  for w in ${W[@]+"${W[@]}"}; do
    case "${w##*/}" in git) git=1 ;; esac
    case "$prev:$w" in
      auth:token) deny "gh auth token would print your GitHub token" ;;
      auth:status) auth_status=1 ;;
    esac
    case "$w" in
      --show-token | --show-token=*) deny "--show-token would print your GitHub token" ;;
      send-pack | http-push | receive-pack) deny "git $w isn't allowed in the quill workspace" ;;
    esac
    if [ "$auth_status" = 1 ]; then
      case "$w" in
        --*) ;;
        -*t*) deny "gh auth status $w would print your GitHub token" ;;
      esac
    fi
    if [ "$git" = 1 ] && [ "$w" = push ]; then
      deny "git push isn't allowed in the quill workspace"
    fi
    prev="$w"
  done
  return 0
}

# readonly_args <takes a filter: 0|1> <args...>: safe options, numbers, and
# files inside the workspace but outside worktrees/ and repos/ (PR content).
readonly_args() {
  local filter="$1" w p
  shift
  for w in "$@"; do
    case "$w" in
      --) continue ;;
      -*)
        if [ "$filter" = 1 ]; then
          case " $(printf '%s' "$JQ_SAFE_OPTIONS" | tr '\n' ' ') " in *" $w "*) continue ;; esac
          return 1
        fi
        case "$w" in
          *=* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-]*) return 1 ;;
        esac
        continue
        ;;
      *[!0123456789]*) ;;
      *) continue ;; # a number (head -n 20)
    esac
    if [ "$filter" = 1 ]; then
      filter=0 # the jq program itself
      # env / $ENV read environment secrets (GH_TOKEN), import / include
      # read files outside the workspace: those ask instead.
      case "$w" in *env* | *ENV* | *import* | *include*) return 1 ;; esac
      continue
    fi
    case "$w" in /*) p="$w" ;; *) p="$CWD/$w" ;; esac
    p="$(resolve_path "$p")" || return 1
    path_within "$p" "$R_HOME" || return 1
    case "$p" in "$R_WORKTREES" | "$R_WORKTREES"/* | "$R_REPOS" | "$R_REPOS"/*) return 1 ;; esac
  done
  return 0
}

# allowed_command <command>: exactly one simple command that is one of quill's
# own scripts (by real path) or a read-only look at workspace files. Sets
# ALLOWED_SCRIPT to the script's name, or empty.
allowed_command() {
  local cmd="$1" a0 r name
  ALLOWED_SCRIPT=""
  [ "${#cmd}" -le "$MAX_COMMAND_LEN" ] || return 1
  case "$cmd" in *[[:cntrl:]]*) return 1 ;; esac
  TOK_SOFT=1
  if ! tokenize "$cmd"; then
    TOK_SOFT=0
    return 1
  fi
  TOK_SOFT=0
  [ "${#TOKENS[@]}" -ge 1 ] || return 1
  a0="${TOKENS[0]}"
  case "$a0" in
    */*)
      case "$a0" in /*) r="$a0" ;; *) r="$CWD/$a0" ;; esac
      r="$(resolve_path "$r")" || return 1
      for name in $QUILL_SCRIPTS; do
        if [ "$r" = "$R_SCRIPTS/$name" ]; then
          ALLOWED_SCRIPT="$name"
          return 0
        fi
      done
      return 1
      ;;
    ls | cat | head | tail | wc) readonly_args 0 ${TOKENS[@]+"${TOKENS[@]:1}"} ;;
    jq) readonly_args 1 ${TOKENS[@]+"${TOKENS[@]:1}"} ;;
    *) return 1 ;;
  esac
}

TESTS_ASK="this runs the PRs' own code (their tests) in a container. Approve it only if you asked for --run-tests; one approval covers every PR in this run."

# headless_tests_ok: a scheduled run whose maintainer opted in to tests.
headless_tests_ok() {
  [ -n "${QUILL_HEADLESS:-}" ] || return 1
  [ "$(config_json 2>/dev/null | jq -r '.tests.headless == true' 2>/dev/null)" = true ]
}

# check_tests_gate <normalized command>: outside the workspace, ask before
# anything that names quill's run-tests.sh. Inside it, allow-explicit finds
# run-tests.sh by real path (session_branch).
check_tests_gate() {
  case "$1" in *skills/quill/scripts/run-tests.sh*) ask "$TESTS_ASK" ;; esac
  return 0
}

session_branch() {
  local raw="$1" cmd norm home
  if ! cmd="$(jq -r '.tool_input.command // ""' <<<"$raw")"; then
    # Can't read the command: if it might be the post, ask rather than pass.
    case "$raw" in *post.sh* | *--submit*) ask "couldn't parse this command; it may post to GitHub" ;; esac
    exit 0
  fi
  norm="$(norm_command "$cmd")"
  home=""
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  if source "$GUARD_DIR/../skills/quill/scripts/lib/common.sh"; then
    home="$(quill_home 2>/dev/null)" || home=""
  fi
  CWD="$(jq -r '.cwd // ""' <<<"$raw")" || CWD=""
  [ -n "$CWD" ] || CWD="$PWD"
  if [ -z "$home" ] || [ ! -d "$home" ] || ! path_within "$CWD" "$home"; then
    check_post_gate "$norm" 0
    check_tests_gate "$norm"
    exit 0
  fi

  # Inside the workspace: allow quill's own commands, hard-deny a few things,
  # and ask about everything else. A text check can't out-think bash
  # (aliases, variables, interpreters, copied scripts), but an allowlist
  # fails safe: to a human prompt. Ask still prompts in auto mode and counts
  # as a denial in headless runs, which therefore work through the scripts.
  trap session_exit EXIT
  trap 'ask "internal error while checking this command"' ERR
  R_HOME="$(resolve_path "$home")"
  R_WORKTREES="$(resolve_path "$home/worktrees")"
  R_REPOS="$(resolve_path "$home/repos")"
  R_SCRIPTS="$(resolve_path "$GUARD_DIR/../skills/quill/scripts")"
  hard_deny "$norm"
  check_post_gate "$norm" 1
  if allowed_command "$cmd"; then
    # run-tests.sh runs the PRs' own code, so it asks, found by real path so
    # a link under another name asks too. A scheduled run that opted in is
    # the exception (run-tests.sh checks the same two things again).
    if [ "$ALLOWED_SCRIPT" = run-tests.sh ]; then
      if headless_tests_ok; then
        allow "scheduled run with tests.headless: true"
      fi
      ask "$TESTS_ASK"
    fi
    allow "one of quill's own commands"
  fi
  ask "this isn't one of quill's own commands. In the quill workspace every other command needs your OK, so text from a PR can't run anything on its own."
}

# Files that decide what quill and Claude Code may do in the workspace (lower
# case: macOS file systems ignore case): config.json and .mcp.json at the top,
# and instruction files at ANY depth, because Claude Code loads a nested
# CLAUDE.md, CLAUDE.local.md, AGENTS.md or .claude/ when it reads files there.
is_protected_rel() {
  case "/$1/" in
    /config.json/ | /.mcp.json/ | */.claude/* | */claude.md/ | */claude.local.md/ | */agents.md/) return 0 ;;
  esac
  return 1
}

# write_branch <hook json>: Write / Edit / MultiEdit / NotebookEdit in any
# session. Ask before changing a protected workspace file; pass otherwise.
write_branch() {
  local raw="$1" path home cwd p rh lp lh rel f
  path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$raw" 2>/dev/null)" || exit 0
  [ -n "$path" ] || exit 0
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$GUARD_DIR/../skills/quill/scripts/lib/common.sh" || exit 0
  home="$(quill_home 2>/dev/null)" || exit 0
  [ -d "$home" ] || exit 0
  # No ERR trap here: with errtrace it would fire inside $(...) and hand its
  # output back as the path. Failures are checked explicitly and ask.
  trap session_exit EXIT
  cwd="$(jq -r '.cwd // ""' <<<"$raw")" || cwd=""
  [ -n "$cwd" ] || cwd="$PWD"
  case "$path" in /*) p="$path" ;; *) p="$cwd/$path" ;; esac
  p="$(resolve_path "$p")" || p=""
  rh="$(resolve_path "$home")" || rh=""
  case "$p:$rh" in
    /*:/*) ;;
    *) ask "couldn't work out which file this edits; approve only if it isn't the quill workspace's settings." ;;
  esac
  lp="$(lower "$p")"
  lh="$(lower "$rh")"
  rel=""
  case "$lp" in "$lh"/*) rel="${lp#"$lh"/}" ;; esac
  if [ -n "$rel" ] && is_protected_rel "$rel"; then
    ask "this edits $rel in the quill workspace, which decides what quill and Claude Code may do there. Approve only a change you asked for: text from a PR could try to turn off a check, plant instructions, or opt scheduled runs into running tests."
  fi
  # The same file under another name (a hard link, or a path through a link).
  if [ -e "$p" ]; then
    for f in config.json .claude/settings.json .claude/settings.local.json CLAUDE.md CLAUDE.local.md AGENTS.md .mcp.json; do
      if [ -e "$rh/$f" ] && [ "$p" -ef "$rh/$f" ]; then
        ask "this edits the quill workspace's $f (through another path). Approve only a change you asked for."
      fi
    done
  fi
  exit 0
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
  local raw meta agent tool
  raw="$(cat)"
  # One jq call on the hot path: this hook runs before every tool call.
  if ! meta="$(jq -er 'if type == "object" then [(.agent_type // ""), (.tool_name // "")] | @tsv
      else error("not an object") end' 2>/dev/null <<<"$raw")"; then
    # Can't parse the event. Fail closed for the reviewer, stay out of the way otherwise.
    case "$raw" in *"$REVIEWER_AGENT"*) deny "couldn't parse hook input" ;; esac
    exit 0
  fi
  agent="${meta%%$'\t'*}"
  tool="${meta#*$'\t'}"
  if [ "$agent" != "$REVIEWER_AGENT" ]; then
    case "$tool" in
      Bash) session_branch "$raw" ;;
      Write | Edit | MultiEdit | NotebookEdit) write_branch "$raw" ;;
      *) exit 0 ;;
    esac
  fi

  # From here on every failure denies.
  trap guard_exit EXIT
  trap 'deny "internal error"' ERR
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$GUARD_DIR/../skills/quill/scripts/lib/common.sh"
  HOME_DIR="$(quill_home)"
  R_REVIEWS="$(resolve_path "$HOME_DIR/reviews")"
  R_WORKTREES="$(resolve_path "$HOME_DIR/worktrees")"
  AGENTS_DIR="$HOME_DIR/.agents"
  AGENT_ID="$(jq -r '.agent_id // ""' <<<"$raw")"
  # Explicit character list: bash 3.2 matches ranges like a-z by locale
  # collation, so ranges in patterns aren't reliable.
  case "$AGENT_ID" in
    '' | .* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
      deny "missing or malformed agent_id" ;;
  esac
  [ "${#AGENT_ID}" -le 128 ] || deny "malformed agent_id"
  CWD="$(jq -r '.cwd // ""' <<<"$raw")"
  [ -n "$CWD" ] || CWD="$PWD"
  INPUT_TOOL="$(jq -c '.tool_input // {}' <<<"$raw")"
  reviewer_branch "$tool"
}

# Run only when executed, so tests can source the helpers.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
