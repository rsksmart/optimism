## What

<!-- What this PR does and why. One or two lines. Link the ticket. -->

## How this was tested

<!-- What you ran, and what you did not verify. -->

## If this breaks

<!-- How you would detect it and how to recover. "n/a" is a valid answer, say why. -->

## Before you open this

- [ ] I ran `/simplify` and fixed the findings
- [ ] I ran `/code-review` and fixed the findings
- [ ] I ran `/security-review` and fixed the findings
- [ ] I reviewed the full diff and understand the change, including any AI-generated work
- [ ] The title describes the final merged diff, not the branch's original intent

## For the reviewer

Copilot and Codex already report the nitpicks. Look for what they cannot see:

- [ ] Solves the ticket, and only the ticket
- [ ] Business rules and invariants are right
- [ ] Fits our architecture, boundaries and domain language
- [ ] The recovery plan holds up, or n/a is right
- [ ] Peer tested, not only read

Add `blocking` if the PR holds up the team, `postponed` if the review can wait.
