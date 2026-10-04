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
# Every other session (Bash only):
#   post.sh --submit    always "ask": creating the pending GitHub review needs
#                       the user's explicit OK, in every session and directory.
#                       Detected on the command with quotes and backslashes
#                       stripped, and also when post.sh or --submit appears
#                       next to $(...), ${...}, backticks or eval.
#   inside $QUILL_HOME  gh is an allowlist: auth status, search,
#                       pr view|list|diff|checks, and api with GET only (no
#                       -X/--method other than GET, no -f/-F/--field/
#                       --raw-field/--input, no "mutation"). gh nested inside
#                       a shell (bash -c, eval, ...) is denied. git push is
#                       denied, and git -C under worktrees/ must name a
#                       worktree root. This is defense in depth against review
#                       text steering the orchestrator, not a security boundary.
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
  while [ "$i" -lt "${#TOKENS[@]}" ]; do
    check_git_token "$sub" "${TOKENS[$i]}"
    i=$((i + 1))
  done
  return 0
}

# --- every session: the posting gate and the workspace allowlist ------------------

ask() {
  jq -cn --arg r "quill guard: $1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
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

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# check_gh <args...>: the workspace allowlist for gh.
check_gh() {
  local a1="${1:-}" a2="${2:-}" w next method
  case "$a1" in
    auth)
      [ "$a2" = status ] || deny "gh auth $a2 isn't allowed in the quill workspace (only gh auth status)"
      # --show-token prints the token, which is as good as gh auth token
      for w in "$@"; do
        case "$w" in
          --show-token | --show-token=*) deny "gh auth status $w would print the token" ;;
          --*) ;;
          -*t*) deny "gh auth status $w would print the token" ;;
        esac
      done
      ;;
    search) ;;
    pr)
      case "$a2" in
        view | list | diff | checks) ;;
        *) deny "gh pr $a2 isn't allowed in the quill workspace; posting goes through /quill:quill post" ;;
      esac
      ;;
    api)
      next=""
      for w in "$@"; do
        if [ "$next" = method ]; then
          method="$(upper "$w")"
          [ "$method" = GET ] || deny "gh api with method $w isn't allowed in the quill workspace (GET only)"
          next=""
          continue
        fi
        case "$w" in
          -X | --method) next=method ;;
          --method=*) [ "$(upper "${w#--method=}")" = GET ] || deny "gh api $w isn't allowed in the quill workspace (GET only)" ;;
          -X?*) [ "$(upper "${w#-X}")" = GET ] || deny "gh api $w isn't allowed in the quill workspace (GET only)" ;;
          -f* | -F* | --field | --field=* | --raw-field | --raw-field=* | --input | --input=*)
            deny "gh api $w isn't allowed in the quill workspace (it sends a request body)" ;;
        esac
        case "$(upper "$w")" in
          *MUTATION*) deny "GraphQL mutations aren't allowed in the quill workspace" ;;
        esac
      done
      ;;
    *) deny "gh $a1 isn't allowed in the quill workspace (allowed: auth status, search, pr view|list|diff|checks, api GET)" ;;
  esac
  return 0
}

# check_git <args...>: no push; git -C under worktrees/ only at a worktree root.
check_git() {
  local dir r w
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C)
        dir="${2:-}"
        case "$dir" in /*) ;; *) dir="$CWD/$dir" ;; esac
        r="$(resolve_path "$dir")" || deny "can't resolve git -C $2"
        case "$r" in
          "$R_WORKTREES"/*)
            [ "$(dirname "$r")" = "$R_WORKTREES" ] ||
              deny "git -C inside a worktree must name the worktree root, not $2"
            ;;
        esac
        shift 2 || break
        ;;
      -c | -c* | --config-env | --config-env=*) deny "git $1 isn't allowed in the quill workspace (a config alias could push)" ;;
      --git-dir | --work-tree | --namespace | --exec-path | --super-prefix) shift 2 || break ;;
      -*) shift ;;
      push | send-pack | http-push) deny "git $1 isn't allowed in the quill workspace" ;;
      subtree)
        shift
        for w in "$@"; do [ "$w" != push ] || deny "git subtree push isn't allowed in the quill workspace"; done
        break
        ;;
      *) break ;;
    esac
  done
  return 0
}

# check_workspace_command <normalized command>: split into simple commands
# and check each one's gh and git use.
check_workspace_command() {
  local seg first i n w segs
  local -a W
  # Split first and check it worked: a failed split must not look like
  # "nothing to check". Every separator becomes a newline; the tr sets have
  # equal length on purpose (BSD tr doesn't pad a shorter second set).
  # shellcheck disable=SC2020
  # , [ ] split list literals like system("gh","api") or run(['gh','api']).
  segs="$(printf '%s\n' "$1" | tr ';&|(){}`<>,\133\135' '\n\n\n\n\n\n\n\n\n\n\n\n\n')" ||
    deny "couldn't parse the command"
  while IFS= read -r seg; do
    read -r -a W <<<"$seg" || true
    n="${#W[@]}"
    [ "$n" -gt 0 ] || continue
    i=0
    # Skip assignments and wrappers to find the command that runs.
    while [ "$i" -lt "$n" ]; do
      w="${W[$i]}"
      case "$w" in
        env | command | builtin | exec | nohup | time | nice | stdbuf | xargs | sudo | doas | timeout | -* | [0123456789]*) i=$((i + 1)) ;;
        *=*) case "${w%%=*}" in *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) break ;; *) i=$((i + 1)) ;; esac ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    case "${W[$i]}" in
      *'$'*) deny "the command name can't come from a variable in the quill workspace: ${W[$i]}" ;;
    esac
    first="$(basename -- "${W[$i]}")"
    case "$first" in
      gh) check_gh "${W[@]:$((i + 1))}" ;;
      git) check_git "${W[@]:$((i + 1))}" ;;
      bash | sh | zsh | dash | ksh | eval | watch | parallel | script | su)
        # A shell running a string: gh or git push inside it would dodge the checks.
        for w in "${W[@]:$((i + 1))}"; do
          case "$(basename -- "$w")" in
            gh) deny "gh inside $first isn't allowed in the quill workspace; run gh directly" ;;
            push) deny "git push isn't allowed in the quill workspace" ;;
          esac
        done
        ;;
    esac
  done <<<"$segs"
  return 0
}

session_branch() {
  local raw="$1" cmd norm home in_ws=0
  if ! cmd="$(jq -r '.tool_input.command // ""' <<<"$raw")"; then
    # Can't read the command: if it might be the post, ask rather than pass.
    case "$raw" in *post.sh* | *--submit*) ask "couldn't parse this command; it may post to GitHub" ;; esac
    exit 0
  fi
  norm="$(norm_command "$cmd")"
  # shellcheck disable=SC2016 # a literal $ in the command text
  case "$norm" in
    *gh* | *git* | *'$'* | *--sub*)
      # shellcheck source=../skills/quill/scripts/lib/common.sh
      source "$GUARD_DIR/../skills/quill/scripts/lib/common.sh" || exit 0
      home="$(quill_home 2>/dev/null)" || home=""
      CWD="$(jq -r '.cwd // ""' <<<"$raw")" || CWD=""
      [ -n "$CWD" ] || CWD="$PWD"
      if [ -n "$home" ] && [ -d "$home" ] && path_within "$CWD" "$home"; then
        in_ws=1
        # Inside the workspace a failure in these checks denies.
        trap guard_exit EXIT
        trap 'deny "internal error"' ERR
        R_WORKTREES="$(resolve_path "$home/worktrees")"
        check_workspace_command "$norm"
        trap - ERR
        trap - EXIT
      fi
      ;;
  esac
  check_post_gate "$norm" "$in_ws"
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
    [ "$tool" = Bash ] || exit 0
    session_branch "$raw"
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
