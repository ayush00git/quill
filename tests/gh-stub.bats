#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  setup_tmp
  use_gh_stub
}

teardown() {
  teardown_tmp
}

@test "gh stub: first matching route wins and its fixture is printed" {
  gh_respond 'api graphql*' <<'JSON'
{"first": true}
JSON
  gh_respond 'api *' <<'JSON'
{"second": true}
JSON
  run gh api graphql -f query='query { viewer { login } }'
  [ "$status" -eq 0 ]
  [ "$output" = '{"first": true}' ]
}

@test "gh stub: route exit code is honored" {
  gh_respond 'pr view *' 1 </dev/null
  run gh pr view 1
  [ "$status" -eq 1 ]
}

@test "gh stub: unmatched call fails with 97 and is logged" {
  run gh auth token
  [ "$status" -eq 97 ]
  [ "$(gh_calls)" -eq 1 ]
  grep -q '^auth token$' "$GH_STUB_LOG"
}
