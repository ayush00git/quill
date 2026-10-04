#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# guard.sh outside the reviewer: the posting gate (every session) and the gh /
# git allowlist (sessions inside the quill workspace).

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/worktrees/apache__foo__1/sub" "$TEST_TMP/elsewhere"
  GUARD="$REPO_ROOT/hooks/guard.sh"
  CWD_IN="$QUILL_HOME"
  CWD_OUT="$TEST_TMP/elsewhere"
}

teardown() {
  teardown_tmp
}

# session <cwd> <command>: a main-session Bash call through the guard.
session() {
  local ev
  ev="$(jq -cn --arg c "$2" --arg cwd "$1" '{hook_event_name: "PreToolUse", session_id: "s",
    cwd: $cwd, permission_mode: "default", tool_name: "Bash", tool_input: {command: $c}}')"
  run bash -c '"$1" <<<"$2"' _ "$GUARD" "$ev"
}

expect_pass() { # no decision at all
  if [ "$status" -ne 0 ] || [ -n "$output" ]; then
    echo "expected pass-through, got status $status: $output"
    return 1
  fi
}

expect_ask() {
  if [ "$status" -ne 0 ]; then
    echo "expected ask, got status $status: $output"
    return 1
  fi
  case "$output" in
    *'"permissionDecision":"ask"'*) ;;
    *)
      echo "expected an ask decision, got: $output"
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

each() { # each <expect fn> <cwd> <command>...
  local fn="$1" cwd="$2" c
  shift 2
  for c in "$@"; do
    session "$cwd" "$c"
    "$fn" || {
      echo "command: $c"
      return 1
    }
  done
}

# --- the posting gate, everywhere ---

@test "post.sh --submit always asks, inside the workspace or not" {
  local p="/home/u/.claude/plugins/cache/quill/quill/abc/skills/quill/scripts/post.sh"
  each expect_ask "$CWD_OUT" "$p --submit apache/foo#1 --sha abc"
  each expect_ask "$CWD_IN" "$p --submit apache/foo#1 --sha abc"
}

@test "quoting tricks don't hide post.sh --submit" {
  each expect_ask "$CWD_OUT" \
    "\"/x/post.sh\" '--submit' apache/foo#1" \
    "/x/po\"\"st.sh --sub'mit' apache/foo#1" \
    '/x/post\.sh --submit apache/foo#1' \
    "cd /x && ./post.sh --submit apache/foo#1"
}

@test "post.sh or --submit next to dynamic shell constructs asks too" {
  each expect_ask "$CWD_OUT" \
    "\$(printf post.sh) --submit x" \
    "S=--submit; /x/post.sh \$S x" \
    "/x/post.sh \$(printf -- --sub)mit x" \
    "eval '/x/post.sh' x" \
    "/x/post.sh \`echo x\`"
}

@test "the dry run and unrelated commands don't ask" {
  each expect_pass "$CWD_OUT" \
    "/x/post.sh --dry-run apache/foo#1" \
    "echo --submit" \
    "git commit -m 'post.sh docs'" \
    "ls"
}

# --- the workspace allowlist ---

@test "workspace: read-only gh is allowed" {
  each expect_pass "$CWD_IN" \
    "gh auth status" \
    "gh search prs --review-requested=@me --state=open" \
    "gh pr view 1 -R apache/foo --json title" \
    "gh pr list -R apache/foo" \
    "gh pr diff 1 -R apache/foo" \
    "gh pr checks 1 -R apache/foo" \
    "gh api repos/apache/foo/pulls/1" \
    "gh api -X GET repos/apache/foo" \
    "gh api --method=get repos/apache/foo" \
    "gh api --method GET repos/apache/foo --jq .title" \
    "cd /tmp && gh pr view 1" \
    "FOO=1 gh pr view 1" \
    "timeout 30 gh pr view 1"
}

@test "workspace: gh writes and anything off the allowlist are denied" {
  each expect_deny "$CWD_IN" \
    "gh pr merge 1" \
    "gh pr close 1" \
    "gh pr review 1 --approve" \
    "gh pr comment 1 -b hi" \
    "gh pr edit 1 --add-label x" \
    "gh pr reopen 1" \
    "gh pr lock 1" \
    "gh pr ready 1" \
    "gh issue create -t x" \
    "gh auth token" \
    "gh repo delete apache/foo" \
    "gh gist create f" \
    "gh secret set X" \
    "gh variable set X" \
    "gh label create x" \
    "gh release create v1" \
    "gh workflow run ci" \
    "gh run rerun 1" \
    "gh --help"
}

@test "workspace: gh api only with GET and no request body" {
  each expect_deny "$CWD_IN" \
    "gh api -X POST repos/a/b/pulls/1/reviews" \
    "gh api --method=PATCH repos/a/b" \
    "gh api --method delete repos/a/b" \
    "gh api -XDELETE repos/a/b" \
    "gh api repos/a/b/issues -f title=x" \
    "gh api repos/a/b/issues -F n=1" \
    "gh api repos/a/b -ftitle=x" \
    "gh api repos/a/b --field title=x" \
    "gh api repos/a/b --raw-field title=x" \
    "gh api repos/a/b --input body.json" \
    "gh api repos/a/b --input=body.json" \
    "gh api graphql -f query='mutation { x }'" \
    "gh api graphql --jq 'Mutation'"
}

@test "workspace: gh hidden in pipelines, wrappers or shells is still checked" {
  each expect_deny "$CWD_IN" \
    "echo hi && gh pr merge 1" \
    "gh pr view 1 | gh pr merge 1" \
    "true; gh auth token" \
    "(gh pr close 1)" \
    "x=\$(gh auth token)" \
    "bash -c 'gh pr merge 1'" \
    "sh -c \"gh auth token\"" \
    "eval gh pr merge 1" \
    "xargs gh pr merge" \
    "env GH_TOKEN=x gh pr merge 1" \
    "/usr/local/bin/gh pr merge 1" \
    "nohup gh pr close 1 &"
}

@test "workspace: git push is denied, plain git is fine" {
  each expect_deny "$CWD_IN" \
    "git push origin main" \
    "git -c user.name=x push" \
    "git --git-dir=x.git push" \
    "cd repo && git push -f" \
    "bash -c 'git push'"
  each expect_pass "$CWD_IN" \
    "git status" \
    "git log --oneline -5" \
    "git -C /tmp log"
}

@test "workspace: git -C under worktrees/ must be a worktree root" {
  each expect_pass "$CWD_IN" "git -C worktrees/apache__foo__1 log"
  each expect_pass "$CWD_IN" "git -C $QUILL_HOME/worktrees/apache__foo__1 log -p"
  each expect_deny "$CWD_IN" \
    "git -C worktrees/apache__foo__1/sub log -p" \
    "git -C $QUILL_HOME/worktrees/apache__foo__1/sub log"
}

@test "workspace: reviewer-found bypasses are closed" {
  # gh auth status --show-token prints the token, like gh auth token
  each expect_deny "$CWD_IN" \
    "gh auth status --show-token" \
    "gh auth status -t" \
    "gh auth status -ht"
  # an alias via -c can push; other push commands
  each expect_deny "$CWD_IN" \
    "git -c alias.p=push p origin main" \
    "git --config-env=alias.p=X p" \
    "git send-pack origin main" \
    "git subtree push --prefix x origin main"
  # list literals in other interpreters, and command names from variables
  each expect_deny "$CWD_IN" \
    "perl -e 'system(\"gh\",\"api\",\"-X\",\"POST\",\"x\")'" \
    "python3 -c \"import subprocess; subprocess.run(['gh','api','-X','POST','x'])\"" \
    "G=gh; \$G api -X POST x" \
    "G=g; H=h; \$G\$H api x"
  # a renamed copy of post.sh, and --sub built from a variable
  each expect_ask "$CWD_IN" \
    "/tmp/renamed.sh --submit 12" \
    "/tmp/renamed.sh --sub\$X 12" \
    "/x/post.sh --sub\$X 12"
  each expect_pass "$CWD_IN" \
    "gh auth status" \
    "gh api repos/{owner}/{repo}/pulls --jq .[].number" \
    "gh pr list --json number,title" \
    "echo \$HOME"
}

@test "outside the workspace, gh and git are none of quill's business" {
  each expect_pass "$CWD_OUT" \
    "gh pr merge 1" \
    "gh auth token" \
    "git push origin main"
}

@test "a cwd below the workspace or through a symlink counts as inside" {
  each expect_deny "$QUILL_HOME/worktrees" "gh pr merge 1"
  ln -s "$QUILL_HOME" "$TEST_TMP/link"
  each expect_deny "$TEST_TMP/link" "gh pr merge 1"
}

@test "non-Bash tools from the main session pass straight through" {
  local ev
  ev="$(jq -cn --arg cwd "$CWD_IN" '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: "Write",
    tool_input: {file_path: "/etc/x", content: "gh pr merge 1"}}')"
  run bash -c '"$1" <<<"$2"' _ "$GUARD" "$ev"
  expect_pass
}
