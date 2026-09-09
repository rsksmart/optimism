## What

<!-- What this PR does and why. One or two lines. Link the ticket. -->

## Before you open this

- [ ] `/simplify` run, findings fixed
- [ ] `/code-review` run, findings fixed
- [ ] `/security-review` run, findings fixed

## For the reviewer

Copilot and Codex already report the nitpicks. Look for what they cannot see:

- [ ] Does it solve the ticket, and only the ticket?
- [ ] Are the business rules and invariants right?
- [ ] Does it fit our architecture, boundaries and domain language?
- [ ] Rollout: migrations, flags, backwards compatibility, revert path.
- [ ] Peer test it. Do not only read the diff.

Add `blocking` if the PR holds up the team, `postponed` if the review can wait.
