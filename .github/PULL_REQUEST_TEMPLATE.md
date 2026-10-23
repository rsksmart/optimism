## What

<!-- What this PR does and why. One or two lines. Link the ticket. -->

## How this was tested

<!-- What you ran, and what you did not verify. -->

## If this breaks

<!-- How you would detect it and how to recover. "n/a" is a valid answer, say why. -->

## Before you open this

Each section is ticked by its owner: the author here, then the reviewer and the merger below. An unticked box blocks the merge.

- [ ] I ran `/simplify` and fixed the findings
- [ ] I ran `/code-review` and fixed the findings
- [ ] I ran `/security-review` and fixed the findings
- [ ] I reviewed the full diff and understand the change, including any AI-generated work
- [ ] Not a stack, or each PR is safe alone in `rsk/develop` (working or unused), even if the ones above never land
- [ ] I added `blocking` if the PR holds up the team, or `postponed` if the review can wait

## For the reviewer

- [ ] I read the full diff and understand the change, including any AI-generated work
- [ ] Solves the ticket, and only the ticket
- [ ] Business rules and invariants are right
- [ ] Fits our architecture, boundaries and domain language
- [ ] The recovery plan holds up, or n/a is right
- [ ] Peer tested, not only read
- [ ] Not a stack, or I read every PR in it

## For the merger

- [ ] The title describes the final merged diff, not the branch's original intent
- [ ] Not a stack, or I merge only the top one (GitHub merges the rest)
