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
│   └── RSKOPCMSplitter.sol             # 8-stage splitter (the on-chain helper)
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
