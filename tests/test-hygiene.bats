#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# bats only fails a test on a failing command, and two common assertion forms
# don't count as one mid-test: a negated command (`! cmd`, bash's set -e
# ignores it) and, under the macOS /bin/bash 3.2, a failing `[[ ]]`. End them
# with `|| false`, or use `run` and check $status.

load helpers/common

@test "test files end negations and [[ ]] assertions with || false" {
  run grep -nE '^[[:space:]]+(! |\[\[ )' "$REPO_ROOT"/tests/*.bats
  local bad
  bad="$(printf '%s\n' "$output" | grep -v '|| false$' | grep -v 'test-hygiene.bats' || true)"
  [ -z "$bad" ] || {
    printf 'unenforced assertion:\n%s\n' "$bad"
    false
  }
}
