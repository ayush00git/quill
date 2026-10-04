# SPDX-License-Identifier: Apache-2.0
#
# ghmap.jq: a jq module. GitHub's own diff for a PR, from
# `gh api repos/O/R/pulls/N/files` (the "patch" field), as a map in the same
# shape as lib/diffmap.sh: {"<path>": {"RIGHT": [[s, e]], "LEFT": [[s, e]]}}.
# This is what GitHub validates inline comments against, so post.sh prefers
# it. GitHub leaves "patch" out for very large or binary files; those paths
# are listed under "nopatch" for the local map to cover.

def ghmap:
  reduce .[] as $f ({map: {}, nopatch: []};
    if ($f.patch | type) != "string" then .nopatch += [$f.filename]
    else
      reduce ($f.patch | scan("(?m)^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@")) as $h (.;
        ($h[0] | tonumber) as $ls | (($h[1] // "1") | tonumber) as $lc
        | ($h[2] | tonumber) as $rs | (($h[3] // "1") | tonumber) as $rc
        | (if $lc > 0 then .map[$f.filename].LEFT += [[$ls, $ls + $lc - 1]] else . end)
        | (if $rc > 0 then .map[$f.filename].RIGHT += [[$rs, $rs + $rc - 1]] else . end))
    end);
