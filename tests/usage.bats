#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Every script's --help is its whole header comment, read from the file
# itself, so it can't drift from the header.

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
}

teardown() {
  teardown_tmp
}

@test "--help prints each script's whole header and nothing past it" {
  local f name want n=0
  for f in "$SCRIPTS"/*.sh; do
    grep -q '^usage() { usage_from_header "${BASH_SOURCE\[0\]}"; }$' "$f" || continue
    name="$(basename "$f")"
    # line 4 up to the first line that isn't a comment, without its "# "
    want="$(sed -n '4,/^[^#]/p' "$f" | sed '$d' | sed 's/^# \{0,1\}//')"
    run "$f" --help
    [ "$status" -eq 64 ] || {
      echo "$name exited $status"
      false
    }
    [ "$output" = "$want" ] || {
      echo "$name printed:"
      echo "$output"
      false
    }
    [[ "$output" == "$name: "* ]] || false
    [[ "$output" != *"set -euo pipefail"* ]] || false
    n=$((n + 1))
  done
  [ "$n" -ge 7 ]
}

@test "no script prints a fixed line range as its usage" {
  run grep -l "sed -n '[0-9]*,[0-9]*p' \"\${BASH_SOURCE" "$SCRIPTS"/*.sh
  [ "$status" -eq 1 ]
}
