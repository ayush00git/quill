# SPDX-License-Identifier: Apache-2.0
#
# diffmap.jq: a jq module over the map from lib/diffmap.sh.

# line_in_diff($map; $path; $side; $line): $line is inside a hunk of $path on $side.
def line_in_diff($map; $path; $side; $line):
  ($line | type) == "number" and $line >= 1
  and any(($map[$path][$side] // [])[]; .[0] <= $line and $line <= .[1]);

# comment_in_diff($map): the input comment ({path, line, side, start_line?,
# start_side?}) can be posted inline. A multi-line comment must sit inside
# a single hunk on one side.
def comment_in_diff($map):
  . as $c
  | ($c.side // "RIGHT") as $side
  | if $c.start_line == null then
      line_in_diff($map; $c.path; $side; $c.line)
    else
      ($c.start_side // $side) == $side
      and ($c.start_line | type) == "number" and $c.start_line < $c.line
      and any(($map[$c.path][$side] // [])[]; .[0] <= $c.start_line and $c.line <= .[1])
    end;
