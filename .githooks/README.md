# Git hooks

Version-controlled git hooks for this repo. Install them once per clone with:

```bash
just install-git-hooks
```

That points `core.hooksPath` at this directory, so every hook here runs for all
worktrees of the clone. Re-running the command is a no-op.

To add a hook, drop an executable script named after the git hook (e.g.
`pre-commit`, `commit-msg`) into this directory — no install change is needed.

## Hooks

- `pre-push` — RSK fork: blocks pushing unformatted Go code touched by the
  push, via `just fmt-check` (see AGENTS_rsk.md § CI / workflows). It replaces
  upstream's Rust-only pre-push hook: both share `core.hooksPath` and git runs a
  single `pre-push`, and the fork does not change Rust code.
