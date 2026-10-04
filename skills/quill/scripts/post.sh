#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# post.sh: turn a drafted review into a pending GitHub review.
#
#   post.sh --dry-run <owner/repo#N | PR URL>
#   post.sh --submit <owner/repo#N | PR URL> --sha <payload sha256>
#
# --dry-run builds and checks the exact request without sending it:
#   - the PR is still open and its head is the one quill reviewed
#   - you don't already have a pending review on it (GitHub allows one)
#   - every inline comment sits on a line of GitHub's own diff (pulls/N/files
#     hunks; the local diff covers files GitHub sends no patch for); the
#     others move into the review body instead of failing the whole request
#   - nothing in it looks like a secret or quill's private notes
# It writes <workspace>/post/<slug>.json, prints the comments exactly as they
# would be posted, and the payload's sha256.
#
# --submit sends that payload as a PENDING review (no "event"), visible only to
# you until you submit it in GitHub's UI. It refuses unless:
#   - this isn't a headless run (QUILL_HEADLESS unset) and the session runs
#     in the workspace, where the explicit ask rule makes Claude Code ask you
#   - that ask rule is still in the workspace settings
#   - the payload is the one the dry run showed (same sha256)
#   - the head, the pending-review check and the secret scan still pass
# Only the literal words --submit and --sha are accepted.
#
# Exit codes: 0 ok, 3 head moved, 4 pending review exists, 5 refused
# (secret or private text, or a submit precondition), 6 no drafted review,
# 1 anything else.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/repo.sh
source "$SCRIPT_DIR/lib/repo.sh"
# shellcheck source=lib/diffmap.sh
source "$SCRIPT_DIR/lib/diffmap.sh"

usage() {
  sed -n '4,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

# Text that must never reach GitHub: credentials (GitHub, AWS, Slack, private
# keys) and quill's private notes. Patterns are anchored on fixed prefixes,
# so they stay linear on long input.
SECRET_RE='gh[opsu]_[A-Za-z0-9]|github_pat_|AKIA[0-9A-Z]{12}|-----BEGIN|xox[abprs]-'
PRIVATE_RE='(?i)expected answer|contributor signals'

# gh_json <out file> <gh api args...>: a GET whose failure stops the run with
# gh's own message.
gh_json() {
  local out="$1"
  shift
  if ! gh api --method GET "$@" >"$out" 2>"$out.err"; then
    die "GitHub request failed (gh api $*): $(head -1 "$out.err")"
  fi
}

dry_run() {
  local ref="$1" parsed owner repo number key home state draft tmp me head gd base mb
  parsed="$(parse_pr_ref "$ref")" || exit 1
  read -r owner repo number <<<"$parsed"
  key="$owner/$repo#$number"
  home="$(quill_home)"
  state="$home/state.json"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-post.XXXXXX")" || exit 1
  POST_TMP="$tmp"
  trap 'rm -rf "$POST_TMP"' EXIT

  # The draft quill wrote for this PR.
  [ -f "$state" ] || die "no drafted review for $key: run /quill:quill $key first" 6
  jq -e --arg k "$key" '.prs[$k].reviewedHeadSha and .prs[$k].commentsFile' "$state" >/dev/null 2>&1 ||
    die "no drafted review for $key: run /quill:quill $key first" 6
  jq --arg k "$key" '.prs[$k]' "$state" >"$tmp/draft.json"
  draft="$home/$(jq -r .commentsFile "$tmp/draft.json")"
  path_within "$draft" "$home/reviews" || die "the drafted comments file isn't inside $home/reviews: $draft"
  [ -f "$draft" ] || die "the drafted comments file is missing: $draft" 6
  jq -e 'type == "array"' "$draft" >/dev/null 2>&1 || die "the drafted comments file isn't a JSON array: $draft"

  # The PR now, on GitHub.
  gh_json "$tmp/pr.json" "repos/$owner/$repo/pulls/$number"
  [ "$(jq -r .state "$tmp/pr.json")" = open ] || die "$key is $(jq -r 'if .merged then "merged" else .state end' "$tmp/pr.json"); nothing to post"
  head="$(jq -r .head.sha "$tmp/pr.json")"
  if [ "$head" != "$(jq -r .reviewedHeadSha "$tmp/draft.json")" ]; then
    die "$key moved from $(jq -r '.reviewedHeadSha[0:7]' "$tmp/draft.json") to ${head:0:7} since quill reviewed it; review it again with /quill:quill $key" 3
  fi

  # GitHub allows one pending review per person per PR.
  me="$(gh api --method GET user --jq .login)" || die "gh isn't authenticated (run: gh auth login)"
  gh_json "$tmp/reviews.json" "repos/$owner/$repo/pulls/$number/reviews" --paginate --slurp
  if jq -e --arg me "$me" '[add[]? | select(.state == "PENDING" and .user.login == $me)] | length > 0' \
    "$tmp/reviews.json" >/dev/null; then
    die "you already have a pending review on $key; submit or delete it on GitHub first" 4
  fi

  # Lines GitHub will accept: its own hunks, plus the local diff for files it
  # sends no patch for.
  gh_json "$tmp/files.json" "repos/$owner/$repo/pulls/$number/files" --paginate --slurp
  jq -L "$QUILL_LIB_DIR" 'include "ghmap"; add // [] | ghmap' "$tmp/files.json" >"$tmp/ghmap.json"
  if [ "$(jq '.nopatch | length' "$tmp/ghmap.json")" -gt 0 ]; then
    base="$(jq -r .base.ref "$tmp/pr.json")"
    gd="$(repo_git_dir "$owner/$repo")" || exit 1
    if mb="$(qgit --git-dir="$gd" merge-base "refs/quill/base/$base" "$head" 2>/dev/null)" &&
      diff_map "$gd" "$mb" "$head" >"$tmp/local.json"; then
      jq --slurpfile l "$tmp/local.json" \
        '.nopatch as $np | .map + ($l[0] | with_entries(select(.key as $k | $np | index($k))))' \
        "$tmp/ghmap.json" >"$tmp/map.json"
    else
      warn "no local diff for files GitHub sent no patch for; comments on them go into the review body"
      jq '.map' "$tmp/ghmap.json" >"$tmp/map.json"
    fi
  else
    jq '.map' "$tmp/ghmap.json" >"$tmp/map.json"
  fi

  # The payload: inline comments that fit the diff; the rest in the body. No
  # "event" key, so GitHub keeps the review PENDING (visible only to you).
  jq -L "$QUILL_LIB_DIR" --slurpfile map "$tmp/map.json" --arg head "$head" '
    include "diffmap";
    $map[0] as $m
    | map({path, line, side: (.side // "RIGHT"), body}
          + (if .start_line == null then {} else {start_line, start_side: (.start_side // .side // "RIGHT")} end))
    | (map(select(comment_in_diff($m)))) as $inline
    | (map(select(comment_in_diff($m) | not))) as $outside
    | {commit_id: $head, comments: $inline}
      + (if ($outside | length) == 0 then {} else
          {body: ("Comments on lines outside the diff:\n\n"
                  + ($outside | map("- `\(.path):\(.line)`: \(.body)") | join("\n\n")))} end)' \
    "$draft" >"$tmp/payload.json"

  check_payload_text "$tmp/payload.json"

  mkdir -p "$home/post"
  local out sha
  out="$home/post/$(pr_slug "$owner" "$repo" "$number").json"
  write_atomic "$out" <"$tmp/payload.json"
  sha="$(sha256_file "$out")"

  jq -r --arg key "$key" '
    "Pending review for \($key) at \(.commit_id[0:7]): \(.comments | length) inline comment(s)"
    + (if .body then ", plus comments on lines outside the diff in the review body" else "" end) + ".",
    "",
    (.comments[] | "### \(.path):\(if .start_line then "\(.start_line)-" else "" end)\(.line) (\(.side))", .body, ""),
    (if .body then ("### Review body", .body, "") else empty end)' "$out"
  printf 'Payload: %s\nsha256: %s\n' "$out" "$sha"
  printf 'To create it: post.sh --submit %s --sha %s\n' "$key" "$sha"
}

# The explicit ask rule init.sh puts in the workspace settings (see init.sh).
POST_ASK_RULE='Bash(*post.sh*--submit*)'

# check_payload_text <payload>: the secret and private-notes scan.
check_payload_text() {
  if jq -e --arg re "$SECRET_RE" '[.body // "", .comments[].body] | any(test($re))' "$1" >/dev/null; then
    die "refusing: the review contains something that looks like a credential" 5
  fi
  if jq -e --arg re "$PRIVATE_RE" '[.body // "", .comments[].body] | any(test($re))' "$1" >/dev/null; then
    die "refusing: the review contains quill's private notes (expected answers or contributor signals)" 5
  fi
  jq -e 'has("event") | not' "$1" >/dev/null || die "refusing: the payload would submit the review instead of leaving it pending" 5
}

submit() {
  local ref="$1" want_sha="$2" parsed owner repo number key home rhome cwd out sha head me tmp
  parsed="$(parse_pr_ref "$ref")" || exit 1
  read -r owner repo number <<<"$parsed"
  key="$owner/$repo#$number"
  home="$(quill_home)"

  # Never from a headless or scheduled run.
  [ -z "${QUILL_HEADLESS:-}" ] || die "refusing: headless runs never post (QUILL_HEADLESS is set)" 5
  # Only from a session in the workspace, where the ask rule below applies.
  rhome="$(resolve_path "$home")" || die "can't resolve the workspace"
  for cwd in "$PWD" "${CLAUDE_PROJECT_DIR:-$PWD}"; do
    [ "$(resolve_path "$cwd")" = "$rhome" ] ||
      die "refusing: run this from a Claude Code session started in $home (here: $cwd)" 5
  done
  # The explicit ask rule makes Claude Code ask you before this command, in
  # every permission mode. Without it, don't post.
  jq -e --arg r "$POST_ASK_RULE" '(.permissions.ask // []) | index($r)' "$home/.claude/settings.json" >/dev/null 2>&1 ||
    die "refusing: $home/.claude/settings.json lacks the ask rule $POST_ASK_RULE (run init.sh)" 5

  out="$home/post/$(pr_slug "$owner" "$repo" "$number").json"
  [ -f "$out" ] || die "no payload for $key: run post.sh --dry-run $key first" 6
  sha="$(sha256_file "$out")"
  [ "$sha" = "$want_sha" ] || die "refusing: the payload changed since the dry run (sha256 $sha, expected $want_sha); run --dry-run again" 5
  check_payload_text "$out"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-post.XXXXXX")" || exit 1
  POST_TMP="$tmp"
  trap 'rm -rf "$POST_TMP"' EXIT

  # Re-check what may have changed since the dry run.
  gh_json "$tmp/pr.json" "repos/$owner/$repo/pulls/$number"
  [ "$(jq -r .state "$tmp/pr.json")" = open ] || die "$key isn't open any more; nothing posted"
  head="$(jq -r .head.sha "$tmp/pr.json")"
  [ "$head" = "$(jq -r .commit_id "$out")" ] ||
    die "$key moved to ${head:0:7} since the dry run; review it again with /quill:quill $key" 3
  me="$(gh api --method GET user --jq .login)" || die "gh isn't authenticated (run: gh auth login)"
  gh_json "$tmp/reviews.json" "repos/$owner/$repo/pulls/$number/reviews" --paginate --slurp
  if jq -e --arg me "$me" '[add[]? | select(.state == "PENDING" and .user.login == $me)] | length > 0' \
    "$tmp/reviews.json" >/dev/null; then
    die "you already have a pending review on $key; submit or delete it on GitHub first" 4
  fi

  # The one GitHub write quill ever makes.
  if ! gh api --method POST "repos/$owner/$repo/pulls/$number/reviews" --input "$out" >"$tmp/resp.json" 2>"$tmp/resp.err"; then
    die "GitHub refused the review: $(jq -r '.message // empty' "$tmp/resp.json" 2>/dev/null) $(head -1 "$tmp/resp.err")"
  fi
  [ "$(jq -r .state "$tmp/resp.json")" = PENDING ] ||
    warn "GitHub reports the review as $(jq -r .state "$tmp/resp.json"), not PENDING; check it on GitHub now"

  lock_acquire "$home/.state.lock" 30
  if jq --arg k "$key" --slurpfile r "$tmp/resp.json" --arg at "$(now_iso)" --slurpfile p "$out" \
    '.prs[$k].posted = {reviewId: $r[0].id, at: $at, state: $r[0].state, url: $r[0].html_url,
                        commitId: $p[0].commit_id, comments: ($p[0].comments | length)}' \
    "$home/state.json" >"$tmp/state.json"; then
    mv -f "$tmp/state.json" "$home/state.json"
  fi
  lock_release "$home/.state.lock"
  mv -f "$out" "${out%.json}.posted.json"

  jq -r --arg key "$key" --slurpfile p "${out%.json}.posted.json" \
    '"Created a pending review on \($key) with \($p[0].comments | length) inline comment(s). Only you can see it until you submit it on GitHub: \(.html_url)"' \
    "$tmp/resp.json"
}

main() {
  case "${1:-}" in
    --dry-run)
      if [ -z "${2:-}" ] || [ "$#" -ne 2 ]; then usage; fi
      require_cmd gh jq git
      dry_run "$2"
      ;;
    --submit)
      if [ "$#" -ne 4 ] || [ "$3" != "--sha" ] || [ -z "$4" ]; then usage; fi
      require_cmd gh jq
      submit "$2" "$4"
      ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
}

main "$@"
