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

@test "workspace: quill's own scripts are allowed (by real path)" {
  each allow "$CWD_IN" \
    "$SCR/init.sh" \
    "$SCR/queue.sh --run-dir reviews/2026-10-04/.run/r1 --repo apache/foo" \
    "$SCR/prepare.sh --run-dir 'reviews/2026-10-04/.run/r1'" \
    "$SCR/save-review.sh --run-dir reviews/2026-10-04/.run/r1 --all" \
    "$SCR/render-queue.sh --run-dir reviews/2026-10-04/.run/r1" \
    "$SCR/run-tests.sh --run-dir reviews/2026-10-04/.run/r1" \
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
    "cat state.json | sh"
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
