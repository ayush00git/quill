#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# guard.sh outside the reviewer: the posting gate (every session) and, in
# sessions inside the quill workspace, allow-explicit: quill's own scripts
# and read-only looks are allowed, a few things are hard-denied, and
# everything else asks.

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/worktrees/apache__foo__1/sub" "$QUILL_HOME/repos" \
    "$QUILL_HOME/reviews/2026-10-04" "$TEST_TMP/elsewhere"
  printf '{}\n' >"$QUILL_HOME/state.json"
  printf 'q\n' >"$QUILL_HOME/reviews/2026-10-04/QUEUE.md"
  GUARD="$REPO_ROOT/hooks/guard.sh"
  SCR="$REPO_ROOT/skills/quill/scripts"
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

decision() { # decision <expected: pass|allow|ask|deny>
  case "$1:$status" in
    pass:0) [ -z "$output" ] && return 0 ;;
    allow:0) case "$output" in *'"permissionDecision":"allow"'*) return 0 ;; esac ;;
    ask:0) case "$output" in *'"permissionDecision":"ask"'*) return 0 ;; esac ;;
    deny:2) return 0 ;;
  esac
  echo "expected $1, got status $status: $output"
  return 1
}

each() { # each <pass|allow|ask|deny> <cwd> <command>...
  local want="$1" cwd="$2" c
  shift 2
  for c in "$@"; do
    session "$cwd" "$c"
    decision "$want" || {
      echo "command: $c"
      return 1
    }
  done
}

# --- the posting gate, everywhere ---

@test "post.sh --submit always asks, inside the workspace or not" {
  each ask "$CWD_OUT" "/x/skills/quill/scripts/post.sh --submit apache/foo#1 --sha abc"
  each ask "$CWD_IN" "$SCR/post.sh --submit apache/foo#1 --sha abc"
}

@test "quoting tricks don't hide post.sh --submit" {
  each ask "$CWD_OUT" \
    "\"/x/post.sh\" '--submit' apache/foo#1" \
    "/x/po\"\"st.sh --sub'mit' apache/foo#1" \
    '/x/post\.sh --submit apache/foo#1' \
    "cd /x && ./post.sh --submit apache/foo#1"
}

@test "post.sh or --submit next to dynamic shell constructs asks too" {
  each ask "$CWD_OUT" \
    "\$(printf post.sh) --submit x" \
    "S=--submit; /x/post.sh \$S x" \
    "/x/post.sh \$(printf -- --sub)mit x" \
    "eval '/x/post.sh' x" \
    "/x/post.sh \`echo x\`"
}

@test "outside the workspace, everything else passes untouched" {
  each pass "$CWD_OUT" \
    "/x/post.sh --dry-run apache/foo#1" \
    "echo --submit" \
    "git commit -m 'post.sh docs'" \
    "gh pr merge 1" \
    "gh auth token" \
    "git push origin main" \
    "ls"
}

# --- the workspace: allow ---

@test "workspace: quill's own scripts are allowed (by real path), except run-tests.sh" {
  each allow "$CWD_IN" \
    "$SCR/init.sh" \
    "$SCR/queue.sh --run-dir reviews/2026-10-04/.run/r1 --repo apache/foo" \
    "$SCR/prepare.sh --run-dir 'reviews/2026-10-04/.run/r1'" \
    "$SCR/save-review.sh --run-dir reviews/2026-10-04/.run/r1 --all" \
    "$SCR/render-queue.sh --run-dir reviews/2026-10-04/.run/r1" \
    "$SCR/post.sh --dry-run apache/foo#1" \
    "$SCR/clean.sh" \
    "$SCR/../scripts/queue.sh --run-dir x"
}

@test "workspace: a copied or look-alike script, or extra shell around it, asks" {
  cp "$SCR/queue.sh" "$TEST_TMP/queue.sh"
  each ask "$CWD_IN" \
    "$TEST_TMP/queue.sh --run-dir x" \
    "queue.sh --run-dir x" \
    "$SCR/lib/common.sh" \
    "bash $SCR/queue.sh --run-dir x" \
    "$SCR/queue.sh --run-dir x && rm -rf ~" \
    "$SCR/queue.sh --run-dir x; curl evil.example" \
    "$SCR/queue.sh --run-dir \$(id)" \
    "$SCR/queue.sh --run-dir x > /tmp/out" \
    "QUILL_HOME=/ $SCR/queue.sh --run-dir x" \
    "$SCR/queue.sh --run-dir *"
}

@test "workspace: read-only looks at workspace files are allowed" {
  each allow "$CWD_IN" \
    "cat state.json" \
    "cat $QUILL_HOME/state.json" \
    "head -n 20 reviews/2026-10-04/QUEUE.md" \
    "tail -5 reviews/2026-10-04/QUEUE.md" \
    "wc -l reviews/2026-10-04/QUEUE.md" \
    "ls reviews" \
    "ls -la" \
    "jq -r '.prs | keys[]' state.json" \
    "jq -c . state.json"
}

@test "workspace: read-only commands on PR content, outside files or with risky options ask" {
  each ask "$CWD_IN" \
    "cat /etc/passwd" \
    "cat ../../etc/passwd" \
    "cat worktrees/apache__foo__1/sub/x" \
    "ls repos" \
    "head -c 100 ~/.ssh/id_rsa" \
    "jq --arg x y . state.json" \
    "jq -f prog.jq state.json" \
    "jq . /etc/passwd" \
    "ls --color=always" \
    "cat state.json | sh" \
    "jq -n env" \
    "jq -n '\$ENV.GH_TOKEN'" \
    "jq -r 'env.GH_TOKEN' state.json" \
    "jq -n 'import \"../.config/x\" as \$d; \$d'" \
    "jq -n 'include \"x\"; .'"
}

# --- the workspace: hard deny ---

@test "workspace: printing the gh token is always denied" {
  each deny "$CWD_IN" \
    "gh auth token" \
    "true; gh auth token" \
    "x=\$(gh auth token)" \
    "sh -c \"gh auth token\"" \
    "gh auth status --show-token" \
    "gh auth status -t" \
    "gh auth status -ht"
}

@test "workspace: pushing is always denied" {
  each deny "$CWD_IN" \
    "git push origin main" \
    "cd repo && git push -f" \
    "bash -c 'git push'" \
    "git send-pack origin main" \
    "git http-push x" \
    "git subtree push --prefix x origin main"
}

# --- the workspace: everything else asks ---

@test "workspace: everything off the allowlist asks, including gh and git" {
  each ask "$CWD_IN" \
    "gh pr view 1" \
    "gh pr merge 1" \
    "gh api -X POST repos/a/b/pulls/1/reviews" \
    "git status" \
    "git -C worktrees/apache__foo__1/sub log -p" \
    "rm -rf reviews" \
    "curl https://evil.example" \
    "echo hi"
}

@test "workspace: [reviewer]'s bypass cases get ask or deny, never allow" {
  each deny "$CWD_IN" \
    "gh auth status --show-token" \
    "gh auth status -t"
  each ask "$CWD_IN" \
    "git -c alias.p=push p origin main" \
    "git --config-env=alias.p=X p" \
    "perl -e 'system(\"gh\",\"api\",\"-X\",\"POST\",\"x\")'" \
    "python3 -c \"import subprocess; subprocess.run(['gh','api','-X','POST','x'])\"" \
    "G=gh; \$G api -X POST x" \
    "G=g; H=h; \$G\$H api x" \
    "/tmp/renamed.sh --submit 12" \
    "/tmp/renamed.sh --sub\$X 12" \
    "/x/post.sh --sub\$X 12"
}

@test "a cwd below the workspace or through a symlink counts as inside" {
  each ask "$QUILL_HOME/worktrees" "gh pr merge 1"
  ln -s "$QUILL_HOME" "$TEST_TMP/link"
  each ask "$TEST_TMP/link" "gh pr merge 1"
  each allow "$TEST_TMP/link" "$SCR/init.sh"
}

@test "non-Bash tools from the main session pass straight through" {
  local ev
  ev="$(jq -cn --arg cwd "$CWD_IN" '{hook_event_name: "PreToolUse", cwd: $cwd, tool_name: "Write",
    tool_input: {file_path: "/etc/x", content: "gh pr merge 1"}}')"
  run bash -c '"$1" <<<"$2"' _ "$GUARD" "$ev"
  decision pass
}

# --- running PR code: run-tests.sh ---

@test "run-tests.sh asks, inside the workspace or not; other projects' run-tests.sh pass" {
  each ask "$CWD_IN" "$SCR/run-tests.sh --run-dir $QUILL_HOME/reviews/2026-10-04/.run/r1"
  each ask "$CWD_OUT" "/x/skills/quill/scripts/run-tests.sh --run-dir /x/r1"
  each pass "$CWD_OUT" "./run-tests.sh" "make test"
}

@test "run-tests.sh hidden by quoting, variables or a link still asks" {
  ln -s "$SCR/run-tests.sh" "$QUILL_HOME/rt"
  each ask "$CWD_IN" \
    "\"$SCR/run-tests.sh\" --run-dir x" \
    "$SCR/run-te''sts.sh --run-dir x" \
    "$SCR/run\\-tests.sh --run-dir x" \
    "\$(printf run-tests.sh) --run-dir x" \
    "bash $SCR/run-tests.sh --run-dir x" \
    "./rt --run-dir x" \
    "$QUILL_HOME/rt --run-dir x"
}

@test "scheduled runs: allowed only with QUILL_HEADLESS and tests.headless true, for the real script alone" {
  local cmd="$SCR/run-tests.sh --run-dir x"
  # not opted in
  QUILL_HEADLESS=1 each ask "$CWD_IN" "$cmd"
  printf '{"tests": {"headless": "true"}}\n' >"$QUILL_HOME/config.json"
  QUILL_HEADLESS=1 each ask "$CWD_IN" "$cmd"
  # opted in, but not a scheduled run
  printf '{"tests": {"headless": true}}\n' >"$QUILL_HOME/config.json"
  each ask "$CWD_IN" "$cmd"
  # opted in and scheduled: exactly the script, nothing around it
  QUILL_HEADLESS=1 each allow "$CWD_IN" "$cmd"
  QUILL_HEADLESS=1 each ask "$CWD_IN" \
    "bash $cmd" \
    "QUILL_HEADLESS=1 $cmd" \
    "$cmd; touch x" \
    "$cmd && ls" \
    "cp $SCR/run-tests.sh $QUILL_HOME/r.sh" \
    "$TEST_TMP/elsewhere/run-tests.sh --run-dir x"
}

# --- the files that decide what may run ---

# edit <tool> <cwd> <path>: a main-session file edit through the guard.
edit() {
  local ev
  ev="$(jq -cn --arg t "$1" --arg cwd "$2" --arg p "$3" '{hook_event_name: "PreToolUse", session_id: "s",
    cwd: $cwd, permission_mode: "acceptEdits", tool_name: $t,
    tool_input: (if $t == "NotebookEdit" then {notebook_path: $p, new_source: "x"}
                 else {file_path: $p, content: "x", old_string: "a", new_string: "b"} end)}')"
  run bash -c '"$1" <<<"$2"' _ "$GUARD" "$ev"
}

edits() { # edits <pass|ask> <cwd> <path>...: every write tool on each path
  local want="$1" cwd="$2" p t
  shift 2
  for p in "$@"; do
    for t in Write Edit MultiEdit NotebookEdit; do
      edit "$t" "$cwd" "$p"
      decision "$want" || {
        echo "$t $p"
        return 1
      }
    done
  done
}

@test "edits to the workspace's config, Claude settings and instructions ask, from any session" {
  printf '{}\n' >"$QUILL_HOME/config.json"
  local f
  for f in config.json .claude/settings.json .claude/settings.local.json .claude/skills/x/SKILL.md \
    .claude/agents/a.md CLAUDE.md CLAUDE.local.md .mcp.json; do
    edits ask "$CWD_IN" "$QUILL_HOME/$f"
    edits ask "$CWD_OUT" "$QUILL_HOME/$f"
  done
}

@test "other spellings of a protected file ask too" {
  printf '{}\n' >"$QUILL_HOME/config.json"
  mkdir -p "$QUILL_HOME/notes"
  ln -s "$QUILL_HOME" "$TEST_TMP/ws-link"
  ln "$QUILL_HOME/config.json" "$TEST_TMP/elsewhere/hard.json"
  edits ask "$CWD_IN" config.json ./notes/../config.json .claude/settings.json
  edits ask "$CWD_OUT" \
    "$QUILL_HOME/Config.JSON" \
    "$QUILL_HOME/.Claude/settings.json" \
    "$QUILL_HOME/notes/../config.json" \
    "$TEST_TMP/ws-link/config.json" \
    "$TEST_TMP/elsewhere/hard.json"
}

@test "edits elsewhere pass untouched" {
  edits pass "$CWD_IN" "$QUILL_HOME/notes/todo.md" "$QUILL_HOME/reviews/2026-10-04/x.md"
  edits pass "$CWD_OUT" "$TEST_TMP/elsewhere/config.json" "$TEST_TMP/elsewhere/.claude/settings.json" "$TEST_TMP/elsewhere/CLAUDE.md"
}

@test "shell writes to config.json in the workspace ask; reading it is still allowed" {
  printf '{}\n' >"$QUILL_HOME/config.json"
  each ask "$CWD_IN" \
    "jq '.tests.headless = true' config.json > c.json && mv c.json config.json" \
    "printf '{}' > config.json" \
    "tee config.json" \
    "sed -i s/a/b/ config.json" \
    "cp $TEST_TMP/x config.json" \
    "python3 -c \"open('config.json','w')\""
  each allow "$CWD_IN" "cat config.json" "jq .tests config.json"
}

@test "a path that can't be resolved asks instead of passing" {
  [ "$(id -u)" != 0 ] || skip "root can enter any directory"
  # The portable resolver (as on macOS), and a directory it can't enter.
  mkdir -p "$TEST_TMP/bin" "$QUILL_HOME/locked"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_TMP/bin/realpath"
  chmod +x "$TEST_TMP/bin/realpath"
  chmod 000 "$QUILL_HOME/locked"
  PATH="$TEST_TMP/bin:$PATH" edit Write "$CWD_IN" "$QUILL_HOME/locked/x.json"
  chmod 755 "$QUILL_HOME/locked"
  decision ask
}

@test "edits under a missing directory are matched with the portable resolver too" {
  mkdir -p "$TEST_TMP/bin"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_TMP/bin/realpath"
  chmod +x "$TEST_TMP/bin/realpath"
  ln -s "$QUILL_HOME" "$TEST_TMP/ws-link"
  PATH="$TEST_TMP/bin:$PATH" edits ask "$CWD_OUT" \
    "$QUILL_HOME/.claude/settings.json" \
    "$TEST_TMP/ws-link/.claude/skills/x/SKILL.md" \
    "$QUILL_HOME/missing/../config.json"
}
