#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

setup() {
  LIB="$SCRIPTS/lib"
  CFG="$(jq -c . "$LIB/defaults.json")"
}

matches() { # matches <glob> <path> -> true|false
  jq -nr -L "$LIB" --arg g "$1" --arg p "$2" 'include "size"; $p | test($g | glob_regex)'
}

@test "glob_regex: name patterns match at any depth, path patterns from the root" {
  [ "$(matches package-lock.json package-lock.json)" = true ]
  [ "$(matches package-lock.json web/app/package-lock.json)" = true ]
  [ "$(matches package-lock.json package-lock.json.bak)" = false ]
  [ "$(matches 'vendor/**' vendor/github.com/x/y.go)" = true ]
  [ "$(matches 'vendor/**' src/vendor/y.go)" = false ]
  [ "$(matches '**/generated/**' generated/a.java)" = true ]
  [ "$(matches '**/generated/**' a/b/generated/c/d.java)" = true ]
  [ "$(matches '**/generated/**' a/generatedx/c.java)" = false ]
  [ "$(matches '**/*.pb.go' api/v1/x.pb.go)" = true ]
  [ "$(matches '**/*.pb.go' api/v1/xpb.go)" = false ]
  [ "$(matches '*.min.js' a/b.min.js)" = true ]
  [ "$(matches 'a?.txt' ab.txt)" = true ]
  [ "$(matches 'a?.txt' a/b.txt)" = false ]
  # regex metacharacters in a pattern are literal
  [ "$(matches 'x[1].md' 'x[1].md')" = true ]
  [ "$(matches 'x[1].md' x1.md)" = false ]
  [ "$(matches 'a+b.txt' aab.txt)" = false ]
}

size_of() { # size_of <files json> [size override json]
  jq -nc -L "$LIB" --argjson cfg "$CFG" --argjson f "$1" --argjson s "${2:-null}" 'include "size";
    {size: ($s // {additions: ([$f[].additions] | add // 0), deletions: ([$f[].deletions] | add // 0), files: ($f | length)}),
     files: $f, filesTruncated: false}
    | effective_size($cfg) | [.effectiveSize, .sizeClass]'
}

@test "effective size leaves out lockfiles, vendored and generated code" {
  run size_of '[
    {"path": "src/Main.java", "additions": 40, "deletions": 10},
    {"path": "package-lock.json", "additions": 900, "deletions": 300},
    {"path": "vendor/lib/x.go", "additions": 500, "deletions": 0},
    {"path": "api/gen/generated/Api.java", "additions": 200, "deletions": 50},
    {"path": "docs/guide.md", "additions": 5, "deletions": 1}]'
  [ "$output" = '[{"additions":45,"deletions":11,"files":2,"generatedFiles":3,"generatedLines":1950,"partial":false},"small"]' ]
}

@test "size classes follow smallPrLines and largePrLines" {
  run size_of '[{"path": "a.go", "additions": 150, "deletions": 50}]'
  [[ "$output" == *'"small"]' ]] || false
  run size_of '[{"path": "a.go", "additions": 300, "deletions": 0}]'
  [[ "$output" == *'"medium"]' ]] || false
  run size_of '[{"path": "a.go", "additions": 450, "deletions": 50}]'
  [[ "$output" == *'"large"]' ]] || false
  CFG="$(jq -c '.smallPrLines = 10 | .largePrLines = 20' <<<"$CFG")"
  run size_of '[{"path": "a.go", "additions": 15, "deletions": 0}]'
  [[ "$output" == *'"medium"]' ]] || false
}

@test "configured patterns replace the defaults" {
  CFG="$(jq -c '.generatedPatterns = ["**/*.snap"]' <<<"$CFG")"
  run size_of '[{"path": "package-lock.json", "additions": 10, "deletions": 0}, {"path": "t/__snapshots__/a.snap", "additions": 7, "deletions": 0}]'
  [[ "$output" == '[{"additions":10,"deletions":0,"files":1,"generatedFiles":1,'* ]] || false
}

@test "a truncated file list is marked partial" {
  run jq -nc -L "$LIB" --argjson cfg "$CFG" 'include "size";
    {size: {additions: 10, deletions: 0, files: 150}, files: [], filesTruncated: true} | effective_size($cfg) | .effectiveSize.partial'
  [ "$output" = "true" ]
}

@test "queue.sh adds effectiveSize and sizeClass to every item" {
  setup_tmp
  use_gh_stub
  export QUILL_HOME="$TEST_TMP/ws"
  mkdir -p "$QUILL_HOME/reviews"
  gh_respond 'api --method GET user --jq .login' <<'JSON'
me
JSON
  gh_respond_with 'api graphql *' fake-graphql-prs
  run "$SCRIPTS/queue.sh" --run-dir "$QUILL_HOME/reviews/2026-10-04/.run/t1" --pr apache/foo#1
  [ "$status" -eq 0 ]
  run jq -c '.items[0] | [.effectiveSize.additions, .effectiveSize.files, .sizeClass]' "$QUILL_HOME/reviews/2026-10-04/.run/t1/queue.json"
  [ "$output" = '[1,1,"small"]' ]
  teardown_tmp
}
