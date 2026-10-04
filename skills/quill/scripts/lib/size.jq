# SPDX-License-Identifier: Apache-2.0
#
# size.jq: a jq module. The PR size that matters for review effort leaves out
# generated files, lockfiles and vendored code (config "generatedPatterns").

# glob_regex: a gitignore-style glob as an anchored regex. A pattern without a
# "/" matches the file name at any depth; "**/" matches any number of
# directories (including none), "/**" everything below, "*" and "?" stay
# within one path segment.
def glob_regex:
  (if contains("/") then . else "**/" + . end)
  | [scan("\\*\\*/|/\\*\\*$|\\*\\*|\\*|\\?|.")]
  | map(
      if . == "**/" then "(.*/)?"
      elif . == "/**" then "/.*"
      elif . == "**" then ".*"
      elif . == "*" then "[^/]*"
      elif . == "?" then "[^/]"
      elif test("^[A-Za-z0-9_/-]$") then .
      else "\\" + .
      end)
  | "^" + join("") + "$";

# effective_size($cfg): adds effectiveSize and sizeClass to a queue item.
def effective_size($cfg):
  (($cfg.generatedPatterns // []) | map(glob_regex)) as $re
  | [(.files // [])[] | select(.path as $p | any($re[]; . as $r | $p | test($r)))] as $gen
  | ((.size.additions // 0) - ($gen | map(.additions) | add // 0)) as $add
  | ((.size.deletions // 0) - ($gen | map(.deletions) | add // 0)) as $del
  | . + {
      effectiveSize: {
        additions: $add,
        deletions: $del,
        files: ((.size.files // 0) - ($gen | length)),
        generatedFiles: ($gen | length),
        generatedLines: ($gen | map(.additions + .deletions) | add // 0),
        partial: (.filesTruncated // false)
      },
      sizeClass: (($add + $del) as $n
        | if $n <= ($cfg.smallPrLines // 200) then "small"
          elif $n >= ($cfg.largePrLines // 500) then "large"
          else "medium" end)
    };
