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

## Testing RSK changes

Upstream tests only guard untouched behavior; some RSK branches even make an
upstream test path fail. Every RSK divergence must get its own test, and those
tests must not collide with upstream on sync.

- **New test files are suffixed `_rsk_test.go`** (e.g. `estimator_rsk_test.go`).
  **Never add functions to an upstream `_test.go` file** — a fork-only file
  can't conflict on merge; an added function in a shared file frequently does.
- **Test functions are prefixed `TestRSK_`**; test-only helpers, mocks and
  fixtures are **prefixed `rsk`** (e.g. `rskEstimatorBackend`) so they never
  collide with upstream symbols in the shared package.
- **Prefer the external test package** `package <pkg>_test` when testing the
  exported API. Use the internal package **only** when the change is reachable
  solely through unexported symbols (e.g. `EthClient`'s unexported hook fields
  and `runHeaderVerify` / `runBlockVerify`, or the `txmgr` internal `craftTx`
  harness). Internal and external `_test` files coexist in one directory.
- **One `TestMain` per package** — don't add a second one in a `_rsk_test.go`.
- **Assert the default path too**: every nil-defaulted RSK hook must preserve
  standard Ethereum behavior, so cover both "nil ⇒ default" and "set ⇒ hook
  invoked / overrides default".
- **Keep tests hermetic** — no live RSK / forge / network. Reuse upstream test
  seams (`testutils` mocks, `batching/test` stubs, `StaticBinary`); add a small
  `rsk`-prefixed wrapper when a seam can't express what you need (e.g. injecting
  an error into a multi-output contract call).

Run a package's RSK tests with, e.g.:

    go test ./op-service/txmgr/... -run 'TestRSK_' -v

### RSK Go test coverage map

| Area | RSK divergence | RSK test |
| --- | --- | --- |
| `op-service/txmgr/estimator.go` | pre-EIP-1559 `eth_gasPrice` fallback; "neither available" error | `estimator_rsk_test.go` |
| `op-service/txmgr/{cli,txmgr}.go` | `UseLegacyTx` (type-0 tx), pluggable `GasPriceEstimatorFn` | `txmgr_rsk_test.go` |
| `op-service/txmgr/metrics/tx_metrics.go` | nil-guarded fee gauges (nil base/blob fee) | `tx_metrics_rsk_test.go` |
| `op-node/rollup/derive/l1_traversal{,_managed}.go` | reorg-aware receipt-fetch `NotFound` handling | `l1_traversal_rsk_test.go` |
| `op-node/rollup/derive/l1_block_info.go` | nil L1 `BaseFee` ⇒ 0 (no panic) | `l1_block_info_rsk_test.go` |
| `op-service/sources/{eth_client,receipts_rpc,types}.go` | pluggable block / header / receipts / tx-hash hooks | `eth_client_rsk_test.go` |
| `op-deployer/pkg/deployer/broadcaster` | `TxMgrConfigHook` on `KeyedBroadcasterOpts` | `keyed_rsk_test.go` |
| `op-deployer/pkg/deployer/forge` | `ExtraScriptOpts` on `Client` | `client_rsk_test.go` |
| `op-proposer/contracts/disputegamefactory.go` | skip un-loadable games; surface ctx errors | `disputegamefactory_rsk_test.go` |

When you add a new RSK divergence, add a row here and an `_rsk_test.go` beside
the code.

## CI / workflows

- Every `rsk/**` PR is gated by `rsk-test.yml`: **`go-checks`** — `go build
  ./...`, `go vet ./...` and `golangci-lint run ./...` (which also enforces
  formatting) over the whole module — and **`go-tests`**, the scoped suite
  above. To reproduce `go-checks` locally, run `just sync-superchain` first:
  `op-core/superchain/chain.go` embeds a gitignored `superchain-configs.zip`,
  so on a fresh checkout every package load — build, vet and lint alike —
  fails without it. Then run `go build ./...`, `go vet ./...` and
  `just lint-go`, plus `./linter/bin/op-golangci-lint fmt` to apply
  formatting. `just lint-go` also runs `go mod tidy -diff`, which CI does not:
  it is stricter than the gate, not a substitute for it. Both lint commands
  need the custom linter binary `just lint-go` builds: `.golangci.yaml`
  enables the `bigint` plugin, and a stock `golangci-lint` refuses the config
  outright.
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
