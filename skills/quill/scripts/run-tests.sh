#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# run-tests.sh: run the affected tests of each prepared PR in a throwaway
# container (only with /quill:quill --run-tests).
#
#   run-tests.sh --run-dir <dir> [--slug <owner__repo__N>]
#
# PR code never runs on the host. The PR's tree goes into the container as a
# tar stream on stdin (git archive), so no host path is mounted: no home
# directory, SSH keys, gh token, credentials or host environment. The
# container runs with every capability dropped, no-new-privileges, pid,
# memory and CPU limits, and a timeout (config "tests"). Network is on by
# default because most builds download dependencies; set tests.network to
# "none" to cut it. tests.cacheVolumes (off by default) keeps a named
# dependency-cache volume per repo, shared by that repo's PRs.
#
# Writes ctx/<slug>/tests.json for the reviewer:
#   {status: passed|failed|timed out|not run, reason?, command?, exitCode?,
#    durationSec?, logTail?}
# and the full log to <run-dir>/tests/<slug>.log. No container runtime means
# "not run" with the reason, never "passed". A run whose output passes
# tests.maxLogBytes (default 50 MB) is stopped, so a PR can't fill the disk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"
# shellcheck source=lib/testplan.sh
source "$SCRIPT_DIR/lib/testplan.sh"

usage() {
  sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

# not_run <ctx dir> <reason>
not_run() {
  jq -n --arg r "$2" '{status: "not run", reason: $r}' | write_atomic "$1/tests.json"
}

# runtime_ready <runtime>: prints why it can't be used, or nothing.
runtime_ready() {
  local rt="$1" err
  case "$rt" in
    docker | podman) ;;
    *) printf 'tests.runtime must be docker or podman, not %s\n' "$rt"; return 0 ;;
  esac
  if ! command -v "$rt" >/dev/null 2>&1; then
    printf 'no container runtime (%s) is installed, so no tests ran\n' "$rt"
    return 0
  fi
  if ! err="$("$rt" info 2>&1 >/dev/null)"; then
    printf '%s is installed but not usable (%s), so no tests ran\n' "$rt" "$(printf '%s' "$err" | head -1)"
  fi
  return 0
}

# run_one <run dir> <slug> <config file> <runtime>
run_one() {
  local run_dir="$1" slug="$2" cfg="$3" rt="$4" ctx task repo head mb gd plan name log start rc status timeout pid wd maxlog
  ctx="$run_dir/ctx/$slug"
  task="$ctx/task.json"
  [ -f "$task" ] || { warn "no task.json for $slug"; return 0; }
  repo="$(jq -r '.pr | split("#")[0]' "$task")"
  head="$(jq -r .head_sha "$task")"
  mb="$(jq -r .merge_base "$task")"
  gd="$(repo_git_dir "$repo")" || { not_run "$ctx" "no cached clone for $repo"; return 0; }

  qgit --git-dir="$gd" diff --name-only --no-renames "$mb" "$head" >"$ctx/.changed" || {
    not_run "$ctx" "couldn't list the changed files"
    return 0
  }
  plan="$(test_plan "$gd" "$head" "$ctx/.changed" "$repo" "$cfg")" || {
    not_run "$ctx" "couldn't work out a test plan"
    return 0
  }
  rm -f "$ctx/.changed"
  if [ "$(jq -r 'has("reason")' <<<"$plan")" = true ]; then
    not_run "$ctx" "$(jq -r .reason <<<"$plan")"
    return 0
  fi

  mkdir -p "$run_dir/tests"
  log="$run_dir/tests/$slug.log"
  name="quill-test-$slug-$$"
  timeout="$(jq -r '.tests.timeoutSec // 900' "$cfg")"
  maxlog="$(jq -r '.tests.maxLogBytes // 52428800' "$cfg")"
  local -a argv cache=()
  if [ "$(jq -r '.tests.cacheVolumes // false' "$cfg")" = true ]; then
    # Opt-in: a named volume per repo as HOME keeps downloaded dependencies
    # between runs. It's a volume, not a host path, but every PR of the repo
    # shares it, so one PR's build can poison the next one's cache.
    cache=(--mount "type=volume,src=quill-cache-$(repo_slug "${repo%%/*}" "${repo#*/}"),dst=/tmp/home")
  fi
  argv=("$rt" run --rm -i --name "$name"
    --network "$(jq -r '.tests.network // "bridge"' "$cfg")"
    --cap-drop ALL --security-opt no-new-privileges --pids-limit 4096
    --memory "$(jq -r '.tests.memory // "6g"' "$cfg")" --cpus "$(jq -r '.tests.cpus // 4' "$cfg")"
    -e HOME=/tmp/home ${cache[@]+"${cache[@]}"}
    "$(jq -r .image <<<"$plan")"
    sh -c "mkdir -p /tmp/src /tmp/home && tar -x -C /tmp/src && cd /tmp/src && $(jq -r .command <<<"$plan")")

  start="$(date +%s)"
  # git archive streams the PR tree; info/attributes keeps export-ignore off.
  qgit_net --git-dir="$gd" archive --format=tar "$head" | "${argv[@]}" >"$log" 2>&1 &
  pid=$!
  # macOS has no timeout(1): a watchdog kills the container instead. It keeps
  # trying until the run ends: at the deadline the container may not exist
  # yet (the image still pulling), and a single kill would then miss it.
  (
    i=0
    stop=""
    while kill -0 "$pid" 2>/dev/null; do
      if [ -z "$stop" ]; then
        if [ "$i" -ge "$timeout" ]; then
          stop=timedout
        elif [ "$(wc -c <"$log" 2>/dev/null | tr -d ' ')" -gt "$maxlog" ]; then
          stop=toolong
        fi
        [ -z "$stop" ] || : >"$log.$stop"
      fi
      [ -z "$stop" ] || "$rt" kill "$name" >/dev/null 2>&1 || true
      sleep 1
      i=$((i + 1))
    done
  ) &
  wd=$!
  rc=0
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true

  if [ -e "$log.timedout" ]; then
    status="timed out"
    rm -f "$log.timedout"
  elif [ -e "$log.toolong" ]; then
    status="output too large"
    rm -f "$log.toolong"
  elif [ "$rc" -eq 0 ]; then
    status=passed
  else
    status=failed
  fi
  jq -n --arg s "$status" --argjson rc "$rc" --argjson d "$(($(date +%s) - start))" \
    --arg cmd "$(printf '%q ' "${argv[@]}")" --arg tail "$(tail -n 60 "$log" | cut -c1-400)" \
    --argjson plan "$plan" \
    '{status: $s, exitCode: $rc, durationSec: $d, command: ($cmd | rtrimstr(" ")),
      buildSystem: $plan.buildSystem, modules: $plan.modules, logTail: $tail}' | write_atomic "$ctx/tests.json"
  printf 'tests %s: %s (%ss)\n' "$(jq -r .pr "$task")" "$status" "$(jq -r .durationSec "$ctx/tests.json")"
}

main() {
  local run_dir="" slug="" cfg rt why slugs
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-dir) run_dir="${2:-}"; shift 2 || usage ;;
      --slug) slug="${2:-}"; shift 2 || usage ;;
      -h | --help) usage ;;
      *) die "unknown argument: $1 (see --help)" 64 ;;
    esac
  done
  [ -n "$run_dir" ] || usage
  require_cmd git jq
  run_dir="$(require_run_dir "$run_dir")" || exit 1
  [ -f "$run_dir/dispatch.json" ] || die "no dispatch.json in $run_dir (run prepare.sh first)"
  if [ -n "$slug" ]; then
    case "$slug" in */* | .* | *..*) die "not a PR slug: $slug" 64 ;; esac
    slugs="$slug"
  else
    slugs="$(jq -r '.prs[] | select(.error | not) | .slug' "$run_dir/dispatch.json")"
  fi

  cfg="$(mktemp "${TMPDIR:-/tmp}/quill-cfg.XXXXXX")" || exit 1
  config_json >"$cfg"
  rt="$(jq -r '.tests.runtime // "docker"' "$cfg")"
  why="$(runtime_ready "$rt")"

  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    if [ -n "$why" ]; then
      not_run "$run_dir/ctx/$slug" "$why"
      printf 'tests %s: not run (%s)\n' "$slug" "$why"
      continue
    fi
    run_one "$run_dir" "$slug" "$cfg" "$rt" || not_run "$run_dir/ctx/$slug" "the test run failed to start"
  done <<<"$slugs"
  rm -f "$cfg"
}

main "$@"
