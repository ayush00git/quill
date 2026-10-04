# quill

A Claude Code plugin for maintainers. `quill` finds every pull request waiting on your review, checks each one out in an isolated worktree, and hands you a ranked queue plus a private, senior-level review of each PR. It can then push the drafted comments to GitHub as a pending review that only you can see until you submit it.

It runs entirely inside Claude Code on your own machine: no API keys, no servers, no CI tokens.

> Status: under construction. Usage, the security model and scheduling docs land with the features.

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

## License

Apache License 2.0. See [LICENSE](LICENSE).
