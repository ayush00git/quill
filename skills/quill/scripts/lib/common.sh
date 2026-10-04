# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for quill scripts and hooks. Source it; don't run it.
# Everything here works under bash 3.2 (macOS /bin/bash) and `set -euo pipefail`.

QUILL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- logging ---------------------------------------------------------------

log() { printf 'quill: %s\n' "$*" >&2; }
warn() { printf 'quill: warning: %s\n' "$*" >&2; }

# die <message> [exit code]
die() {
  printf 'quill: error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# require_cmd <name>...: fail with one message naming every missing command.
require_cmd() {
  local missing="" c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  [ -z "$missing" ] || die "missing required command(s):$missing"
}

# --- workspace -------------------------------------------------------------

# quill_home: the workspace root. $QUILL_HOME, else ~/quill. A leading ~ is
# expanded, a trailing slash dropped, and the result must be absolute.
quill_home() {
  local h="${QUILL_HOME:-$HOME/quill}"
  # shellcheck disable=SC2088 # matching a literal ~ on purpose
  case "$h" in
    "~") h="$HOME" ;;
    "~/"*) h="$HOME/${h#\~/}" ;;
  esac
  while [ "${#h}" -gt 1 ] && [ "${h%/}" != "$h" ]; do h="${h%/}"; done
  case "$h" in
    /*) printf '%s\n' "$h" ;;
    *) die "QUILL_HOME must be an absolute path, got: $h" ;;
  esac
}

# --- config ----------------------------------------------------------------

# config_json: defaults.json deep-merged with <workspace>/config.json (objects
# merge key by key, arrays and scalars from config.json replace the default).
config_json() {
  local cfg
  cfg="$(quill_home)/config.json"
  if [ -f "$cfg" ]; then
    jq -e 'type == "object"' "$cfg" >/dev/null 2>&1 ||
      die "config is not a valid JSON object: $cfg"
    jq -s '.[0] * .[1]' "$QUILL_LIB_DIR/defaults.json" "$cfg"
  else
    jq . "$QUILL_LIB_DIR/defaults.json"
  fi
}

# config_get <jq filter>: one value from the merged config, raw for strings.
config_get() {
  config_json | jq -r "$1"
}

# --- PR references ---------------------------------------------------------

# parse_pr_ref <owner/repo#N | https://github.com/owner/repo/pull/N[...]>
# Prints "owner repo N". Fails on anything else, including other hosts.
parse_pr_ref() {
  local ref="$1" re_short re_url
  re_short='^([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)#([1-9][0-9]*)$'
  re_url='^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)([/?#].*)?$'
  if [[ "$ref" =~ $re_short ]] || [[ "$ref" =~ $re_url ]]; then
    case "${BASH_REMATCH[2]}" in
      . | ..) die "not a PR reference: $ref" ;;
    esac
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    die "not a PR reference (want owner/repo#N or a github.com PR URL): $ref"
  fi
}

# pr_slug <owner> <repo> <N>: owner__repo__N, the file-name form used everywhere.
pr_slug() {
  printf '%s__%s__%s\n' "$1" "$2" "$3"
}

# repo_slug <owner> <repo>: owner__repo
repo_slug() {
  printf '%s__%s\n' "$1" "$2"
}

# --- time and hashing --------------------------------------------------------

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
today() { date +%Y-%m-%d; }

# sha256_file <file> / sha256_stdin: hex digest only.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# --- files -------------------------------------------------------------------

# write_atomic <file>: stdin goes to a temp file next to <file>, then mv.
write_atomic() {
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "$dest.tmp.XXXXXX")"
  if cat >"$tmp"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# resolve_path <path>: absolute path with every symlink resolved. The final
# component may not exist yet; its parent must.
resolve_path() {
  local p="$1" dir base target n=0
  if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
    realpath -m -- "$p"
    return
  fi
  # Portable fallback (BSD realpath has no -m).
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    target="$(readlink "$p")"
    case "$target" in
      /*) p="$target" ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
  done
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  dir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || return 1
  case "$base" in
    .) printf '%s\n' "$dir" ;;
    ..) dirname "$dir" ;;
    *) if [ "$dir" = "/" ]; then printf '/%s\n' "$base"; else printf '%s/%s\n' "$dir" "$base"; fi ;;
  esac
}

# path_within <path> <dir>: true when the resolved path is <dir> or below it.
path_within() {
  local p d
  p="$(resolve_path "$1")" || return 1
  d="$(resolve_path "$2")" || return 1
  [ "$p" = "$d" ] && return 0
  case "$p" in "$d"/*) return 0 ;; esac
  return 1
}

# --- locking -------------------------------------------------------------------

# lock_acquire <lockdir> [timeout seconds, default 30]: mkdir-based lock
# (flock isn't on macOS). A lock older than 10 minutes is treated as stale.
lock_acquire() {
  local lock="$1" timeout="${2:-30}" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      warn "removing stale lock: $lock"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    [ "$waited" -lt "$timeout" ] || die "timed out waiting for lock: $lock"
    sleep 1
    waited=$((waited + 1))
  done
}

lock_release() {
  rmdir "$1" 2>/dev/null || true
}
