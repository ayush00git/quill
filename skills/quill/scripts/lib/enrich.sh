# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
#
# Enrichment: fetch everything quill needs about each candidate PR with one
# GraphQL request per batch of PRs, then normalize it (normalize.jq).
# Requires lib/common.sh.
#
# Responses can be large (bodies, files, timelines), so they always travel
# through files and stdin, never through command-line arguments, which
# Linux caps at 128 KB each.

QUILL_ENRICH_BATCH="${QUILL_ENRICH_BATCH:-10}"

# _enrich_query < items: the GraphQL document for one batch. Owner, name and
# number are validated before they are spliced in.
_enrich_query() {
  jq -r --rawfile frag "$QUILL_LIB_DIR/pr-fields.graphql" '
    def valid: (.repo | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$"))
      and ((.repo | split("/")[1]) as $n | $n != "." and $n != "..")
      and (.number | type == "number" and . >= 1 and . == floor);
    if all(.[]; valid) | not then error("invalid repo or PR number in batch") else . end
    | "query($me: String!) {\n"
      + (to_entries | map(
          (.value.repo | split("/")) as [$o, $n]
          | "p\(.key): repository(owner: \"\($o)\", name: \"\($n)\") { pullRequest(number: \(.value.number)) { ...PR } }")
        | join("\n"))
      + "\n}\n" + $frag'
}

# _enrich_batch <batch file> <viewer> <out file>: the batch's items with
# details merged in. PRs that can't be read (deleted, no access) are dropped
# with a warning.
_enrich_batch() {
  local batch="$1" viewer="$2" out="$3" query resp="$3.resp"
  query="$(_enrich_query <"$batch")" || die "refusing to query an invalid PR reference"
  # gh exits non-zero when any alias fails but still prints the partial data.
  gh api graphql --method POST -f query="$query" -f me="$viewer" >"$resp" 2>/dev/null || true
  if ! jq -e '.data | type == "object"' "$resp" >/dev/null 2>&1; then
    die "GitHub GraphQL request failed: $(jq -r '[.errors[]?.message] | join("; ")' "$resp" 2>/dev/null)"
  fi
  jq -r --slurpfile items "$batch" '
    . as $resp | $items[0] | to_entries[]
    | select($resp.data["p\(.key)"].pullRequest == null)
    | "quill: warning: skipping \(.value.repo)#\(.value.number): not readable on GitHub"' "$resp" >&2
  jq -L "$QUILL_LIB_DIR" --slurpfile items "$batch" '
    include "normalize";
    . as $resp
    | [$items[0] | to_entries[]
      | ($resp.data["p\(.key)"].pullRequest) as $pr
      | select($pr != null)
      | .value + ($pr | normalize)]' "$resp" >"$out"
  rm -f "$resp"
}

# enrich_items <items file> <viewer> <out file>: every item, in batches.
enrich_items() {
  local items="$1" viewer="$2" out="$3" tmp total i=0 n=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/quill-enrich.XXXXXX")"
  total="$(jq length "$items")"
  while [ "$i" -lt "$total" ]; do
    jq -c --argjson i "$i" --argjson n "$QUILL_ENRICH_BATCH" '.[$i:$i + $n]' "$items" >"$tmp/batch-$n.json"
    _enrich_batch "$tmp/batch-$n.json" "$viewer" "$tmp/out-$n.json"
    i=$((i + QUILL_ENRICH_BATCH))
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    printf '[]\n' >"$out"
  else
    # Read the parts in batch order (out-0, out-1, ... out-10, not glob order).
    local k=0 parts=()
    while [ "$k" -lt "$n" ]; do
      parts+=("$tmp/out-$k.json")
      k=$((k + 1))
    done
    jq -s 'add' "${parts[@]}" >"$out"
  fi
  rm -rf "$tmp"
}
