# contracts-rootstock — RSK-side Solidity carry-on

Out-of-tree Solidity carry-on for deploying OP Stack chains to Rootstock
(RSK). Lives outside `packages/contracts-bedrock/` so the upstream
contracts package stays close to its release-tag content and our changes
remain a thin, traceable add-on.

This package exists for one reason: **deploying an OP Chain under RSKj's
RSKIP144 6.8 M per-tx sublist gas cap.** Upstream's monolithic
`OPCMv2.deploy(config)` call requires ~10 M gas in a single transaction
and therefore can never land on RSK regardless of how the L1 block gas
limit is configured.

## What's here

```
contracts-rootstock/
├── README.md                           # this file
├── PLAN.md                             # design rationale, gas budget, EIP-170 tradeoffs
├── DEPLOY.md                           # how to deploy a fresh OP Chain to RSK using only Forge
├── foundry.toml                        # remappings into contracts-bedrock
├── contracts/
│   ├── RSKOPCMSplitterBase.sol         # shared OPCMv2 9.0.2 port: validation + _apply slices
│   ├── RSKOPCMSplitter.sol             # 8-stage splitter (initial deployment)
│   └── RSKOPCMSplitterUpgrade.sol      # one-transaction upgrade of an existing chain
└── script/
    └── RSKDeployOPChain.s.sol          # Forge driver: runSplit(input)
```

The splitter inherits `OPContractsManagerUtilsCaller` so it picks up
*all* of upstream's per-step primitives (`_loadOrDeployProxy`, `_upgrade`,
`_makeGameArgs`, the StorageSetter dance, the L1StandardBridge ChugSplash
quirk, downgrade-protection checks) at near-zero bytecode cost. The only
upstream code we duplicate is the orchestration body of
`_loadChainContracts` and `_apply`, sliced into 7 stages that each fit
under 6.8 M gas.

## Upgrading an existing chain

`RSKOPCMSplitterUpgrade` is the RSK counterpart of `OPCMv2.upgrade`, which
cannot run on these chains (it must be delegatecalled by the ProxyAdmin
owner, and its sequence check reverts on chains the pre-9.0.2 splitter
deployed). Deploy one per chain with the OPCMv2 9.0.2 and the chain's
SystemConfig, have the ProxyAdmin owner(s) transfer ownership to it, then
call `upgrade` with the same input upstream takes. Every ProxyAdmin goes back
to its owner in that transaction; `abort` gives them back without upgrading.
`PLAN.md` lists where it differs from upstream, and
`test/RSKOPCMSplitterUpgradeFork.t.sol` dry-runs it against a live chain.

## Quick start

To deploy a chain to a running RSK L1, see **[`DEPLOY.md`](./DEPLOY.md)**
for the Forge-only runbook.

If you have the parent rollup repository, you can use
`cmd/deploy-rollup` to automate everything end-to-end (including the
runtime configs `genesis.json` and `rollup.json` that this package
alone can't produce).

## Compatibility note

CREATE2 addresses for the deployed proxies will **differ** from what
`OPCMv2.deploy()` would have produced on Ethereum L1, because
`Blueprint.deployFrom` uses `address(this)` as the CREATE2 deployer and
our splitter's address is not OPCMv2's. This is purely cosmetic — the
addresses are still consistent across all RSK deployments because the
splitter is the deployer in all cases.
