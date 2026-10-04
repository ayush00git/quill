# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Risk flags: the parts of a PR that deserve extra attention, written to
# ctx/<slug>/risk.json for the reviewer and the queue ranking:
#   {flags: [{category, path, details: [...]}]}
# Categories:
#   workflows     .github/workflows and .github/actions: pull_request_target,
#                 third-party actions not pinned to a commit SHA, new secrets,
#                 write permissions, ${{ github.event.* }} in run steps
#   build         build scripts, wrappers and plugins
#   dependencies  dependency manifests and lockfiles
#   agent-config  instructions for AI tools (CLAUDE.md, AGENTS.md, .claude/, ...)
#   release       release, packaging, LICENSE/NOTICE and signing config
#   binary        compiled artifacts or archives added to the tree
#   symlink       symlinks added or changed
#   submodule     submodules added or moved
# Requires lib/common.sh and lib/repo.sh.

# _risk_categories <path>: one category per line (a path can be in several).
_risk_categories() {
  local p l base
  p="$1"
  l="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  base="${l##*/}"
  case "$l" in
    .github/workflows/* | .github/actions/* | */action.yml | */action.yaml | action.yml | action.yaml)
      echo workflows ;;
  esac
  case "$base" in
    pom.xml | build.gradle | build.gradle.kts | settings.gradle | settings.gradle.kts | gradlew | gradlew.bat | mvnw | mvnw.cmd | \
      makefile | gnumakefile | *.mk | cmakelists.txt | *.cmake | build.xml | build.sbt | setup.py | setup.cfg | \
      noxfile.py | tox.ini | rakefile | build.sh | build.ps1 | justfile | bazel | build.bazel | workspace | \
      workspace.bazel | module.bazel | .bazelrc | meson.build | configure | configure.ac)
      echo build ;;
    *)
      case "$l" in
        .mvn/* | */.mvn/* | gradle/* | buildsrc/* | */buildsrc/* | project/*.sbt | project/*.scala | dev/* | build/* | build-tools/* | buildtools/*)
          echo build ;;
      esac
      ;;
  esac
  case "$base" in
    pom.xml | package.json | package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-lock.yaml | bun.lock | \
      go.mod | go.sum | cargo.toml | cargo.lock | pyproject.toml | poetry.lock | uv.lock | pipfile | pipfile.lock | \
      requirements*.txt | constraints*.txt | gemfile | gemfile.lock | composer.json | composer.lock | ivy.xml | \
      libs.versions.toml | gradle.lockfile | *.csproj | packages.config | directory.packages.props | build.gradle | \
      build.gradle.kts | build.sbt | dependencies.gradle | versions.props)
      echo dependencies ;;
  esac
  case "$l" in
    claude.md | */claude.md | claude.local.md | */claude.local.md | agents.md | */agents.md | gemini.md | */gemini.md | \
      .claude/* | */.claude/* | .cursor/* | */.cursor/* | .cursorrules | */.cursorrules | .windsurfrules | \
      .github/copilot-instructions.md | .github/instructions/* | .mcp.json | */.mcp.json | .aider* | */.aider*)
      echo agent-config ;;
  esac
  case "$l" in
    release/* | */release/* | *release*.sh | *release*.py | .asf.yaml | license | license.* | */license | \
      */license.* | notice | notice.* | */notice | */notice.* | keys | */keys | dockerfile* | */dockerfile* | docker/* | \
      */assembly/* | assembly/* | .goreleaser* | manifest.in | *.spec | debian/* | */debian/* | .github/release* | \
      */packaging/* | packaging/*)
      echo release ;;
  esac
  case "$base" in
    *.jar | *.war | *.ear | *.class | *.so | *.so.* | *.dylib | *.dll | *.exe | *.bin | *.o | *.a | *.pyc | *.whl | \
      *.zip | *.tar | *.tgz | *.tar.gz | *.gz | *.7z | *.rar | *.node | *.wasm)
      echo binary ;;
  esac
}

# _workflow_details <git dir> <from> <to> <path>: what's risky in the lines
# the PR adds to one workflow or action file.
_workflow_details() {
  local gd="$1" from="$2" to="$3" path="$4" added
  added="$(qgit_net --git-dir="$gd" diff --no-ext-diff --no-color -U0 "$from" "$to" -- "$path" |
    sed -n 's/^+//p' | grep -v '^++ ' || true)"
  [ -n "$added" ] || return 0
  if printf '%s\n' "$added" | grep -q 'pull_request_target'; then
    echo "adds or keeps a pull_request_target trigger"
  fi
  if printf '%s\n' "$added" | grep -q 'workflow_run'; then
    echo "adds a workflow_run trigger"
  fi
  printf '%s\n' "$added" |
    sed -n 's/^[[:space:]-]*uses:[[:space:]]*["'\'']\{0,1\}\([^"'\''[:space:]#]*\).*/\1/p' |
    while IFS= read -r use; do
      case "$use" in
        ./* | docker://*) continue ;;
        actions/* | github/* | apache/*) continue ;;
      esac
      case "${use##*@}" in
        "$use") echo "third-party action without a ref: $use" ;;
        *)
          if ! printf '%s' "${use##*@}" | grep -Eq '^[0123456789abcdef]{40}$'; then
            echo "third-party action not pinned to a commit SHA: $use"
          fi
          ;;
      esac
    done
  printf '%s\n' "$added" | grep -o 'secrets\.[[:alnum:]_]*' | sort -u | sed 's/^/uses secret: /' || true
  if printf '%s\n' "$added" | grep -Eq '^[[:space:]]*[[:lower:]-]+:[[:space:]]*write([[:space:]]|$)|write-all'; then
    echo "grants write permissions"
  fi
  # shellcheck disable=SC2016 # a literal ${{ ... }} expression, not a shell expansion
  if printf '%s\n' "$added" | grep -q '\${{[[:space:]]*github\.event\.'; then
    echo "interpolates \${{ github.event.* }} (check for script injection in run steps)"
  fi
  return 0
}

# risk_flags <git dir> <from sha> <to sha>: prints the risk.json document.
risk_flags() {
  local gd="$1" from="$2" to="$3" meta path old_mode new_mode status cat details
  local out
  out="$(mktemp "${TMPDIR:-/tmp}/quill-risk.XXXXXX")" || return 1
  # --raw -z: ":<old mode> <new mode> <old sha> <new sha> <status>\0<path>\0"
  qgit --git-dir="$gd" diff --raw -z --no-renames --no-ext-diff "$from" "$to" |
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      old_mode="$(printf '%s' "$meta" | cut -d' ' -f1 | tr -d ':')"
      new_mode="$(printf '%s' "$meta" | cut -d' ' -f2)"
      status="$(printf '%s' "$meta" | cut -d' ' -f5)"
      {
        _risk_categories "$path" | while IFS= read -r cat; do
          details="[]"
          if [ "$cat" = workflows ] && [ "$status" != D ]; then
            details="$(_workflow_details "$gd" "$from" "$to" "$path" | jq -R . | jq -s -c .)"
          fi
          jq -cn --arg c "$cat" --arg p "$path" --arg s "$status" --argjson d "$details" \
            '{category: $c, path: $p, status: $s, details: $d}'
        done
        if [ "$new_mode" = 120000 ] || [ "$old_mode" = 120000 ]; then
          jq -cn --arg p "$path" --arg s "$status" '{category: "symlink", path: $p, status: $s, details: []}'
        fi
        if [ "$new_mode" = 160000 ] || [ "$old_mode" = 160000 ]; then
          jq -cn --arg p "$path" --arg s "$status" '{category: "submodule", path: $p, status: $s, details: []}'
        fi
      } >>"$out"
    done
  if ! jq -s '{flags: .}' "$out"; then
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}
