# AGENTS — RSK fork overrides

**This repository is the RSK fork of `ethereum-optimism/optimism`.** The rules
here are RSK-specific and **take precedence over `AGENTS.md` / `CLAUDE.md`
wherever they conflict.** Read this before acting on anything in those files.

## It's a fork

- Upstream: `ethereum-optimism/optimism`. This repo: `rsksmart/optimism`.
- `develop` and `main` are **pristine upstream mirrors** — never commit RSK work
  to them. They only move when we sync upstream (via GitHub "Sync fork").
- All RSK work lives on **`rsk/**` branches** (`rsk/develop`, `rsk/<topic>`) —
  a branch namespace, not a code layout. RSK *code* is mostly inline patches in
  upstream files (see *Where RSK code lives*).

## Default / base branch

- The RSK trunk is **`rsk/develop`** (not `develop`).
- Branch your work off `rsk/develop`, named `rsk/<topic>`
  (e.g. `rsk/<user>/<feature>`, `rsk/ci/<thing>`).

## Opening pull requests  ⚠️ read this

- **Before you push, sanity-check remote and branch** (cheap insurance, esp. for agents):
  - `git remote -v` — `origin` must be `rsksmart/optimism` (not `ethereum-optimism/optimism` or a personal fork).
  - `git branch --show-current` — must be `rsk/<topic>`, never `develop`/`main`.
- **Base repository must be `rsksmart/optimism`.** GitHub defaults a fork PR's
  base to the upstream parent (`ethereum-optimism/optimism`) — you **must change
  the "base repository" dropdown** back to `rsksmart/optimism`.
- **Destination (base) branch must be `rsk/develop`.** Never target `develop`,
  `main`, or the upstream repo.
- Reliable ways to avoid the upstream default:
  - `gh pr create --repo rsksmart/optimism --base rsk/develop --head <your-branch>`
  - or open the compare URL inside the fork:
    `https://github.com/rsksmart/optimism/compare/rsk/develop...<your-branch>`
- The PR **title** must follow Conventional Commits (`type(scope): summary`):
  feature PRs are squash-merged, so the title becomes the commit on
  `rsk/develop` (enforced by the PR-title check).
- Because that title becomes the permanent commit, it must describe what the
  **final diff actually does**, not the branch's original intent. Before
  opening a PR, and again before marking it ready, re-read the diff and confirm
  the title still fits. If the scope changed along the way (commits dropped,
  work rebased out, or the goal narrowed), retitle it to match what actually
  lands. A title that describes work no longer in the diff ships a misleading
  commit onto `rsk/develop` and pollutes the changelog.

## Merge model

- **Feature PRs → squash merge** (one clean commit on `rsk/develop`).
- **Upstream syncs → merge commit** (never squash — squashing an upstream merge
  destroys the merge base and makes the next sync a conflict slog). Done as a
  `rsk/sync-<tag>` → `rsk/develop` PR using the *merge* method, typically by a
  maintainer.

## Where RSK code lives

- In this fork: **inline `IsRSKChain`-gated patches** (the `Apply*RSK` hooks)
  within upstream files. Keep them minimal and gated.
- **Not** in this fork: the `gorsk/` primitives and `rsk/trie` adapter live in
  the **opRSK** repo; op-geth is consumed **unmodified**.
- Prefer adding RSK logic to **opRSK** over patching upstream files here — it
  keeps the fork thin and upstream syncs clean.

## Patch style: stay close to upstream

- When you must patch an upstream file, prefer the change that stays **closest
  to upstream** over a bespoke local rewrite. Reuse upstream's own helpers, keep
  the diff minimal, and don't re-implement what upstream already does. A smaller,
  upstream-shaped patch conflicts far less on the next sync.
- If a simpler approach lines up with upstream, take it, even if a hand-rolled
  version feels marginally cleaner in isolation. Isolate the unavoidable
  RSK-specific bits so the upstream-mirrored logic stays recognizable.
- Example: `op-service/txmgr` `prepare()` had been re-hand-rolled as a manual
  retry loop, which drifted from upstream and dropped a pre-attempt `ctx` check
  (a data race). The fix put it back on upstream's `retry.Do` and confined the
  RSK-only backoff to a tiny adapter, a ~3-line diff from upstream instead of a
  full rewrite (PAYROLLUP-87).

## CI / workflows

- RSK-added GitHub Actions workflows live in `.github/workflows/` alongside
  upstream's, **prefixed `rsk-`** — the filename (`rsk-<thing>.yml`) and the
  `name:` field. This flags them as RSK-owned and avoids filename collisions on
  upstream sync (a workflow upstream would call `foo.yml` we add as `rsk-foo.yml`).
- Scope triggers to the RSK surface — e.g. `branches: [rsk/**]` /
  `tags: ['rsk/**']` — so upstream's `develop`/`main` mirrors aren't affected.
- **Pin every third-party action to a full commit SHA**, with the version as a
  trailing comment (`uses: actions/checkout@<sha> # v4`) — never a mutable tag
  (`@v4`, `@main`). A tag can be repointed at malicious code; a commit SHA can't.
  This is supply-chain hygiene and keeps OpenSSF Scorecard's `Pinned-Dependencies`
  check green. Pinning doesn't mean going stale: the Dependabot `github-actions`
  config bumps the SHAs (and their version comments). Resolve a tag to its SHA with
  `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha`.

## Syncing upstream (maintainers)

- `git fetch upstream --tags && git merge <release-tag>` into `rsk/develop`
  (merge commit), resolve `IsRSKChain`-vs-upstream conflicts, then PR into
  `rsk/develop` with the *merge* method.
- Keep `develop` / `main` as mirrors via GitHub "Sync fork" — do not put RSK
  commits on them.

## Commits & signing

- **All commits MUST be GPG-signed.** Unsigned commits show as "Unverified"
  (the org uses vigilant mode). Never create an unsigned commit, and never pass
  `--no-gpg-sign` or `-c commit.gpgsign=false` — do not skip signing.
- Porcelain `git commit` signs automatically here (`commit.gpgsign=true`).
  **Plumbing and APIs do NOT sign**: `git commit-tree`, and the GitHub Contents /
  Git Data APIs, produce *unsigned* commits. If you must use them, sign
  explicitly (`git commit-tree -S …`) or re-sign before pushing. Prefer
  `git commit`.
- When unsure, verify before/after pushing:
  `git log --show-signature -1`, or
  `gh api repos/<owner>/<repo>/commits/<sha> --jq .commit.verification`
  (look for `verified: true`; `reason: unsigned` means signing was skipped).
