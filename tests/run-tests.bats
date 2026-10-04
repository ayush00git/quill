#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  REAL_HOME="$HOME"
  use_git_sandbox
  export QUILL_HOME="$TEST_TMP/ws"
  "$SCRIPTS/init.sh" >/dev/null 2>&1
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  # shellcheck source=../skills/quill/scripts/lib/testplan.sh
  source "$SCRIPTS/lib/testplan.sh"
  export DOCKER_STUB_DIR="$TEST_TMP/docker"
  mkdir -p "$DOCKER_STUB_DIR"
  : >"$DOCKER_STUB_DIR/calls"
}

teardown() {
  teardown_tmp
}

# repo_with <file>...: a git repo whose tree has these files; sets GD and HEAD.
repo_with() {
  local r="$TEST_TMP/r" f
  rm -rf "$r"
  git init -q "$r"
  for f in "$@"; do
    mkdir -p "$r/$(dirname "$f")"
    printf 'x\n' >"$r/$f"
  done
  git -C "$r" add -A
  git -C "$r" commit -q -m t
  GD="$r/.git"
  HEAD="$(git -C "$r" rev-parse HEAD)"
}

plan() { # plan <changed files...> -> the plan's command or reason
  printf '%s\n' "$@" >"$TEST_TMP/changed"
  config_json >"$TEST_TMP/cfg.json"
  test_plan "$GD" "$HEAD" "$TEST_TMP/changed" apache/foo "$TEST_TMP/cfg.json" | jq -r '.command // .reason'
}

# --- test plans ---

@test "maven: the modules a PR touches, with what they need; the root means everything" {
  repo_with pom.xml core/pom.xml core/src/A.java api/pom.xml api/src/B.java docs/x.md
  [ "$(plan core/src/A.java api/src/B.java)" = "mvn -B -ntp -am -pl api,core test" ]
  [ "$(plan docs/x.md)" = "mvn -B -ntp test" ]
}

@test "gradle: project paths per module" {
  repo_with settings.gradle build.gradle core/build.gradle.kts core/src/A.kt
  [ "$(plan core/src/A.kt)" = "gradle --no-daemon :core:test" ]
}

@test "go: the packages of the changed .go files" {
  repo_with go.mod main.go pkg/a/x.go pkg/b/y.go
  [ "$(plan pkg/a/x.go main.go README.md)" = "go test . ./pkg/a" ]
  [ "$(plan README.md)" = "go test ." ]
}

@test "python, node and cargo: the whole suite" {
  repo_with pyproject.toml src/m.py
  [[ "$(plan src/m.py)" == *"python -m pytest -q" ]] || false
  repo_with package.json index.js
  [ "$(plan index.js)" = "npm ci && npm test" ]
  repo_with Cargo.toml src/lib.rs
  [ "$(plan src/lib.rs)" = "cargo test" ]
}

@test "unknown build: no plan, with a reason that says how to configure one" {
  repo_with README.md src/a.go
  [[ "$(plan src/a.go)" == *'set tests.repos["apache/foo"] = {image, command}'* ]] || false
}

@test "a configured plan wins and gets the modules filled in" {
  repo_with pom.xml core/pom.xml core/A.java
  printf '{"tests": {"repos": {"apache/foo": {"image": "my/jdk:21", "command": "./mvnw -pl {modules} verify"}}}}\n' >"$QUILL_HOME/config.json"
  [ "$(plan core/A.java)" = "./mvnw -pl core verify" ]
}

# --- running ---

# prepared_run: a run with one prepared PR whose repo has a configured plan.
prepared_run() {
  export QUILL_GIT_BASE_URL="file://$TEST_TMP/remotes"
  local head
  head="$(make_remote apache/foo)"
  GD="$(ensure_clone apache/foo)"
  fetch_pr apache/foo 1 main >/dev/null
  RUN="$QUILL_HOME/reviews/2026-10-04/.run/r1"
  CTX="$RUN/ctx/apache__foo__1"
  mkdir -p "$CTX"
  jq -n --arg h "$head" --arg b "$(git --git-dir="$GD" rev-parse refs/quill/base/main)" \
    '{pr: "apache/foo#1", head_sha: $h, merge_base: $b}' >"$CTX/task.json"
  jq -n '{version: 1, prs: [{pr: "apache/foo#1", slug: "apache__foo__1"}]}' >"$RUN/dispatch.json"
  printf '%s\n' '{"tests": {"timeoutSec": 30, "repos": {"apache/foo": {"image": "busybox", "command": "go test ./..."}}}}' >"$QUILL_HOME/config.json"
  PATH="$REPO_ROOT/tests/helpers/docker-stub:$PATH"
}

tests_json() { jq -r "$1" "$CTX/tests.json"; }

@test "a sandboxed run: tree on stdin, no mounts, no host env, capabilities dropped, limits set" {
  prepared_run
  run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  [[ "$output" == "tests apache/foo#1: passed ("* ]] || false
  [ "$(tests_json .status)" = "passed" ]
  [ "$(tests_json .exitCode)" = "0" ]
  local cmd
  cmd="$(grep '^run ' "$DOCKER_STUB_DIR/calls")"
  [[ "$cmd" == "run --rm -i --name quill-test-apache__foo__1-"* ]] || false
  [[ "$cmd" == *"--network bridge --cap-drop ALL --security-opt no-new-privileges --pids-limit 4096 --memory 6g --cpus 4 -e HOME=/tmp/home busybox sh -c "* ]] || false
  [[ "$cmd" == *"tar -x -C /tmp/src && cd /tmp/src && go test ./..." ]] || false
  # nothing from the host goes in except the tar stream
  [[ "$cmd" != *" -v "* ]] || false
  [[ "$cmd" != *"--volume"* ]] || false
  [[ "$cmd" != *"--mount"* ]] || false
  [[ "$cmd" != *"--env-file"* ]] || false
  [ "$(grep -o -- ' -e ' <<<"$cmd" | wc -l | tr -d ' ')" = "1" ]
  grep -qx 'src/a.go' "$DOCKER_STUB_DIR/tarlist"
  # the exact command and the log are recorded
  [[ "$(tests_json .command)" == *"--cap-drop ALL"* ]] || false
  grep -q 'test output' "$RUN/tests/apache__foo__1.log"
  [ "$(tests_json .logTail)" = "test output" ]
}

@test "failing tests are reported as failed with the exit code" {
  prepared_run
  DOCKER_STUB_EXIT=3 run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  [ "$(tests_json .status)" = "failed" ]
  [ "$(tests_json .exitCode)" = "3" ]
}

@test "a run past the timeout is killed and reported as timed out" {
  prepared_run
  printf '%s\n' '{"tests": {"timeoutSec": 1, "repos": {"apache/foo": {"image": "busybox", "command": "sleep 60"}}}}' >"$QUILL_HOME/config.json"
  DOCKER_STUB_SLEEP=10 run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  [ "$(tests_json .status)" = "timed out" ]
  grep -q '^kill quill-test-apache__foo__1-' "$DOCKER_STUB_DIR/calls"
}

@test "tests.network none and resource limits come from config" {
  prepared_run
  printf '%s\n' '{"tests": {"network": "none", "memory": "2g", "cpus": 1, "repos": {"apache/foo": {"image": "busybox", "command": "true"}}}}' >"$QUILL_HOME/config.json"
  run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [[ "$(grep '^run ' "$DOCKER_STUB_DIR/calls")" == *"--network none "*"--memory 2g --cpus 1 "* ]] || false
}

@test "an unusable runtime or an unknown one means not run, never passed" {
  prepared_run
  DOCKER_STUB_INFO_EXIT=1 run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [ "$status" -eq 0 ]
  [ "$(tests_json .status)" = "not run" ]
  [[ "$(tests_json .reason)" == "docker is installed but not usable"* ]] || false
  printf '%s\n' '{"tests": {"runtime": "lxc"}}' >"$QUILL_HOME/config.json"
  run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [ "$(tests_json .reason)" = "tests.runtime must be docker or podman, not lxc" ]
  [ "$(grep -c '^run ' "$DOCKER_STUB_DIR/calls")" = "0" ]
}

@test "no test plan: not run, with the reason" {
  prepared_run
  printf '{}\n' >"$QUILL_HOME/config.json"
  run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  [ "$(tests_json .status)" = "not run" ]
  [[ "$(tests_json .reason)" == *"couldn't tell how this repo runs its tests"* ]] || false
}

@test "run dirs and slugs are confined" {
  prepared_run
  run "$SCRIPTS/run-tests.sh" --run-dir "$TEST_TMP/elsewhere"
  [ "$status" -ne 0 ]
  run "$SCRIPTS/run-tests.sh" --run-dir "$RUN" --slug ../x
  [ "$status" -ne 0 ]
}

@test "real container (QUILL_TEST_CONTAINER=docker|podman): no host home, keys or token inside" {
  [ -n "${QUILL_TEST_CONTAINER:-}" ] || skip "set QUILL_TEST_CONTAINER=docker or podman to run"
  prepared_run
  PATH="${PATH#"$REPO_ROOT/tests/helpers/docker-stub:"}"
  # shellcheck disable=SC2016 # runs inside the container
  jq -n --arg rt "$QUILL_TEST_CONTAINER" '{tests: {runtime: $rt, timeoutSec: 300, repos: {"apache/foo": {image: "docker.io/library/busybox:latest",
    command: "test -f src/a.go && test ! -e /root/.ssh && test -z \"${GH_TOKEN:-}\" && test \"$HOME\" = /tmp/home && echo sandbox-ok"}}}}' \
    >"$QUILL_HOME/config.json"
  # the runtime keeps its images under the real home (rootless podman would
  # otherwise create a store under the test's HOME that rm can't delete)
  HOME="$REAL_HOME" GH_TOKEN=should-not-leak run "$SCRIPTS/run-tests.sh" --run-dir "$RUN"
  cat "$RUN/tests/apache__foo__1.log"
  [ "$(tests_json .status)" = "passed" ]
  grep -q sandbox-ok "$RUN/tests/apache__foo__1.log"
}
