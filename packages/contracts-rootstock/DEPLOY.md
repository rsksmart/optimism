# Deploying an OP Chain to Rootstock (RSK)

This guide walks through deploying the OP Stack L1 contracts to a Rootstock
(RSK) L1 using **only `forge` and `cast`**, from inside the `optimism` fork.
No external Go tooling, no upstream `op-deployer`, no parent rollup repository.

If you'd rather have one binary do everything end-to-end (including the
runtime `genesis.json` / `rollup.json` files this Forge-only path can't
produce), use the RSK orchestrator that ships in this fork:

```bash
go install github.com/ethereum-optimism/optimism/rsk/op-deployer/cmd/deploy-rollup@latest
```

See `rsk/op-deployer/README.md` for usage. The Forge-only steps below are
retained for operators who prefer not to install Go tooling, or who want
full per-transaction visibility (debugging, audit, manual gas tuning).

---

## Why this package exists

`OPContractsManagerV2.deploy(config)` (upstream OP Stack release tag
`op-batcher/v1.16.7`) is a single ~10 M-gas external call. RSKj enforces a
**per-transaction sublist gas limit** under RSKIP144, hard-capped at
~6.8 M on regtest 9.x regardless of how `targetgaslimit` is set. The
monolithic call therefore can never land on RSK.

`contracts-rootstock/` ships a thin orchestrator (`RSKOPCMSplitter.sol`)
that exposes the same end-state as `OPCMv2.deploy()` but as **8 separate
transactions**, each empirically under the 6.8 M cap. The Forge driver
(`script/RSKDeployOPChain.s.sol`) walks the splitter through its 7 stages.

Output address layout is byte-identical to upstream's `DeployOPChain.Output`,
so any downstream tooling parsing broadcast JSON works unchanged.

See `PLAN.md` for the design rationale, gas budget per stage, and the
EIP-170 bytecode tradeoffs that drove the 1a/1b and 4a/4b splits.

---

## Prerequisites

### Tooling

- **Foundry** with `forge` and `cast` on PATH.
- **`jq`** (used for ABI-encoding inputs in the examples below; any equivalent
  works).

### L1 (RSK)

- A reachable RSKj endpoint (regtest, testnet, or mainnet).
- An EOA with **enough RBTC** to cover the deploy. Minimum: ~80 M gas total
  across all steps at the minimum gas price the chain accepts (regtest is
  ~0.06 gwei). Budget at least 0.5 RBTC for safety on regtest.
- The **CREATE2 deterministic deployer** (`0x4e59b44847b379578588920cA78FbF26c0B4956C`)
  must be deployed on the L1. On regtest you can deploy it once with the
  standard pre-signed transaction (see "CREATE2 factory" below).

### Foundry config

Upstream `optimism/packages/contracts-bedrock/foundry.toml` sets
`deny = "warnings"`, which causes `forge build` to fail with a
`Lint failed (...) aborting due to N linter warning(s)` error on the
contracts-bedrock tree. For deployment runs you can either:

```bash
export FOUNDRY_DENY=never
```

…or pass `--lint-deny never` on each `forge build` / `forge script`
invocation. The runbook below assumes the env var is set.

---

## Deployment overview

Four Forge invocations, in order. Each emits a broadcast file under
`<package>/broadcast/<script>/<l1ChainId>/run-latest.json` (or
`runSplit-latest.json`, `runWithDump-latest.json`) from which you'll
extract the addresses you need to feed into the next step.

| # | Script | Package | Tx count | Output |
|---|---|---|---|---|
| 1 | `DeploySuperchain.run` | contracts-bedrock | ~5 | SuperchainConfig, ProtocolVersions, SuperchainProxyAdmin |
| 2 | `DeployImplementations.runWithBytes` | contracts-bedrock | ~16 | All impls + `OPCMv2` |
| 3 | `RSKDeployOPChain.runSplit` | contracts-rootstock (this) | **8** | All proxies + dispute games |
| 4 | `L2GenesisDump.runWithDump` (you write a wrapper) | contracts-bedrock | 0 (off-chain) | `l2-allocs.json` |

After step 4 you have all the on-chain state for an OP Chain plus the L2
genesis allocations. To turn that into runtime `genesis.json` and
`rollup.json` you need either the `op-node` CLI's `genesis l2` and
`genesis rollup` subcommands, or the parent rollup repo's `deploy-rollup`
helper. That last-mile is **out of scope** for this contracts-only guide.

### Common forge flags for RSK

Every step below shares the same RSK-friendly flag set:

```text
--rpc-url <RPC>             RSK L1 RPC endpoint
--private-key <KEY>         deployer EOA (without 0x is fine)
--broadcast                 actually send transactions
--legacy                    type-0 txs only (RSK has no EIP-1559)
--slow                      one tx at a time, wait for receipt before next
--gas-estimate-multiplier 110   keep padded gas under the 6.8 M sublist cap
                                (Forge default is 130, which trips the cap
                                even on transactions that fit raw)
-vvvv                       verbose; helpful for diagnosing reverts
```

Use them on every `forge script --broadcast` call below.

### Variable conventions

The examples assume you've exported:

```bash
export L1_RPC=http://127.0.0.1:4444         # RSK regtest
export L1_CHAIN_ID=33
export L2_CHAIN_ID=200133
export DEPLOYER_KEY=<hex>                    # 32-byte private key, no 0x
export DEPLOYER=$(cast wallet address --private-key $DEPLOYER_KEY)
export FOUNDRY_DENY=never
```

For a regtest using the standard "cow" pre-funded account:

```bash
export DEPLOYER_KEY=c85ef7d79691fe79573b1a7064c19c1a9819ebdbd1faaab1a8ec92344438aaf4
export DEPLOYER=0xcd2a3d9f938e13cd947ec05abc7fe734df8dd826
```

---

## CREATE2 factory (one-time, regtest only)

Public networks already have the deterministic CREATE2 deployer at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. On a fresh regtest you
must deploy it once. The factory is deployed by sending a single
**pre-signed legacy transaction** (Nick's method, gas-price 100 gwei,
nonce 0 from a one-shot signer):

```bash
# 1) Fund the factory deployer (signer of the pre-signed tx)
cast send 0x3fAB184622Dc19b6109349B94811493BF2a45362 \
  --value 0.05ether \
  --rpc-url $L1_RPC --private-key $DEPLOYER_KEY \
  --legacy

# 2) Submit the canonical CREATE2 factory deployment tx
cast publish \
  0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222 \
  --rpc-url $L1_RPC

# 3) Verify
cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $L1_RPC | head -c 20
# expect: 0x6080604052348015...
```

Skip this section on testnet/mainnet — it's already there.

---

## Step 1 — Deploy Superchain

**Script:** `optimism/packages/contracts-bedrock/scripts/deploy/DeploySuperchain.s.sol:DeploySuperchain`
**Function:** `run(Input memory)` — Input tuple is:

```solidity
struct Input {
    address guardian;
    address protocolVersionsOwner;
    address superchainProxyAdminOwner;
    bool    paused;
    bytes32 recommendedProtocolVersion;
    bytes32 requiredProtocolVersion;
}
```

For a single-operator regtest, set all three role addresses to your EOA.
Both protocol-version fields can be the version-9.0.0 sentinel
`0x0000…0009000000000000000000000000`.

Run from `optimism/packages/contracts-bedrock`:

```bash
cd optimism/packages/contracts-bedrock

forge script scripts/deploy/DeploySuperchain.s.sol:DeploySuperchain \
  --sig 'run((address,address,address,bool,bytes32,bytes32))' \
  "($DEPLOYER,$DEPLOYER,$DEPLOYER,false,0x0000000000000000000000000000000000000009000000000000000000000000,0x0000000000000000000000000000000000000009000000000000000000000000)" \
  --rpc-url $L1_RPC --private-key $DEPLOYER_KEY \
  --broadcast --legacy --slow --gas-estimate-multiplier 110 \
  -vvvv
```

Extract the 5 addresses from the broadcast log:

```bash
BROADCAST=broadcast/DeploySuperchain.s.sol/$L1_CHAIN_ID/run-latest.json
export SUPERCHAIN_CONFIG_PROXY=$(jq -r '.returns.output_.value | fromjson | .superchainConfigProxy' $BROADCAST 2>/dev/null \
  || jq -r '.transactions[] | select(.contractName == "Proxy" and .arguments[0] == env.SUPERCHAIN_CONFIG_IMPL) | .contractAddress' $BROADCAST)
# (also extract: protocolVersionsProxy, superchainProxyAdmin, superchainConfigImpl, protocolVersionsImpl)
```

In practice the cleanest way to read these out of the broadcast JSON is
to grep transaction names — the contract names are emitted on each
deployment. For example:

```bash
jq -r '.transactions[] | "\(.contractName // "?")\t\(.contractAddress)"' \
  broadcast/DeploySuperchain.s.sol/$L1_CHAIN_ID/run-latest.json
```

You'll need `superchainConfigProxy`, `protocolVersionsProxy`, and
`superchainProxyAdmin` for step 2.

---

## Step 2 — Deploy Implementations

**Script:** `optimism/packages/contracts-bedrock/scripts/deploy/DeployImplementations.s.sol:DeployImplementations`
**Function:** `runWithBytes(bytes)` — takes ABI-encoded `Input`:

```solidity
struct Input {
    uint256 withdrawalDelaySeconds;
    uint256 minProposalSizeBytes;
    uint256 challengePeriodSeconds;
    uint256 proofMaturityDelaySeconds;
    uint256 disputeGameFinalityDelaySeconds;
    uint256 mipsVersion;
    bytes32 devFeatureBitmap;
    uint256 faultGameV2MaxGameDepth;
    uint256 faultGameV2SplitDepth;
    uint256 faultGameV2ClockExtension;
    uint256 faultGameV2MaxClockDuration;
    address superchainConfigProxy;
    address protocolVersionsProxy;
    address superchainProxyAdmin;
    address l1ProxyAdminOwner;
    address challenger;
    bool    skipFaultProofs;     // set TRUE on RSK to skip OptimismPortalInterop,
                                 // FaultDisputeGame, PermissionedDisputeGame, and
                                 // OPCMStandardValidator (each ~6 M gas to deploy
                                 // and not used by the permissioned-only path)
}
```

ABI-encode the input with `cast`:

```bash
INPUT_BYTES=$(cast abi-encode \
  'f((uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,address,address,address,address,address,bool))' \
  "(604800,126000,86400,604800,302400,8,0x0,73,30,10800,302400,$SUPERCHAIN_CONFIG_PROXY,$PROTOCOL_VERSIONS_PROXY,$SUPERCHAIN_PROXY_ADMIN,$DEPLOYER,$DEPLOYER,true)")

forge script scripts/deploy/DeployImplementations.s.sol:DeployImplementations \
  --sig 'runWithBytes(bytes)' "$INPUT_BYTES" \
  --rpc-url $L1_RPC --private-key $DEPLOYER_KEY \
  --broadcast --legacy --slow --gas-estimate-multiplier 110 \
  -vvvv
```

Extract `OPContractsManagerV2` (a.k.a. `opcm`) from the broadcast — that's
the only address step 3 needs. The pre-`v1.16.7` `OPContractsManager`
return slot is a leftover ABI placeholder and is always zero on this
release.

```bash
export OPCM=$(jq -r '.transactions[] | select(.contractName == "OPContractsManagerV2") | .contractAddress' \
  broadcast/DeployImplementations.s.sol/$L1_CHAIN_ID/run-latest.json | head -1)
```

---

## Step 3 — Deploy OP Chain (split, RSK-specific)

This is the step that fails on stock OP Stack against RSK and is the
reason this package exists. Use **`RSKDeployOPChain`** in
`contracts-rootstock/` instead of upstream's `DeployOPChain`.

**Script:** `optimism/packages/contracts-rootstock/script/RSKDeployOPChain.s.sol:RSKDeployOPChain`
**Function:** `runSplit(Types.DeployOPChainInput memory)` — Input tuple
is byte-identical to upstream `Types.DeployOPChainInput`:

```solidity
struct DeployOPChainInput {
    address opChainProxyAdminOwner;
    address systemConfigOwner;
    address batcher;
    address unsafeBlockSigner;
    address proposer;
    address challenger;
    uint32  basefeeScalar;
    uint32  blobBaseFeeScalar;
    uint256 l2ChainId;
    address opcm;
    string  saltMixer;
    uint64  gasLimit;
    GameType  disputeGameType;             // uint32; 1 = permissioned
    Claim     disputeAbsolutePrestate;     // bytes32
    uint256 disputeMaxGameDepth;
    uint256 disputeSplitDepth;
    Duration disputeClockExtension;        // uint64 seconds
    Duration disputeMaxClockDuration;      // uint64 seconds
    bool    allowCustomDisputeParameters;
    uint32  operatorFeeScalar;
    uint64  operatorFeeConstant;
    ISuperchainConfig superchainConfig;    // address
    bool    useCustomGasToken;
}
```

Choose your batcher and proposer addresses **before** running this step.
Each must be funded on L1 with enough RBTC to operate (~10 RBTC each is
plenty for regtest). They will sign every batch / output-root tx going
forward; do **not** use the deployer EOA for these roles in production
(L1 nonce contention).

Run from `optimism/packages/contracts-rootstock`:

```bash
cd optimism/packages/contracts-rootstock

forge script script/RSKDeployOPChain.s.sol:RSKDeployOPChain \
  --sig 'runSplit((address,address,address,address,address,address,uint32,uint32,uint256,address,string,uint64,uint32,bytes32,uint256,uint256,uint64,uint64,bool,uint32,uint64,address,bool))' \
  "($DEPLOYER,$DEPLOYER,$BATCHER,$DEPLOYER,$PROPOSER,$DEPLOYER,1000000,1000000,$L2_CHAIN_ID,$OPCM,\"$L2_CHAIN_ID\",30000000,1,0x0000000000000000000000000000000000000000000000000000000000000001,73,30,10800,302400,false,0,0,$SUPERCHAIN_CONFIG_PROXY,false)" \
  --rpc-url $L1_RPC --private-key $DEPLOYER_KEY \
  --broadcast --legacy --slow --gas-estimate-multiplier 110 \
  -vvvv
```

This emits **8 broadcasts** from this Forge invocation:

| # | Function | Approx. padded gas |
|---|---|---|
| 1 | `CREATE` `RSKOPCMSplitter` | 4.7 M |
| 2 | `deployStep1a_coreProxies` | 3.9 M |
| 3 | `deployStep1b_remainingProxies` | 4.3 M |
| 4 | `step2_systemConfigAndPortal` | 1.1 M |
| 5 | `step3_messengerAndBridges` | 0.9 M |
| 6 | `step4a_disputeFactoryAndWeth` | 0.4 M |
| 7 | `step4b_anchorAndGames` | 0.7 M |
| 8 | `step5_finalize` | 0.1 M |

All comfortably under the 6.8 M RSKIP144 sublist cap.

The broadcast file will be at
`broadcast/RSKDeployOPChain.s.sol/$L1_CHAIN_ID/runSplit-latest.json`.
Extract OP Chain addresses by contract name as before:

```bash
jq -r '.transactions[] | "\(.contractName // "?")\t\(.contractAddress)"' \
  broadcast/RSKDeployOPChain.s.sol/$L1_CHAIN_ID/runSplit-latest.json
```

You'll see (among others) `OptimismPortal` (the proxy), `SystemConfig`,
`L1CrossDomainMessenger`, `L1StandardBridge`, `DisputeGameFactory`,
`AnchorStateRegistry`, and `DelayedWETH`. These are the addresses
downstream tooling consumes.

---

## Step 4 — L2 Genesis allocations

Upstream `L2Genesis.s.sol` sets up L2 predeploys but doesn't write the
state to disk. Wrap it in a one-shot script that calls
`vm.dumpState(path)` after `run(...)`. From
`optimism/packages/contracts-bedrock/scripts/`, create:

```solidity
// scripts/L2GenesisDump.s.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;
import { L2Genesis } from "scripts/L2Genesis.s.sol";

contract L2GenesisDump is L2Genesis {
    function runWithDump(Input memory _input, string memory _outputPath) public {
        run(_input);
        vm.dumpState(_outputPath);
    }
}
```

The Input tuple is large (32 fields). The minimum non-zero values for an
RSK regtest are below; anything not mentioned can be `address(0)`, `0`,
or `false`:

```solidity
struct Input {
    uint256 l1ChainID;                                 // 33 (RSK regtest)
    uint256 l2ChainID;                                 // 200133
    address payable l1CrossDomainMessengerProxy;       // from step 3
    address payable l1StandardBridgeProxy;             // from step 3
    address payable l1ERC721BridgeProxy;               // from step 3
    address opChainProxyAdminOwner;                    // your EOA
    address sequencerFeeVaultRecipient;                // your EOA
    uint256 sequencerFeeVaultMinimumWithdrawalAmount;  // 10 ether
    uint256 sequencerFeeVaultWithdrawalNetwork;        // 0
    address baseFeeVaultRecipient;
    uint256 baseFeeVaultMinimumWithdrawalAmount;
    uint256 baseFeeVaultWithdrawalNetwork;
    address l1FeeVaultRecipient;
    uint256 l1FeeVaultMinimumWithdrawalAmount;
    uint256 l1FeeVaultWithdrawalNetwork;
    address operatorFeeVaultRecipient;
    uint256 operatorFeeVaultMinimumWithdrawalAmount;
    uint256 operatorFeeVaultWithdrawalNetwork;
    address governanceTokenOwner;
    uint256 fork;                                       // 8 = Holocene
    bool    enableGovernance;                           // false
    bool    fundDevAccounts;                            // true on regtest
    bool    useRevenueShare;                            // false
    address chainFeesRecipient;
    address l1FeesDepositor;
    bool    useCustomGasToken;                          // false
    bool    useInterop;                                 // false
    string  gasPayingTokenName;                         // ""
    string  gasPayingTokenSymbol;                       // ""
    uint256 nativeAssetLiquidityAmount;                 // 0
    address liquidityControllerOwner;
    bytes32 devFeatureBitmap;                           // 0x0
}
```

**Note:** the `Input` struct has historically drifted between OP Stack
release tags (`deployCrossL2Inbox` was removed, `useInterop` and
`devFeatureBitmap` were added on `op-batcher/v1.16.7`). If you regenerate
this from a different release, re-grep `struct Input` in
`scripts/L2Genesis.s.sol` and re-derive the tuple signature.

Run **without** `--broadcast` (state dump runs locally):

```bash
cd optimism/packages/contracts-bedrock

forge script scripts/L2GenesisDump.s.sol:L2GenesisDump \
  --sig 'runWithDump((uint256,uint256,address,address,address,address,address,uint256,uint256,address,uint256,uint256,address,uint256,uint256,address,uint256,uint256,address,uint256,bool,bool,bool,address,address,bool,bool,string,string,uint256,address,bytes32),string)' \
  "($L1_CHAIN_ID,$L2_CHAIN_ID,$L1_CROSS_DOMAIN_MESSENGER_PROXY,$L1_STANDARD_BRIDGE_PROXY,$L1_ERC721_BRIDGE_PROXY,$DEPLOYER,$DEPLOYER,10000000000000000000,0,$DEPLOYER,10000000000000000000,0,$DEPLOYER,10000000000000000000,0,$DEPLOYER,10000000000000000000,0,$DEPLOYER,8,false,true,false,$DEPLOYER,$DEPLOYER,false,false,\"\",\"\",0,$DEPLOYER,0x0)" \
  "$(pwd)/../../../l2-allocs.json" \
  -vvvv
```

Output: a JSON file at the path you passed (`l2-allocs.json` in the
example above) containing the full L2 EVM state with all predeploys at
their canonical addresses, baked against the L1 contracts you deployed
in step 3.

---

## What's next

The four steps above produce all the **on-chain** state needed. To
actually run an OP Chain you also need:

1. **`genesis.json`** — the L2 execution-layer genesis block,
   constructed from `l2-allocs.json` + chain config. Generate with
   `op-node genesis l2 --l2-allocs l2-allocs.json --deploy-config <cfg>
   --l1-rpc <RPC> --l2-chain-id <id> --outfile genesis.json`.
2. **`rollup.json`** — the consensus-layer config consumed by
   `op-node`. Generate with `op-node genesis rollup --deploy-config
   <cfg> --outfile rollup.json --l1-rpc <RPC>`.
3. Run the three OP services (`op-node`, `op-batcher`, `op-proposer`)
   pointed at those configs.

Both `op-node genesis ...` subcommands need a "deploy-config" JSON that
mirrors most of the inputs you fed into steps 1–4. The parent rollup
repository's `cmd/deploy-rollup` Go tool builds this file for you;
without it you'll have to hand-author one from upstream's documented
schema.

The simplest path post-step-4 is the bundled RSK orchestrator:

```bash
go install github.com/ethereum-optimism/optimism/rsk/op-deployer/cmd/deploy-rollup@latest
deploy-rollup --workdir <your-workdir> --resume --start-from generate-genesis
```

The state files (`deployment_state.json`, `state.json`) it writes can
be reconstructed from the broadcast JSONs you have, so even a partial
hand-deploy can hand off to the Go tool for runtime-config generation.

---

## Troubleshooting

### `transaction's gas limit of N is higher than the block's gas limit of 6800000`

You forgot `--gas-estimate-multiplier 110` on a non-`runSplit` script,
or your RSKj is on an older release with a different sublist cap. The
splitter (`RSKDeployOPChain.runSplit`) is the only step that's been
empirically tuned to fit; all other scripts deploy contracts that fit
*raw*, but Forge's default 130 % padding pushes them over. Lower the
multiplier and retry.

If `runSplit` itself fails with this error, RSKj has changed its
sublist cap or one of our stages has bloated past the empirical
budget. Check the broadcast JSON for which `step*` function tripped
and consider further-splitting it.

### `Lint failed (...) aborting due to N linter warning(s)`

Set `FOUNDRY_DENY=never` (or `--lint-deny never`). See the foundry
config note in Prerequisites.

### `Function runWithDump(...) is not implemented in your script`

Your `runWithDump` signature drifted from upstream's `L2Genesis.Input`
struct. Re-grep `struct Input` in `scripts/L2Genesis.s.sol` of your
release tag and update the tuple signature in your `forge script`
invocation accordingly.

### `Source "..." not found`

Forge prioritises the local `src/` directory over `src/=...`
remappings. Keep this package's source under `contracts/` (already
the case) — never rename it to `src/`, or the
`src/=../contracts-bedrock/src/` remapping will silently break.

### `File outside of allowed directories`

You're invoking `forge` from a directory other than
`optimism/packages/contracts-rootstock/` and `solc` lost the
`allow_paths` resolution. Always `cd` into the package before running
`forge script`.

### CREATE2 deploys revert with "create2 deployer not found"

`0x4e59b44847b379578588920cA78FbF26c0B4956C` is not deployed on your L1.
See "CREATE2 factory" above for the regtest one-shot.

---

## See also

- `PLAN.md` — design rationale, gas budget per stage, EIP-170 splits.
- `contracts/RSKOPCMSplitter.sol` — the on-chain splitter implementation.
- `script/RSKDeployOPChain.s.sol` — the Forge driver for `runSplit`.
- `../../rsk/op-deployer/` — the bundled Go orchestrator that automates every
  step in this guide, plus runtime-config generation (`genesis.json`,
  `rollup.json`).
