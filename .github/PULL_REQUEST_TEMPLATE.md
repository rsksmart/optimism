## What

<!-- What this PR does and why. One or two lines. Link the ticket. -->

## How this was tested

<!-- What you ran, and what you did not verify. -->

## If this breaks

<!-- How you would detect it and how to recover. "n/a" is a valid answer, say why. -->

## Before you open this

- [ ] I ran the team review process and fixed the findings
- [ ] If this is a stack, each PR is safe alone in `rsk/develop` (working or unused), even if the ones above never land

## For the reviewer

Copilot, Codex and the team review process already report the nitpicks. Look for what they cannot see:

- [ ] I ran the team review process and went through its findings
- [ ] The recovery plan holds up, or n/a is right
- [ ] Peer tested, not only read
- [ ] If this is a stack, I read every PR in it

Add `blocking` if the PR holds up the team, `postponed` if the review can wait.

## For the merger

- [ ] The title describes the final merged diff, not the branch's original intent
- [ ] If this is a stack, I merge only the top one (GitHub merges the rest)
