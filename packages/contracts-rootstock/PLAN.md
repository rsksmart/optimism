# oprsk-contracts — F1 design plan

## Status (2026-05-04)

**Implemented.** Pending live regtest smoke test.

- `contracts/RSKOPCMSplitter.sol` — splitter contract (23,563 bytes deployed,
  1,013 bytes EIP-170 margin). Inherits `OPContractsManagerUtilsCaller`,
  exposes `deployStep1_loadProxies` + `step{2..5}_*` for initial deployment,
  `upgradeStep1_loadExisting` + `step{2..5}_*` for upgrades, and `migrate(...)`
  as a verbatim delegatecall pass-through to `OPContractsManagerMigrator`.
- `script/RSKDeployOPChain.s.sol` — Forge driver with `runSplit(...)`. Input
  ABI is byte-identical to upstream `Types.DeployOPChainInput`. Emits 6
  broadcasts (1 splitter deploy + 5 stage txs) per chain deployment.
- `cmd/deploy-rollup` — wired via the new `WorkingDir` field on
  `ForgeScriptInput`; `Config.OPRSKContractsDir()` resolves to this
  package. Existing `--use-split-deploy` CLI flag continues to drive the
  same code path; the only Go-side change is the script name + working dir.

Deviations from this plan:

- Stage granularity stayed at 5 (per the approved design); empirical
  retuning is deferred until smoke-test results are in.
- `upgrade` flow ships in the same splitter contract (not a separate
  `RSKOPCMUpgrader`) because the bytecode budget allowed it (1 KB margin).
  The `runSplit` script only exercises `deployStep1` today; `upgrade` /
  `migrate` get their driver entry points when the first non-deploy
  scenario hits regtest.
- The upstream `isPermittedUpgradeSequence` downgrade-protection check is
  a no-op stub on the upgrade path right now; will be wired through to
  `OPContractsManagerStandardValidator` when the first upgrade lands.
  Tracked inline in the splitter's `step2_systemConfigAndPortal` body.

## Problem

`OPContractsManagerV2.deploy(config)` (upstream `op-batcher/v1.16.7`,
`packages/contracts-bedrock/src/L1/opcm/OPContractsManagerV2.sol`) is a single
external call that, on the broadcasting side, requires ~10M gas (10,998,240
empirically with `forge --gas-estimate-multiplier 110`). RSKj enforces a per-tx
ceiling equal to the **sublist gas limit** (`TxValidatorGasLimitValidator`
under RSKIP144) which is hard-capped at 6,800,000 on regtest 9.1, regardless of
how high `targetgaslimit` is set. So no amount of regtest tuning can land
`opcmV2.deploy()` on RSK.

`OPCMv2.upgrade(_input)` and `OPCMv2.migrate(_input)` will hit the same wall
the first time RSK exercises them on a real chain.

## Approach (chosen during prior session)

- **Strategic path**: split v2's deploy/upgrade/migrate (don't fall back to v1).
- **Location**: out-of-tree `oprsk-contracts/`, parallels `oprsk/`.
- **Sub-approach**: external orchestrator script + a thin on-chain helper that
  holds ProxyAdmin authority across the multi-tx flow.

## Architectural insight

`OPCMv2` is a thin orchestrator built on top of two delegatecall-able helper
contracts:

- **`OPContractsManagerUtils`** holds *all* the per-step primitives as public
  external functions: `upgrade`, `loadOrDeployProxy`, `computeSalt`,
  `chainIdToBatchInboxAddress`, `makeGameArgs`, `getGameImpl`, `loadBytes`,
  `isMatchingInstruction*`, `hasInstruction`. The StorageSetter dance, the
  L1StandardBridge ChugSplash quirk, downgrade protection, version-tag checks —
  all of it lives in `Utils.sol`, not in OPCMv2 itself.
- **`OPContractsManagerUtilsCaller`** is the abstract base class (~250 lines)
  that provides `_upgrade`, `_loadOrDeployProxy`, `_makeGameArgs`, `_getGameImpl`
  etc. as `internal` wrappers that delegatecall into Utils. Inheriting from
  *this* (not the full `OPCMv2`) gives us the full helper surface in ~zero
  bytecode.
- **`OPContractsManagerContainer`** stores `Blueprints` and `Implementations`
  arrays as immutable state, exposed via `blueprints()` and `implementations()`
  externally. We can read both from any contract.

The only thing `OPCMv2.deploy()` *itself* contains (beyond delegating into the
helpers above) is **orchestration**: which `_upgrade` happens in which order
with which init args. That's ~120 LoC of straight-line code. **That's the only
thing we copy.**

## Design

### Contract: `oprsk-contracts/src/RSKOPCMSplitter.sol`

```solidity
contract RSKOPCMSplitter is OPContractsManagerUtilsCaller {
    IOPContractsManagerContainer public immutable container;
    address public immutable deployer;            // operator EOA
    bool public sealed;                           // post-finalize lock

    constructor(IOPContractsManagerUtils u, IOPContractsManagerContainer c, address _deployer)
        OPContractsManagerUtilsCaller(u)
    { container = c; deployer = _deployer; }

    modifier onlyDeployer() { require(msg.sender == deployer && !sealed); _; }

    // Read-throughs to the container (so internal helpers in
    // OPContractsManagerUtilsCaller see the impls/blueprints they expect)
    function blueprints()      public view returns (...) { return container.blueprints(); }
    function implementations() public view returns (...) { return container.implementations(); }

    // ---------- INITIAL DEPLOY ----------
    function deployStep1_loadProxies(FullConfig memory _cfg)
        external onlyDeployer returns (ChainContracts memory cts);
        // = _loadChainContracts(...) lifted verbatim. ProxyAdmin owner = address(this).

    function deployStep2_systemConfigAndPortal(FullConfig memory _cfg, ChainContracts memory _cts)
        external onlyDeployer;
        // = first slice of _apply: SystemConfig + OptimismPortal + ETHLockbox

    function deployStep3_messengerAndBridges(FullConfig memory _cfg, ChainContracts memory _cts)
        external onlyDeployer;
        // = next slice: L1CDM + L1StandardBridge + L1ERC721 + OptimismMintableERC20Factory

    function deployStep4_disputeFactoryAndASR(FullConfig memory _cfg, ChainContracts memory _cts)
        external onlyDeployer;
        // = DisputeGameFactory + DelayedWETH + AnchorStateRegistry + dispute-game-config loop

    function deployStep5_finalize(FullConfig memory _cfg, ChainContracts memory _cts)
        external onlyDeployer;
        // = ownership transfers (DGF, ProxyAdmin) + sealed = true

    // ---------- UPGRADES (same engine, different prelude) ----------
    function upgradeStep1_loadExisting(ISystemConfig _sc, ExtraInstruction[] memory _ins)
        external onlyDeployer returns (ChainContracts memory cts);
    // upgradeStep2..5 reuse the deploy* slices verbatim — the only difference is
    // _isInitialDeployment=false, which is captured as a boolean stored in storage
    // by step1 and consulted in step5_finalize (skip terminal ownership transfer
    // on upgrade).

    // ---------- MIGRATE ----------
    function migrate(IOPContractsManagerMigrator.MigrateInput calldata _input)
        external onlyDeployer;
    // = OPCMv2.migrate verbatim: delegatecall into opcmMigrator. If gas
    // profile turns out > 6.8M empirically, add migrateStepN later. No work
    // needed today.
}
```

Net unavoidable code copy from upstream:

- `deployStep1_loadProxies` ≈ `_loadChainContracts` (lines 370-547 of OPCMv2.sol; ~80 LoC of orchestration; helper bodies are inherited).
- `deployStep{2,3,4,5}` ≈ `_apply` (lines 749-966 of OPCMv2.sol; ~120 LoC of orchestration sliced into 4 stages).
- `_makeSystemConfigInitArgs` (lines 968-1009; ~30 LoC; only `internal` helper not already in Utils).
- `_assertValidFullConfig`, `_isPermittedInstruction`, etc.: only required for `upgrade()`, defer until first upgrade is run.

Total: **~230 LoC** of mechanical orchestration copy, where every line traces 1:1 to a line in upstream `OPCMv2.sol`. Helper bodies stay in `Utils.sol`.

### Why not just inherit `OPContractsManagerV2`?

Upstream `OPCMv2` deployed bytecode is 24,154 bytes — 98% of EIP-170's 24,576-byte cap. Adding even 5 small public step methods is likely to push us over. Inheriting `OPContractsManagerUtilsCaller` (not `OPCMv2`) avoids carrying any of `OPCMv2`'s orchestration in our bytecode while still giving us the full delegatecall-helper surface.

### Stage gas budget (rough)

A representative initial deploy:

| Stage | Calls | Estimated gas |
|---|---|---|
| step1 loadProxies | 11× `Blueprint.deployFrom` (proxies) + `setAddressManager` + `transferOwnership` | ~3.5M |
| step2 systemConfig+portal | 3× `_upgrade` (≈ each is one `proxyAdmin.upgrade` + `storageSetter.setBytes32` + `proxyAdmin.upgradeAndCall` + initializer body). SystemConfig.initialize is heavy. | ~5–6M (tightest) |
| step3 messenger+bridges | 4× `_upgrade` | ~3M |
| step4 disputeFactory+ASR+games | 3× `_upgrade` + N× `setImplementation`+`setInitBond` | ~3–4M |
| step5 finalize | 2× `transferOwnership` | ~100k |

Tight stage = step2 (SystemConfig.initialize is the largest initializer). If it
empirically exceeds 6.8M, we split it into step2a (SystemConfig only) + step2b
(Portal + ETHLockbox). Easy retune.

### Forge script: `oprsk-contracts/script/RSKDeployOPChain.s.sol`

Mirrors upstream `DeployOPChain.s.sol`'s `runWithBytes(bytes)` ABI so
`cmd/deploy-rollup` doesn't need a different output decoder. Per-step layout:

```solidity
function run(Types.DeployOPChainInput memory _input) public returns (Output memory output_) {
    checkInput(_input);

    // 0. Deploy the splitter (one tx).
    vm.broadcast(msg.sender);
    RSKOPCMSplitter sp = new RSKOPCMSplitter(_utils(_input.opcm), _container(_input.opcm), msg.sender);

    IOPContractsManagerV2.FullConfig memory cfg = _toOPCMV2DeployInput(_input);
    IOPContractsManagerV2.ChainContracts memory cts;

    // 1..5. One vm.broadcast per stage.
    vm.broadcast(msg.sender); cts = sp.deployStep1_loadProxies(cfg);
    vm.broadcast(msg.sender); sp.deployStep2_systemConfigAndPortal(cfg, cts);
    vm.broadcast(msg.sender); sp.deployStep3_messengerAndBridges(cfg, cts);
    vm.broadcast(msg.sender); sp.deployStep4_disputeFactoryAndASR(cfg, cts);
    vm.broadcast(msg.sender); sp.deployStep5_finalize(cfg, cts);

    output_ = _fromOPCMV2OutputToOutput(cts);
    checkOutput(_input, output_);
    vm.label(...);
}
```

Forge `--slow` ensures one tx per `vm.broadcast`. Total: 6 transactions.

### `cmd/deploy-rollup` integration

- `runner.go::Steps()`: when `UseSplitDeploy` is true, swap `Deploy OP Chain
  (Split)` for the new `Deploy OP Chain (RSK Split)` step that targets
  `oprsk-contracts/script/RSKDeployOPChain.s.sol:RSKDeployOPChain`.
- `forge.go`: pass `oprsk-contracts/` as a script directory (or use
  `--root` to point at the upstream contracts package, with the script
  referenced by an absolute path). To be decided when we run forge for the
  first time and see which import resolution works cleanest.

The state-extraction code in `steps.go` already reads addresses from the
broadcast JSON by contract name; the names produced by our deploy match
upstream's, so no parser changes needed.

## File layout

```
oprsk-contracts/
├── README.md
├── PLAN.md                                  # this file
├── foundry.toml                             # remappings into upstream contracts-bedrock
├── src/
│   └── RSKOPCMSplitter.sol                  # the splitter contract (~250 LoC)
├── script/
│   └── RSKDeployOPChain.s.sol               # forge driver script (~150 LoC)
└── test/
    └── RSKDeployOPChain.t.sol               # anvil-level dry run (optional, post-MVP)
```

## Risks / open questions

- **CREATE2 address divergence**: `Blueprint.deployFrom` uses `address(this)` as
  the CREATE2 deployer. Since the splitter's address differs from OPCMv2's, the
  resulting proxy addresses will differ from what `opcmV2.deploy()` would have
  produced. Our `cmd/deploy-rollup` already records addresses from broadcast
  logs, so this is purely cosmetic — but worth noting if any downstream tool
  expects deterministic OPCMv2-derived addresses.
- **Splitter constructor cost**: deploying `RSKOPCMSplitter` is one extra tx
  (~1–2M gas). Acceptable.
- **Upgrade ordering invariant**: `_apply()` orders upgrades carefully — Portal
  before ETHLockbox before LCDM, etc. We must preserve order across stage
  boundaries. Stage 2/3/4 boundaries chosen to respect that.
- **Tests**: upstream `test/opcm/DeployOPChain.t.sol` will not run against this
  path (its fixtures assume `opcmV2.deploy()`). Out of scope; we lean on the
  live regtest smoke + the upstream tests that *do* run on `opcmV2.deploy()`
  (which still works on Ethereum-style L1s with no gas cap).

## Out of scope

- Rewriting upstream's `OPCMv2.upgrade()` or `migrate()` until we have a real
  chain to upgrade/migrate. The splitter's `migrate(...)` is a verbatim port of
  `OPCMv2.migrate(...)`; if that exceeds 6.8M empirically, we add stages.
- Renumbering `cmd/deploy-rollup` flags. `--use-split-deploy` keeps its meaning.
