#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Scripts run without a prompt, so each confines its --run-dir itself.

load helpers/common

setup() {
  setup_tmp
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/reviews" "$TEST_TMP/out"
  # shellcheck source=../skills/quill/scripts/lib/common.sh
  source "$SCRIPTS/lib/common.sh"
}

teardown() {
  teardown_tmp
}

@test "a run dir under reviews/<date>/.run/<id> is accepted, resolved and created" {
  run require_run_dir "$QUILL_HOME/reviews/2026-10-04/.run/r1"
  [ "$status" -eq 0 ]
  [ "$output" = "$QUILL_HOME/reviews/2026-10-04/.run/r1" ]
  [ -d "$QUILL_HOME/reviews/2026-10-04/.run/r1" ]
  cd "$QUILL_HOME"
  run require_run_dir "reviews/2026-10-04/.run/20261004T101500-ab12"
  [ "$status" -eq 0 ]
  [ "$output" = "$QUILL_HOME/reviews/2026-10-04/.run/20261004T101500-ab12" ]
}

@test "run dirs outside the workspace's reviews are refused, and not created" {
  local bad
  for bad in "/tmp/quill-run" "$TEST_TMP/out/r1" "$QUILL_HOME/x" "$QUILL_HOME/reviews" \
    "$QUILL_HOME/reviews/2026-10-04/.run/../../../../out" "$QUILL_HOME/reviews/./2026-10-04/.run/r1" ""; do
    run require_run_dir "$bad"
    echo "checking: $bad -> $status $output"
    [ "$status" -ne 0 ]
  done
  [ ! -e "$TEST_TMP/out/r1" ]
}

@test "the shape must be reviews/<YYYY-MM-DD>/.run/<id>" {
  local bad
  for bad in "reviews/2026-10-04" "reviews/2026-10-04/r1" "reviews/today/.run/r1" \
    "reviews/2026-10-04/.run/r1/extra" "reviews/2026-10-04/.run/.hidden" \
    "reviews/2026-10-04/.run/a b" "reviews/2026-10-04/.run/a;b"; do
    run require_run_dir "$QUILL_HOME/$bad"
    echo "checking: $bad -> $status $output"
    [ "$status" -ne 0 ]
  done
}

@test "a symlink can't carry the run dir out of the workspace" {
  mkdir -p "$QUILL_HOME/reviews/2026-10-04"
  ln -s "$TEST_TMP/out" "$QUILL_HOME/reviews/2026-10-04/.run"
  run require_run_dir "$QUILL_HOME/reviews/2026-10-04/.run/r1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolves outside"* ]] || false
  # refused before mkdir: nothing was created through the symlink
  [ ! -e "$TEST_TMP/out/r1" ]
}

@test "the printed path has quill_home's form, whatever form was given" {
  local real
  real="$(cd -P "$QUILL_HOME" && pwd -P)"
  run require_run_dir "$real/reviews/2026-10-04/.run/r1"
  [ "$status" -eq 0 ]
  [ "$output" = "$QUILL_HOME/reviews/2026-10-04/.run/r1" ]
}

@test "a symlinked workspace works through either path" {
  mv "$QUILL_HOME" "$TEST_TMP/real"
  ln -s "$TEST_TMP/real" "$QUILL_HOME"
  local real
  real="$(cd -P "$TEST_TMP/real" && pwd -P)"
  run require_run_dir "$QUILL_HOME/reviews/2026-10-04/.run/r1"
  [ "$status" -eq 0 ]
  [ "$output" = "$QUILL_HOME/reviews/2026-10-04/.run/r1" ]
  run require_run_dir "$real/reviews/2026-10-04/.run/r2"
  [ "$status" -eq 0 ]
  [ "$output" = "$QUILL_HOME/reviews/2026-10-04/.run/r2" ]
}

@test "a missing workspace is reported as such" {
  rm -rf "$QUILL_HOME"
  run require_run_dir "$QUILL_HOME/reviews/2026-10-04/.run/r1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"run init.sh first"* ]] || false
  [ ! -e "$QUILL_HOME" ]
}

@test "queue.sh and prepare.sh refuse a run dir outside the workspace" {
  run "$SCRIPTS/queue.sh" --run-dir "$TEST_TMP/out/r1" --pr apache/foo#1
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be inside"* ]] || false
  run "$SCRIPTS/prepare.sh" --run-dir "$TEST_TMP/out/r1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be inside"* ]] || false
  [ ! -e "$TEST_TMP/out/r1" ]
}
