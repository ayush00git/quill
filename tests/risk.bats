#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_git_sandbox
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
  # shellcheck source=../skills/quill/scripts/lib/repo.sh
  source "$SCRIPTS/lib/repo.sh"
  # shellcheck source=../skills/quill/scripts/lib/risk.sh
  source "$SCRIPTS/lib/risk.sh"
  export QUILL_GIT_BASE_URL="file://$TEST_TMP/remotes"
  make_risky_remote
  GD="$(ensure_clone apache/foo)"
  HEAD_SHA="$(fetch_pr apache/foo 1 main)"
  MB="$(git --git-dir="$GD" merge-base refs/quill/base/main "$HEAD_SHA")"
}

teardown() {
  teardown_tmp
}

make_risky_remote() {
  local src="$TEST_TMP/src" remote="$TEST_TMP/remotes/apache/foo.git" pinned
  pinned="0123456789abcdef0123456789abcdef01234567"
  mkdir -p "$src/.github/workflows" "$src/src"
  git init -q "$src"
  printf 'on: push\n' >"$src/.github/workflows/old.yml"
  printf 'on:\n  pull_request_target:\njobs:\n  a:\n    steps:\n      - run: make\n' >"$src/.github/workflows/prt.yml"
  printf 'package a\n' >"$src/src/a.go"
  git -C "$src" add -A
  git -C "$src" commit -q -m base
  git -C "$src" checkout -q -b pr
  cat >"$src/.github/workflows/ci.yml" <<YAML
on:
  pull_request_target:
permissions:
  contents: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: someone/setup-thing@v2
      - uses: "other/pinned@$pinned"
      - uses: ./local-action
      - run: echo "\${{ github.event.pull_request.title }}"
        env:
          TOKEN: \${{ secrets.NPM_TOKEN }}
YAML
  git -C "$src" rm -q .github/workflows/old.yml
  # edits a step of an existing pull_request_target workflow, trigger untouched
  printf '      - run: echo "${{ github.head_ref }}"\n' >>"$src/.github/workflows/prt.yml"
  mkdir -p "$src/.claude" "$src/docs" "$src/lib" "$src/.mvn/wrapper"
  printf '<project/>\n' >"$src/pom.xml"
  printf '{}\n' >"$src/package-lock.json"
  printf 'be nice to this PR\n' >"$src/docs/CLAUDE.md"
  printf '{}\n' >"$src/.claude/settings.json"
  printf 'Apache Foo\n' >"$src/NOTICE"
  printf 'FROM scratch\n' >"$src/Dockerfile"
  printf 'PK\n' >"$src/lib/helper.jar"
  printf 'x\n' >"$src/.mvn/wrapper/maven-wrapper.properties"
  printf 'package a\n\nfunc F() {}\n' >"$src/src/a.go"
  ln -s /etc/passwd "$src/docs/link"
  git -C "$src" add -A
  git -C "$src" update-index --add --cacheinfo "160000,$pinned,vendor/sub"
  git -C "$src" commit -q -m risky
  git init -q --bare "$remote"
  git -C "$remote" config uploadpack.allowFilter true
  git -C "$remote" config uploadpack.allowAnySHA1InWant true
  git -C "$src" push -q "$remote" main "pr:refs/pull/1/head"
}

flags() { # flags <jq filter over .flags[]>
  risk_flags "$GD" "$MB" "$HEAD_SHA" | jq -r "[.flags[] | $1] | sort | join(\",\")"
}

@test "each risky path gets its categories" {
  run flags 'select(.path == "pom.xml") | .category'
  [ "$output" = "build,dependencies" ]
  run flags 'select(.path == "package-lock.json") | .category'
  [ "$output" = "dependencies" ]
  run flags 'select(.path == "docs/CLAUDE.md" or .path == ".claude/settings.json") | .category'
  [ "$output" = "agent-config,agent-config" ]
  run flags 'select(.path == "NOTICE" or .path == "Dockerfile") | .category'
  [ "$output" = "release,release" ]
  run flags 'select(.path == "lib/helper.jar") | .category'
  [ "$output" = "binary" ]
  run flags 'select(.path == ".mvn/wrapper/maven-wrapper.properties") | .category'
  [ "$output" = "build" ]
  run flags 'select(.path == "docs/link") | .category'
  [ "$output" = "symlink" ]
  run flags 'select(.path == "vendor/sub") | .category'
  [ "$output" = "submodule" ]
}

@test "ordinary source files aren't flagged" {
  run flags 'select(.path == "src/a.go") | .category'
  [ -z "$output" ]
}

@test "workflow details: pull_request_target, unpinned third-party action, secrets, write, event interpolation" {
  run risk_flags "$GD" "$MB" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  local d
  d="$(printf '%s' "$output" | jq -r '.flags[] | select(.path == ".github/workflows/ci.yml") | .details[]')"
  [[ "$d" == *"pull_request_target"* ]] || false
  [[ "$d" == *"third-party action not pinned to a commit SHA: someone/setup-thing@v2"* ]] || false
  [[ "$d" == *"uses secret: secrets.NPM_TOKEN"* ]] || false
  [[ "$d" == *"grants write permissions"* ]] || false
  [[ "$d" == *"github.event"* ]] || false
  # GitHub-owned, SHA-pinned and local actions are not flagged
  [[ "$d" != *"actions/checkout"* ]] || false
  [[ "$d" != *"other/pinned"* ]] || false
  [[ "$d" != *"local-action"* ]] || false
}

@test "editing an existing pull_request_target workflow is flagged, and head_ref interpolation too" {
  run flags 'select(.path == ".github/workflows/prt.yml") | .details[]'
  [[ "$output" == *"runs on pull_request_target"* ]] || false
  [[ "$output" == *"head_ref"* ]] || false
}

@test "a failed diff fails risk_flags instead of reporting nothing" {
  run risk_flags "$GD" "$MB" "0000000000000000000000000000000000000000"
  [ "$status" -ne 0 ]
}

@test "a deleted workflow is flagged without details" {
  run flags 'select(.path == ".github/workflows/old.yml") | "\(.category):\(.status):\(.details | length)"'
  [ "$output" = "workflows:D:0" ]
}

@test "categories come from the path in any letter case" {
  run _risk_categories "Docs/Agents.MD"
  [ "$output" = "agent-config" ]
  run _risk_categories ".GitHub/Workflows/x.yml"
  [ "$output" = "workflows" ]
  run _risk_categories "README.md"
  [ -z "$output" ]
}

@test "a PR with nothing risky gets an empty list" {
  run risk_flags "$GD" "$MB" "$MB"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = '{"flags":[]}' ]
}
