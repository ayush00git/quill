#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# The reference files model the comment style, so they follow it too.

load helpers/common

refs="$REPO_ROOT/skills/quill/references"

@test "reference files contain no em dashes" {
  run grep -rn $'\xe2\x80\x94' "$refs"
  [ "$status" -eq 1 ]
}

@test "review standard covers the nine checks in order" {
  local f="$refs/review-standard.md" prev=0 n line
  for n in 1 2 3 4 5 6 7 8 9; do
    line="$(grep -n "^### $n\. " "$f" | cut -d: -f1)"
    [ -n "$line" ]
    [ "$line" -gt "$prev" ]
    prev="$line"
  done
}
