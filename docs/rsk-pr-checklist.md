# PR checklist

The [checklist workflow](../.github/workflows/rsk-pr-checklist.yml) leaves the `PR checklist` commit status pending while the PR description contains an unticked checkbox. The workflow itself succeeds. All boxes ticked, no boxes, a draft PR, or a Dependabot PR produces a successful status. Marking a draft ready for review evaluates its checkboxes again; converting it back to draft restores the exemption. API and script errors fail the workflow.

This is a team reminder. It checks checkbox lines in the raw description, including examples in code blocks or comments, without comparing them with the PR template. Removing a checkbox is allowed. Nested list markers on the same line, such as `- - [ ] task` or `1. - [ ] task`, are not detected. Ordinary indented checkbox lines are detected. We accept this syntax limit to keep the parser simple.

Dependabot receives success immediately, without a pending status or PR read. Every other run first publishes pending for the event's commit, before reading the PR. Only a completed evaluation or an exemption publishes success. A later API or script error leaves pending in place. This is not atomic: before the run starts, or if its initial status write fails, an earlier success can remain effective. We accept that limitation for this reminder. Each run creates one status record, or two when successful, against GitHub's limit of 1,000 records per commit and status context.

A workflow with sufficient status-write permissions can publish success under the same `PR checklist` context. Restricting the source to GitHub Actions does not distinguish between workflows from that app. We trust the team and accept this limit without additional controls.

After the workflow lands on `rsk/develop`, configure `PR checklist` as a required status in the branch rules. Until then, it does not prevent merging. The workflow uses trusted `pull_request_target` code and never checks out PR code.

If a merge queue is enabled, it receives a successful checklist status because the required check passed before queue entry. Description edits after queue entry are not enforced against the queue commit. Finish the checklist before joining the queue. Commit statuses are shared by PRs with the same head commit, so use separate branches with distinct head commits for independent checklists.
