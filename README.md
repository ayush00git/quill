# quill

A Claude Code plugin for maintainers. `quill` finds every pull request waiting on your review, checks each one out in an isolated worktree, and hands you a ranked queue plus a private, senior-level review of each PR. It can then push the drafted comments to GitHub as a pending review that only you can see until you submit it.

It runs entirely inside Claude Code on your own machine: no API keys, no servers, no CI tokens.

## Requirements

- Claude Code.
- `gh`, logged in (`gh auth login`) as the account you review with.
- `git`, `jq` and `bash`, including macOS's bash 3.2. Tested with git 2.55, gh 2.87 to 2.101, and jq 1.7 and 1.8.
- For `--run-tests` only: Docker or Podman.

## Install

```
/plugin marketplace add ayush00git/quill
/plugin install quill@quill
```

From a shell:

```bash
claude plugin marketplace add ayush00git/quill
claude plugin install quill@quill
```

## Workspace

quill keeps everything in one directory, `~/quill` by default (set `QUILL_HOME` to move it). Start Claude Code there:

```bash
mkdir -p ~/quill && cd ~/quill && claude
```

quill creates what it needs there:

| Path | What |
|---|---|
| `config.json` | your settings (below) |
| `state.json` | which head of each PR was reviewed, and what was posted |
| `reviews/<date>/` | `QUEUE.md`, one review per PR, and the comments that can be posted |
| `repos/` | blob-less bare clones, one per repo |
| `worktrees/` | one sparse checkout per PR under review |
| `post/` | the exact payload a dry run showed you |
| `.claude/settings.json` | keeps the PRs' CLAUDE.md files out of your context, and makes posting always ask |

Run it from the workspace: posting refuses anywhere else, because the workspace settings hold the rule that makes Claude Code ask before posting.

## Usage

| Command | What it does |
|---|---|
| `/quill:quill` | the full queue: every PR in your court, reviewing the ones whose head changed since the last run |
| `/quill:quill apache/foo#123` or a PR URL | review that one PR |
| `/quill:quill list` | rebuild QUEUE.md without reviewing anything |
| `/quill:quill --repo apache/foo` | also watch every open PR in that repo (repeatable) |
| `/quill:quill --force` | review again even if the head didn't change |
| `/quill:quill --run-tests` | also run each PR's affected tests in a throwaway container |
| `/quill:quill post apache/foo#123` | create the drafted review as a pending GitHub review |
| `/quill:quill clean` | drop worktrees, refs and state for closed and merged PRs (`clean --dry-run` lists them) |

A PR is in your court when your review is requested or it's in a repo you watch, and you haven't reviewed it yet. It's also in your court when you have reviewed it and since then the author pushed, replied or re-requested your review. If not, it's waiting on the author and goes in a separate list. PRs you approved with nothing new since, PRs from bots and PRs from `skipAuthors` are skipped.

Each review runs in a `quill:pr-reviewer` subagent, up to `parallel` at a time, on your session's model unless you set `reviewerModel`.

## What you get

**`reviews/<date>/QUEUE.md`** ranks the PRs in your court, with author, size (generated files and lockfiles discounted), CI state, how long each has waited, the review's verdict, the reason, effort and a link to the review. It also lists PRs waiting on their authors and likely low-effort PRs.

**`reviews/<date>/<owner>__<repo>__<N>.md`** is the review: verdict, blocking issues, should-fix issues, questions for the author, at most three nits, tests, private contributor signals and, for low-effort PRs or ones that need answers, a suggested reply. On a PR you reviewed before, it checks whether your earlier findings were addressed.

**`reviews/<date>/<owner>__<repo>__<N>.comments.json`** holds the inline comments that can be posted. Each one sits on a line of the PR's diff. Contributor signals and anything marked private never get in.

Nothing is posted by a review.

## Posting

`/quill:quill post apache/foo#123`:

1. quill runs a dry run. It checks the PR is still open at the head that was reviewed and that you have no pending review on it already, moves any comment GitHub's diff can't anchor into the review body, and refuses anything that looks like a credential or private notes.
2. It shows you every comment exactly as it would be posted, then stops and waits.
3. Reply **post**. Claude Code asks you to allow the submit command. quill sends exactly the payload you saw, checked by its sha256, after re-checking the head.
4. You get the link. The review is **pending**: only you can see it, and you can edit, delete or submit it on GitHub.

quill never approves, requests changes, submits, merges, closes, labels, comments publicly or pushes.

## Running tests

By default quill never runs PR code: the review reports the PR's CI state, and "not run" when there is none.

With `--run-tests`, each PR's affected tests run in a throwaway container:

- The PR's files go in as a `git archive` stream on stdin. No host path is mounted, and the container sees no home directory, SSH keys, gh token, credentials or host environment.
- All capabilities dropped, `no-new-privileges`, pid, memory and CPU limits, a timeout, and a cap on output size.
- The network is on by default, because most builds download dependencies. That means a PR's tests can reach your local network and, on a cloud machine, its metadata service. Set `tests.network` to `"none"` to cut it, and do so on cloud hosts. Builds then need their dependencies in the image.
- quill picks the command from the build files: Maven and Gradle modules near the changed files, Go packages, or the whole suite for Python, Node and Cargo. Set `tests.repos` to choose your own.
- The result is `passed`, `failed`, `timed out`, `output too large`, or `not run` with the reason. No usable Docker or Podman means "not run", never "passed".
- The exact command, exit code and log tail go into the review. The full log stays in the run directory.

## Configuration

`config.json` in the workspace. Every key is optional.

| Key | Default | Meaning |
|---|---|---|
| `repos` | `[]` | repos whose open PRs are always in the queue, as `"owner/name"` |
| `parallel` | `4` | reviewers at once |
| `reviewerModel` | `null` | model for the reviewer subagent; `null` uses your session's |
| `skipBots` | `true` | leave out PRs from bots |
| `skipAuthors` | `[]` | leave out PRs from these logins |
| `smallPrLines`, `largePrLines` | `200`, `500` | size classes, after discounting generated files |
| `generatedPatterns` | lockfiles, `vendor/**`, `*.pb.go`, ... | files that don't count toward size (gitignore-style patterns) |
| `jiraProjects` | `{}` | JIRA keys per repo, for spotting competing PRs; by default the repo name in capitals |
| `tests.runtime` | `"docker"` | `"docker"` or `"podman"` |
| `tests.timeoutSec` | `900` | per PR |
| `tests.network` | `"bridge"` | `"none"` to cut it; recommended on cloud hosts |
| `tests.memory`, `tests.cpus` | `"6g"`, `4` | container limits |
| `tests.maxLogBytes` | `52428800` (50 MB) | a run whose output passes this is stopped, so a PR can't fill your disk |
| `tests.cacheVolumes` | `false` | keep a dependency-cache volume per repo; a repo's PRs share it, so one PR's build can poison the next one's cache |
| `tests.repos` | `{}` | `{"owner/repo": {"image": "...", "command": "..."}}`; `{modules}` in the command becomes the affected modules |

## Scheduled runs

quill can build the queue unattended, so the reviews are waiting when you sit down. A headless run reviews and writes QUEUE.md like an interactive one, but **never posts**: `post.sh` refuses when `QUILL_HEADLESS` is set, and the posting rule can't be answered without a person.

```bash
cd ~/quill && env -u ANTHROPIC_API_KEY QUILL_HEADLESS=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 \
  claude -p "/quill:quill" --permission-mode dontAsk --permission-prompts none --output-format json
```

| Part | Why |
|---|---|
| `cd ~/quill` | the workspace settings only apply to sessions started there |
| `env -u ANTHROPIC_API_KEY` | uses your Claude Code login, not an API key that happens to be in the environment |
| `QUILL_HEADLESS=1` | makes posting refuse outright |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` | runs reviewers in the foreground, so the run waits for them before exiting |
| `--permission-mode dontAsk --permission-prompts none` | anything not already allowed is denied instead of waiting for an answer that never comes |
| `--output-format json` | a machine-readable result for your logs |

Run it once by hand first. That confirms Claude Code and `gh` are logged in and usable from a non-interactive shell. A scheduler starts with a minimal environment, so the examples below go through a login shell (`bash -lc`) to get your usual `PATH`. On macOS, where the default shell is zsh, use `/bin/zsh -lc` if your `PATH` is set in `~/.zprofile`. If `claude`, `gh` or `jq` still isn't found, put their full paths in the command. If you moved the workspace, add `QUILL_HOME=<path>` next to `QUILL_HEADLESS=1` and `cd` there instead.

Add `--run-tests` after `/quill:quill` (inside the quotes) to run tests too.

### cron (Linux, macOS)

`crontab -e`, then for 07:00 on weekdays:

```cron
0 7 * * 1-5 /bin/bash -lc 'cd ~/quill && env -u ANTHROPIC_API_KEY QUILL_HEADLESS=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 claude -p "/quill:quill" --permission-mode dontAsk --permission-prompts none --output-format json >>~/quill/logs/headless.log 2>&1'
```

### launchd (macOS)

`~/Library/LaunchAgents/dev.quill.review.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.quill.review</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd ~/quill &amp;&amp; env -u ANTHROPIC_API_KEY QUILL_HEADLESS=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 claude -p "/quill:quill" --permission-mode dontAsk --permission-prompts none --output-format json &gt;&gt;~/quill/logs/headless.log 2&gt;&amp;1</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
  </array>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.quill.review.plist
```

If the Mac is asleep at 07:00, launchd runs the job when it wakes. If it's off, the run is skipped.

### systemd (Linux)

`~/.config/systemd/user/quill.service`:

```ini
[Unit]
Description=quill review queue

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'cd ~/quill && env -u ANTHROPIC_API_KEY QUILL_HEADLESS=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 claude -p "/quill:quill" --permission-mode dontAsk --permission-prompts none --output-format json >>~/quill/logs/headless.log 2>&1'
```

`~/.config/systemd/user/quill.timer`:

```ini
[Unit]
Description=quill review queue, weekday mornings

[Timer]
OnCalendar=Mon..Fri 07:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now quill.timer
loginctl enable-linger "$USER"   # only if it should run while you're logged out
```

With `Persistent=true`, a run missed while the timer was inactive happens as soon as it starts again: at login, or at boot with lingering.

## Security model

A pull request is untrusted input, and quill hands it to an AI agent. The design assumes a PR will try to steer that agent.

- **The reviewer can only read.** A plugin hook limits the `quill:pr-reviewer` subagent to reading its own PR's worktree and context bundle, plus a short list of read-only `git` subcommands on that worktree. Everything else is denied before permission rules run: writes, the network, other PRs, and instruction files. Each reviewer is bound to one PR, so a PR that hijacks its reviewer can't read or forge another PR's review.
- **PR code never runs on your machine.** Git hooks, filters, `export-subst` and symlinks are switched off in the clones. Checkouts leave out the PR's `CLAUDE.md`, `AGENTS.md` and `.claude/`. Tests run only with `--run-tests`, and only in a container.
- **Reports are checked, not trusted.** A hook captures each reviewer's report, routed by a random nonce in its PR's bundle. quill validates it against the output contract before it becomes a review. Comments must sit on the diff; private text is dropped.
- **PR text is escaped** wherever quill renders it: QUEUE.md cells carry no links, images or HTML that a preview would fetch.
- **Posting needs you.** In the workspace, quill's own scripts and read-only commands run without prompts. Anything else asks, and printing the gh token or pushing is denied outright. The submit command always asks, even in auto mode and with permissions bypassed, and headless runs refuse to post.

Residual risks:

- The clones are blob-less, so a reviewer reading older history can make git fetch file contents from GitHub on demand. That's a read of the PR's own repo and nothing else. For a private repo, git answers GitHub with your usual git credentials for github.com.
- The reviewer still reads attacker-written text. The hook decides what it can do, not what it concludes. A PR can mislead a review, so read the review as a draft.
- The hooks and rules are defense in depth around Claude Code's own permission system, not a replacement for it. Keep quill's workspace separate from your other projects.

## License

Apache License 2.0. See [LICENSE](LICENSE).
