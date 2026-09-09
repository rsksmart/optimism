## What

<!-- What this PR does and why. One or two lines. Link the ticket. -->

## Before you open this

- [ ] `/simplify` run, findings fixed
- [ ] `/code-review` run, findings fixed
- [ ] `/security-review` run, findings fixed

## For the reviewer

Copilot and Codex already report the nitpicks. Look for what they cannot see:

- [ ] Solves the ticket, and only the ticket
- [ ] Business rules and invariants are right
- [ ] Fits our architecture, boundaries and domain language
- [ ] Rollout is covered: migrations, flags, backwards compatibility, revert path
- [ ] Peer tested, not only read

Add `blocking` if the PR holds up the team, `postponed` if the review can wait.
