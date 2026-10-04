#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# The guard is the only thing standing between untrusted PR content and the
# host, so every rule has a case here. Negative assertions use `run` + status
# (a bare `! cmd` mid-test never fails a bats test).

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  WT="$QUILL_HOME/worktrees/apache__foo__1"
  mkdir -p "$WT/src" "$QUILL_HOME/reviews/2026-10-04/.run/r1/ctx/apache__foo__1/guidance" "$QUILL_HOME/repos"
  printf 'x\n' >"$WT/src/a.go"
  printf '{}\n' >"$QUILL_HOME/config.json"
  mkdir -p "$TEST_TMP/outside"
  printf 'secret\n' >"$TEST_TMP/outside/id_rsa"
  GUARD="$REPO_ROOT/hooks/guard.sh"
}

teardown() {
  teardown_tmp
}

# event <agent_type> <tool> <tool_input JSON>
event() {
  jq -cn --arg a "$1" --arg t "$2" --argjson i "$3" --arg cwd "$QUILL_HOME" \
    '{hook_event_name: "PreToolUse", session_id: "s", cwd: $cwd, permission_mode: "default",
      tool_name: $t, tool_input: $i} + (if $a == "" then {} else {agent_id: "ag1", agent_type: $a} end)'
}

# guard_as <agent_type> <tool> <tool_input JSON>: runs the guard, sets status/output.
guard_as() {
  local ev
  ev="$(event "$1" "$2" "$3")"
  run bash -c '"$1" <<<"$2"' _ "$GUARD" "$ev"
}

reviewer() { guard_as "quill:pr-reviewer" "$@"; }

bash_input() { jq -cn --arg c "$1" '{command: $c}'; }

expect_allow() {
  if [ "$status" -ne 0 ]; then
    echo "expected allow, got status $status: $output"
    return 1
  fi
  case "$output" in
    *'"permissionDecision":"allow"'*) ;;
    *)
      echo "expected an allow decision, got: $output"
      return 1
      ;;
  esac
}

expect_deny() {
  if [ "$status" -ne 2 ]; then
    echo "expected deny (2), got status $status: $output"
    return 1
  fi
}

# --- scope: other sessions and agents are untouched ---

@test "main session: no output, no decision" {
  guard_as "" Bash "$(bash_input 'rm -rf /tmp/x')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "other subagents: no output, no decision" {
  guard_as "Explore" Write '{"file_path": "/etc/passwd", "content": "x"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  guard_as "pr-reviewer" Bash "$(bash_input 'curl evil.example')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unparseable input mentioning the reviewer fails closed; otherwise passes" {
  run bash -c '"$1" <<<"not json quill:pr-reviewer"' _ "$GUARD"
  [ "$status" -eq 2 ]
  run bash -c '"$1" <<<"not json"' _ "$GUARD"
  [ "$status" -eq 0 ]
}

# --- tools ---

@test "reviewer: tools other than Read/Grep/Glob/Bash/SubagentHandback are denied" {
  local t
  for t in Write Edit NotebookEdit WebFetch WebSearch Agent Skill ToolSearch TodoWrite mcp__github__create_issue; do
    reviewer "$t" '{}'
    expect_deny
    [[ "$output" == *"tried $t"* ]] || false
  done
}

@test "reviewer: SubagentHandback passes through without a decision" {
  reviewer SubagentHandback '{"message": "report"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Read / Grep / Glob ---

@test "reviewer Read: worktree and context files are allowed" {
  reviewer Read "$(jq -cn --arg p "$WT/src/a.go" '{file_path: $p}')"
  expect_allow
  reviewer Read "$(jq -cn --arg p "$QUILL_HOME/reviews/2026-10-04/.run/r1/ctx/apache__foo__1/guidance/CLAUDE.md.txt" '{file_path: $p}')"
  expect_allow
  reviewer Read '{"file_path": "worktrees/apache__foo__1/src/a.go"}'
  expect_allow
}

@test "reviewer Read: anything outside worktrees/ and reviews/ is denied" {
  local p
  for p in "$TEST_TMP/outside/id_rsa" "$QUILL_HOME/config.json" "$QUILL_HOME/state.json" \
    "$QUILL_HOME/repos/apache__foo.git/config" "$WT/../../../outside/id_rsa" \
    "$QUILL_HOME/notes/x.md" "/etc/passwd" ""; do
    reviewer Read "$(jq -cn --arg p "$p" '{file_path: $p}')"
    expect_deny
  done
}

@test "reviewer Read: a symlink out of the worktree is denied" {
  ln -s "$TEST_TMP/outside/id_rsa" "$WT/src/link"
  ln -s "$TEST_TMP/outside" "$WT/dirlink"
  reviewer Read "$(jq -cn --arg p "$WT/src/link" '{file_path: $p}')"
  expect_deny
  reviewer Read "$(jq -cn --arg p "$WT/dirlink/id_rsa" '{file_path: $p}')"
  expect_deny
}

@test "reviewer Read: instruction files are denied in any case, even inside the worktree" {
  local p
  for p in CLAUDE.md claude.md docs/Claude.Local.md AGENTS.md sub/agents.MD .claude/settings.json .Claude/skills/x/SKILL.md; do
    reviewer Read "$(jq -cn --arg p "$WT/$p" '{file_path: $p}')"
    expect_deny
  done
}

@test "reviewer Grep: path is required and confined; glob must be relative" {
  reviewer Grep "$(jq -cn --arg p "$WT" '{pattern: "TODO", path: $p, glob: "*.go"}')"
  expect_allow
  reviewer Grep '{"pattern": "TODO"}'
  expect_deny
  reviewer Grep "$(jq -cn --arg p "$TEST_TMP/outside" '{pattern: "secret", path: $p}')"
  expect_deny
  local g
  for g in "/etc/*" "~/.ssh/*" "../*" "../../outside/*" "a/../../b" "**/CLAUDE.md" "{..,src}/*" "src/..{,}/x"; do
    reviewer Grep "$(jq -cn --arg p "$WT" --arg g "$g" '{pattern: "x", path: $p, glob: $g}')"
    expect_deny
  done
}

@test "reviewer Glob: path is required and confined; pattern must be relative" {
  reviewer Glob "$(jq -cn --arg p "$WT" '{pattern: "**/*.go", path: $p}')"
  expect_allow
  reviewer Glob '{"pattern": "**/*.go"}'
  expect_deny
  local g
  for g in "/home/**" "~/**" "../**" "src/../../**" ".claude/**" "{..,src}/**" "x{/..,}/**"; do
    reviewer Glob "$(jq -cn --arg p "$WT" --arg g "$g" '{pattern: $g, path: $p}')"
    expect_deny
  done
}

# --- Bash: allowed forms ---

@test "reviewer Bash: read-only git forms are allowed" {
  local c
  for c in \
    "git -C $WT diff abc123...def456" \
    "git -C $WT diff --stat abc123...def456 -- src/a.go" \
    "git -C worktrees/apache__foo__1 log --oneline -n 20" \
    "git --no-pager -C $WT log -L 10,20:src/a.go" \
    "git -C $WT log -S'maxFrameSize' -- src/a.go" \
    "git -C $WT log -G 'retry\\(' --format='%h %s' --" \
    "git -C $WT show HEAD:src/a.go" \
    "git -C $WT show --stat HEAD~1" \
    "git -C $WT blame -L 80,95 HEAD -- src/a.go" \
    "git -C $WT range-diff a..b c..d" \
    "git -C $WT grep -n -e 'TODO' -- src" \
    "git -C $WT grep -i \"two words\"" \
    "git -C $WT diff --no-ext-diff --no-textconv a b" \
    "git -C $WT grep -e 'a;b|c&(d)' -- src" \
    "git -C $WT grep -E 'foo*[0-9]?' -- src" \
    "git -C $WT log --format='%H {%an} <%ae>'" \
    "git -C $WT grep -e \"plain words\" -- src"; do
    reviewer Bash "$(bash_input "$c")"
    expect_allow || {
      echo "command: $c"
      return 1
    }
  done
}

# --- Bash: denied forms ---

assert_bash_denied() {
  local c
  for c in "$@"; do
    reviewer Bash "$(bash_input "$c")"
    expect_deny || {
      echo "command: $c"
      return 1
    }
  done
}

@test "reviewer Bash: anything but git -C <worktree> <allowed subcommand> is denied" {
  assert_bash_denied \
    "ls $WT" \
    "cat $WT/src/a.go" \
    "curl https://evil.example" \
    "gh pr view 1" \
    "git status" \
    "git diff HEAD" \
    "git -C $WT" \
    "git -C $WT status" \
    "git -C $WT checkout main" \
    "git -C $WT push origin main" \
    "git -C $WT fetch" \
    "git -C $WT config core.pager cat" \
    "git -C $WT apply x.patch" \
    "git -C $WT format-patch -1"
}

@test "reviewer Bash: shell metacharacters, newlines and env prefixes are denied" {
  assert_bash_denied \
    "git -C $WT diff; rm -rf ~" \
    "git -C $WT diff && curl x" \
    "git -C $WT diff | sh" \
    "git -C $WT diff > /tmp/out" \
    "git -C $WT diff < /etc/passwd" \
    "git -C $WT show \$(cat /etc/passwd)" \
    "git -C $WT show \`id\`" \
    "git -C $WT show HEAD & sleep 1" \
    "git -C $WT log {a,b}" \
    "git -C $WT log \\
--oneline" \
    "$(printf 'git -C %s diff\nid' "$WT")" \
    "$(printf 'git -C %s diff\tHEAD' "$WT")" \
    "GIT_EXTERNAL_DIFF=/bin/sh git -C $WT diff" \
    "env git -C $WT diff" \
    "git -C $WT log 'unterminated" \
    "git -C $WT log # comment" \
    "git -C $WT log a\\b" \
    "git -C $WT grep -e \"\$HOME\"" \
    "git -C $WT grep -e \"\\x\"" \
    "git -C $WT grep -e \"\`id\`\""
}

@test "reviewer Bash: global options other than -C are denied" {
  assert_bash_denied \
    "git -c diff.external=/bin/sh -C $WT diff" \
    "git -C $WT -c core.pager=sh log" \
    "git --git-dir=$QUILL_HOME/repos/x.git -C $WT log" \
    "git --exec-path=/tmp -C $WT log" \
    "git --work-tree=/ -C $WT diff" \
    "git --config-env=diff.external=X -C $WT diff" \
    "git -p -C $WT log"
}

@test "reviewer Bash: -C must name one worktree under the workspace" {
  assert_bash_denied \
    "git -C / log" \
    "git -C $TEST_TMP/outside log" \
    "git -C $QUILL_HOME log" \
    "git -C $QUILL_HOME/repos/x.git log" \
    "git -C $QUILL_HOME/worktrees log" \
    "git -C $WT/../.. log" \
    "git -C ../ log"
  ln -s "$TEST_TMP/outside" "$QUILL_HOME/worktrees/escape"
  assert_bash_denied "git -C $QUILL_HOME/worktrees/escape log"
}

@test "reviewer Bash: -C can't name a directory inside a worktree (PR-embedded bare repo)" {
  # A PR can commit a directory shaped like a bare repo. git run there treats
  # it as the repository and obeys its config (textconv runs on log -p).
  mkdir -p "$WT/docs/evil/objects" "$WT/docs/evil/refs"
  assert_bash_denied \
    "git -C $WT/docs/evil log -p" \
    "git -C $WT/src log" \
    "git -C worktrees/apache__foo__1/src diff"
}

@test "reviewer Bash: overlong commands are denied before tokenizing" {
  local pad
  pad="$(head -c 5000 /dev/zero | tr '\0' 'a')"
  assert_bash_denied "git -C $WT log --grep='$pad'"
}

@test "reviewer: an unexpected exit in the guard becomes a deny" {
  run bash -c 'source "$1"; trap guard_exit EXIT; exit 1' _ "$GUARD"
  [ "$status" -eq 2 ]
  run bash -c 'source "$1"; trap guard_exit EXIT; exit 0' _ "$GUARD"
  [ "$status" -eq 0 ]
}

@test "reviewer Bash: absolute, ~ and .. arguments are denied (except after -C)" {
  assert_bash_denied \
    "git -C $WT diff /etc/passwd src/a.go" \
    "git -C $WT diff ../../../../outside/id_rsa src/a.go" \
    "git -C $WT log -- ../x" \
    "git -C $WT log -- src/../../x" \
    "git -C $WT show HEAD -- .." \
    "git -C $WT diff --relative=/etc" \
    "git -C $WT diff --relative=~" \
    "git -C $WT log ~/x" \
    "git -C $WT log --relative=~/x" \
    "git -C $WT log a:~/x" \
    "git -C $WT diff '~/.ssh/id_rsa' a"
}

@test "reviewer Bash: unquoted globs are denied (they could expand to ../ or absolute paths)" {
  assert_bash_denied \
    "git -C $WT diff .?/.?/outside/id_rsa a" \
    "git -C $WT diff /e* a" \
    "git -C $WT diff src/[a]*.go"
}

@test "reviewer Bash: options that write, run programs or read other files are denied" {
  assert_bash_denied \
    "git -C $WT diff --output=pwned.txt" \
    "git -C $WT diff --output pwned.txt" \
    "git -C $WT diff --out=pwned.txt" \
    "git -C $WT log -o x" \
    "git -C $WT diff --ext-diff" \
    "git -C $WT diff --ext" \
    "git -C $WT show --textconv HEAD:a" \
    "git -C $WT diff --no-index a b" \
    "git -C $WT diff --no-ind a b" \
    "git -C $WT blame --contents src/a.go src/a.go" \
    "git -C $WT blame --cont x src/a.go" \
    "git -C $WT blame --ignore-revs-file revs src/a.go" \
    "git -C $WT blame -S revs src/a.go" \
    "git -C $WT blame -wS revs src/a.go" \
    "git -C $WT grep -f patterns" \
    "git -C $WT grep -if patterns" \
    "git -C $WT grep --file=patterns" \
    "git -C $WT grep -O" \
    "git -C $WT grep -Ovim x" \
    "git -C $WT grep --open-files-in-pager=sh x" \
    "git -C $WT diff -Oorder" \
    "git -C $WT log --orderfile=order" \
    "git -C $WT diff --stdin" \
    "git -C $WT log --std" \
    "git -C $WT log --show-signature" \
    "git -C $WT show --show-sig HEAD" \
    "git -C $WT log --help"
}

@test "reviewer Bash: background commands are denied" {
  reviewer Bash "$(jq -cn --arg c "git -C $WT log" '{command: $c, run_in_background: true}')"
  expect_deny
}

@test "reviewer Bash: log -S (pickaxe) stays allowed while blame -S is denied" {
  reviewer Bash "$(bash_input "git -C $WT log -Sfoo")"
  expect_allow
  reviewer Bash "$(bash_input "git -C $WT blame -Sfoo src/a.go")"
  expect_deny
}

@test "reviewer: a symlinked QUILL_HOME works through either path" {
  local real="$TEST_TMP/real-ws"
  mv "$QUILL_HOME" "$real"
  ln -s "$real" "$QUILL_HOME"
  reviewer Read "$(jq -cn --arg p "$real/worktrees/apache__foo__1/src/a.go" '{file_path: $p}')"
  expect_allow
  reviewer Read "$(jq -cn --arg p "$QUILL_HOME/worktrees/apache__foo__1/src/a.go" '{file_path: $p}')"
  expect_allow
  reviewer Bash "$(bash_input "git -C $real/worktrees/apache__foo__1 log")"
  expect_allow
  reviewer Read "$(jq -cn --arg p "$real/config.json" '{file_path: $p}')"
  expect_deny
}

# --- hooks.json ---

@test "hooks.json registers guard.sh for every tool" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "*") | .hooks[]
    | select(.type == "command" and (.command | contains("${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh")))' \
    "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ -x "$REPO_ROOT/hooks/guard.sh" ]
}

# --- the tokenizer agrees with bash ---

@test "tokenizer splits every allowed command exactly as bash does" {
  # shellcheck source=../hooks/guard.sh
  source "$GUARD"
  local c got want
  for c in \
    "git -C wt log -S'max frame' -- src/a.go" \
    "git -C wt grep -e 'a;b|c&(d)' -e \"two words\" -- src" \
    "git -C wt log --format='%H {%an} <%ae>' HEAD~1" \
    "git -C wt grep -E 'foo*[0-9]?' 'x'\"y\"z" \
    "git -C wt log -G 'retry\\(' --  " \
    "git  -C   wt   show   HEAD:src/a.go"; do
    tokenize "$c"
    got="$(printf '<%s>' "${TOKENS[@]}")"
    want="$(bash -c 'git() { printf "<git>"; printf "<%s>" "$@"; }; '"$c")"
    [ "$got" = "$want" ] || {
      printf 'command: %s\n got: %s\nwant: %s\n' "$c" "$got" "$want"
      false
    }
  done
}
