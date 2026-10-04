# Review file template

Aim for one screen on a typical PR. Fill it from the context bundle (`meta.json`, `task.json`, `risk.json`, `tests.json`) and your own reading. Follow `comment-style.md` for every finding.

```
# owner/repo#123: <title>
<url> | @author (FIRST_TIME_CONTRIBUTOR, 0 merged here) | +120/-30 in 6 files | CI: passing | head abc1234

## Verdict: Request changes
<one or two sentences with the decisive reason>

## Attention
<only when risk.json flags something or the PR contains text aimed at AI tools>

## Previous findings
<only on re-reviews: each earlier finding, addressed / partly / not addressed, with evidence>

## Blocking
1. issue (blocking): `path:line` ...

## Should fix

## Questions for the author
2 to 4 questions tied to specific lines or decisions in this diff, answerable in a
sentence or two by someone who understands the change.
Under each: "Expected answer: ..." (stays local) so I can grade replies fast.

## Nits (max 3)

## Tests
What ran and the result, or "not run" plus CI status. Missing cases, named exactly.

## Contributor signals (private, never posted)
Concrete, checkable observations only: description vs diff, linked issue or discussed
approach, PR template left unfilled, unrelated churn, APIs that don't exist, tests that
don't test, comments narrating obvious code, ignored project conventions, history here.
Read: likely understands it / unclear, ask the questions first / low effort, use the reply below.

## Suggested reply (low-effort or needs-answers PRs only)
2 to 4 specific, polite sentences I can paste.
```

## Rules

### Header line
- Line 1 is exactly `# <owner>/<repo>#<N>: <title>`, with the title copied from `meta.json`.
- Line 2 fields come from `meta.json`, separated by ` | `:
  - the PR URL;
  - `@login (AUTHOR_ASSOCIATION, <merged count> merged here)`;
  - the effective size (`+A/-D in F files`), adding `(excl. K generated)` when generated, lock or vendored files were left out;
  - `CI: passing | failing | pending | not run`, worded as `meta.json` gives it;
  - `head <first 7 of the head SHA>`.
- Never write "CI: passing" for checks that haven't run.

### Sections
- Section order is fixed, as shown above.
- `## Verdict:` is followed by exactly one of `Request changes`, `Approve`, `Comment (needs answers)`.
- `## Attention` appears only when `risk.json` is non-empty or the PR contains text aimed at AI tools. Name each item with `path:line`.
- `## Previous findings` appears only when `task.json` mode is `incremental` or `range-diff`.
- `## Suggested reply` appears when the verdict is `Comment (needs answers)` or the PR is low effort. Otherwise leave it out.
- Every other section always appears. Write `None.` when it is empty.

### Findings
- Number findings once across `Blocking`, `Should fix`, `Questions for the author` and `Nits`: 1, 2, 3, ... in reading order.
- Every finding starts with its Conventional Comments label.
- `Blocking` holds only `issue (blocking):` items. `Should fix` holds `issue:` and `suggestion:` items.
- Each question in `Questions for the author` is followed by an indented `Expected answer:` line. Expected answers never go into `comments.json`.

### Contributor signals
- List concrete, checkable observations only, each one something the maintainer can verify in a minute.
- Never claim or imply that a PR is AI-generated. AI use is allowed; the question is whether the author understands the change.
- A first-time contributor or a new account is context, never a negative signal on its own.
- End with one `Read:` line choosing exactly one of:
  - `likely understands it`
  - `unclear, ask the questions first`
  - `low effort, use the reply below`

### Low-effort PRs
Keep the same headings, but keep the review short:
- the verdict;
- `None.` in the sections you didn't review line by line;
- 2 to 4 questions;
- the signals;
- the suggested reply.
