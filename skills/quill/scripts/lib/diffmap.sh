# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Diff map: which lines of a PR can carry an inline review comment. GitHub
# accepts a comment only on a line inside one of the PR diff's hunks (added,
# removed or context lines), on the side the line belongs to:
#   RIGHT  line numbers in the new file (added and context lines)
#   LEFT   line numbers in the old file (removed and context lines)
# A comment outside those ranges makes the whole review request fail with a
# 422, so save-review.sh and post.sh check every comment against this map.
#
#   diff_map <git dir> <from sha> <to sha>
#     prints {"<path>": {"RIGHT": [[start, end], ...], "LEFT": [[start, end], ...]}}
#     keyed by the path in the new tree (the old path for deleted files)
# lib/diffmap.jq has the matching checks (comment_in_diff).
# Requires lib/common.sh and lib/repo.sh.

diff_map() {
  local gd="$1" from="$2" to="$3" raw rc
  raw="$(mktemp "${TMPDIR:-/tmp}/quill-diffmap.XXXXXX")" || return 1
  # -M matches GitHub's rename detection; 3 lines of context like GitHub.
  qgit_net --git-dir="$gd" -c core.quotePath=false diff --no-color --no-ext-diff --no-textconv \
    -M -U3 "$from" "$to" >"$raw"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$raw"
    return 1
  fi
  # A map that can't be built must fail, never come out empty.
  if ! awk '
    function unquote(p) {
      if (substr(p, 1, 1) != "\"") return p
      p = substr(p, 2, length(p) - 2)
      gsub(/\\"/, "\"", p)
      gsub(/\\t/, "\t", p)
      gsub(/\\\\/, "\\", p)
      return p
    }
    /^diff --git / { path = ""; old = ""; in_hunk = 0; next }
    # git ends these header lines with a TAB when the path contains a space.
    !in_hunk && /^--- / { old = substr($0, 5); sub(/\t$/, "", old); sub(/^a\//, "", old); if (substr(old, 1, 1) == "\"") { old = unquote(old); sub(/^a\//, "", old) } next }
    !in_hunk && /^\+\+\+ / {
      p = substr($0, 5)
      sub(/\t$/, "", p)
      if (p == "/dev/null") { path = old } else { if (substr(p, 1, 1) == "\"") p = unquote(p); sub(/^b\//, "", p); path = p }
      next
    }
    /^@@ / {
      in_hunk = 1
      # @@ -l[,s] +l[,s] @@
      split($2, a, ","); split($3, b, ",")
      ls = substr(a[1], 2) + 0; lc = (a[2] == "" ? 1 : a[2] + 0)
      rs = substr(b[1], 2) + 0; rc = (b[2] == "" ? 1 : b[2] + 0)
      if (path != "") {
        if (lc > 0) printf "%s\tLEFT\t%d\t%d\n", path, ls, ls + lc - 1
        if (rc > 0) printf "%s\tRIGHT\t%d\t%d\n", path, rs, rs + rc - 1
      }
      next
    }
  ' "$raw" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t"))
      | reduce .[] as $r ({}; .[$r[0]][$r[1]] += [[($r[2] | tonumber), ($r[3] | tonumber)]])'; then
    rm -f "$raw"
    return 1
  fi
  rm -f "$raw"
}
