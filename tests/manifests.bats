#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0

load helpers/common

plugin="$REPO_ROOT/.claude-plugin/plugin.json"
market="$REPO_ROOT/.claude-plugin/marketplace.json"

@test "manifests are valid JSON" {
  jq -e . "$plugin" >/dev/null
  jq -e . "$market" >/dev/null
}

@test "marketplace entry name matches the plugin manifest name" {
  [ "$(jq -r .name "$plugin")" = "quill" ]
  [ "$(jq -r '.plugins[0].name' "$market")" = "$(jq -r .name "$plugin")" ]
}

@test "the repo root is the plugin: marketplace source is \".\"" {
  [ "$(jq -r '.plugins | length' "$market")" -eq 1 ]
  [ "$(jq -r '.plugins[0].source' "$market")" = "." ]
}

@test "no pinned version anywhere, so installs track commits" {
  [ "$(jq 'has("version")' "$plugin")" = "false" ]
  [ "$(jq '.plugins[0] | has("version")' "$market")" = "false" ]
}

@test "license is Apache-2.0" {
  [ "$(jq -r .license "$plugin")" = "Apache-2.0" ]
  head -3 "$REPO_ROOT/LICENSE" | grep -q 'Apache License'
}
