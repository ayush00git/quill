# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Shared bats helpers. Load with: load helpers/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export REPO_ROOT
export SCRIPTS="$REPO_ROOT/skills/quill/scripts"

# Fresh scratch directory per test, removed by teardown_tmp.
setup_tmp() {
  TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/quill.XXXXXX")"
  export TEST_TMP
}

teardown_tmp() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

# Puts the gh stub first on PATH with an empty route table.
use_gh_stub() {
  export GH_STUB_DIR="$TEST_TMP/gh-stub"
  export GH_STUB_LOG="$TEST_TMP/gh-stub.log"
  mkdir -p "$GH_STUB_DIR"
  : >"$GH_STUB_DIR/routes"
  : >"$GH_STUB_LOG"
  PATH="$REPO_ROOT/tests/helpers/bin:$PATH"
  export PATH
}

# gh_respond <glob> [exit] <<'JSON'
#   ...response body...
# JSON
# Adds a route: calls whose joined arguments match <glob> print stdin's
# content and exit with [exit] (default 0). Earlier routes win.
gh_respond() {
  local pattern="$1" code="${2:-0}" n
  n="$(wc -l <"$GH_STUB_DIR/routes" | tr -d ' ')"
  # a fresh file, so a fixture name reused after resetting routes isn't
  # left executable from an earlier gh_respond_with
  rm -f "$GH_STUB_DIR/fixture-$n"
  cat >"$GH_STUB_DIR/fixture-$n"
  printf '%s\t%s\t%s\n' "$pattern" "fixture-$n" "$code" >>"$GH_STUB_DIR/routes"
}

# gh_respond_with <glob> <helper script name in tests/helpers>: matching
# calls run the script with gh's arguments and print its output.
gh_respond_with() {
  local pattern="$1" script="$2" n
  n="$(wc -l <"$GH_STUB_DIR/routes" | tr -d ' ')"
  rm -f "$GH_STUB_DIR/fixture-$n"
  cp "$REPO_ROOT/tests/helpers/$script" "$GH_STUB_DIR/fixture-$n"
  chmod +x "$GH_STUB_DIR/fixture-$n"
  printf '%s\t%s\t%s\n' "$pattern" "fixture-$n" 0 >>"$GH_STUB_DIR/routes"
}

# Number of gh calls the stub has seen.
gh_calls() {
  grep -c '^--$' "$GH_STUB_LOG" || true
}
