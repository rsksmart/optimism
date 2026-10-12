// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// =============================================================================
// RSKOPCMSplitter
//
// A thin one-shot helper contract that decomposes the upstream
// OPContractsManagerV2 chain-management entry points (`deploy`, `upgrade`,
// `migrate`) into multi-tx sequences each fitting under RSKj's RSKIP144 6.8M
// per-tx sublist gas cap.
//
// Invariants vs upstream:
//   * Inherits `OPContractsManagerUtilsCaller` to reuse the inherited
//     `_loadOrDeployProxy`, `_upgrade`, `_makeGameArgs`, `_getGameImpl` and
//     `_encodeSystemConfigInit` helpers verbatim. The actual bodies of most
//     of those helpers live in the deployed `OPContractsManagerUtils`
//     contract and are reached via delegatecall — so the StorageSetter
//     dance, the L1StandardBridge ChugSplash quirk, downgrade protection,
//     version-tag checks, etc. all carry over exactly.
//   * `_loadChainContracts` and `_apply` are lifted line-for-line from
//     `OPContractsManagerV2.sol` (op-contracts v9, op-node/v1.19.9) and split
//     into stage methods. Each stage's body is a contiguous slice of
//     upstream's straight-line code; nothing is reordered.
//   * Two deliberate divergences in `_assertValidFullConfig`, both about
//     PERMISSIONED_CANNON (the output-root permissioned game RSK deploys):
//     - an initial deployment may enable it although op-contracts v9
//       hard-wires SUPER_ROOT_GAMES_MIGRATION on, which upstream reads as
//       "initial deployments use super-root games only". RSK runs one L2
//       per L1 with no interop, so a super-root game buys nothing and would
//       make the proposer depend on a super-root RPC;
//     - it may carry a zero init bond. Upstream requires a non-zero bond for
//       every enabled game except SUPER_PERMISSIONED; on a permissioned game
//       only the proposer can create games, so the bond is parked capital
//       with no anti-spam value (PAYROLLUP-191).
//
// Each splitter instance is per-chain-operation: deploy it, run a session,
// throw it away. The `sealed` flag makes that explicit at the contract
// level.
//
// The `deployer` immutable is the operator EOA that constructed the
// splitter; only that EOA may call into the stage methods. The splitter
// itself owns the ProxyAdmin during the deploy session and transfers
// ownership to `_cfg.proxyAdminOwner` at the very end of stage 5 (initial
// deployments only — upgrades skip the terminal transfer).
// =============================================================================

import { OPContractsManagerUtilsCaller } from "src/L1/opcm/OPContractsManagerUtilsCaller.sol";

import { Blueprint } from "src/libraries/Blueprint.sol";
import { GameType, GameTypes, Proposal } from "src/dispute/lib/Types.sol";
import { SemverComp } from "src/libraries/SemverComp.sol";
import { Features } from "src/libraries/Features.sol";
import { DevFeatures } from "src/libraries/DevFeatures.sol";
import { Constants } from "src/libraries/Constants.sol";

import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { IDelayedWETH } from "interfaces/dispute/IDelayedWETH.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IAddressManager } from "interfaces/legacy/IAddressManager.sol";
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IOptimismPortal2 as IOptimismPortal } from "interfaces/L1/IOptimismPortal2.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IOptimismMintableERC20Factory } from "interfaces/universal/IOptimismMintableERC20Factory.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { IOPContractsManagerContainer } from "interfaces/L1/opcm/IOPContractsManagerContainer.sol";
import { IOPContractsManagerStandardValidator } from "interfaces/L1/IOPContractsManagerStandardValidator.sol";
import { IOPContractsManagerUtils } from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import { IOPContractsManagerMigrator } from "interfaces/L1/opcm/IOPContractsManagerMigrator.sol";

contract RSKOPCMSplitter is OPContractsManagerUtilsCaller {
    // -----------------------------------------------------------------------
    // Type aliases — mirror upstream OPContractsManagerV2 storage shapes so
    // the same struct values can flow back and forth across stage calls
    // without ABI translation.
    // -----------------------------------------------------------------------
    struct ChainContracts {
        ISystemConfig systemConfig;
        IProxyAdmin proxyAdmin;
        IAddressManager addressManager;
        IL1CrossDomainMessenger l1CrossDomainMessenger;
        IL1ERC721Bridge l1ERC721Bridge;
        IL1StandardBridge l1StandardBridge;
        IOptimismPortal optimismPortal;
        IETHLockbox ethLockbox;
        IOptimismMintableERC20Factory optimismMintableERC20Factory;
        IDisputeGameFactory disputeGameFactory;
        IAnchorStateRegistry anchorStateRegistry;
        IDelayedWETH delayedWETH;
    }

    /// @notice Subset of ChainContracts produced by `deployStep1a_coreProxies`
    ///         and consumed by `deployStep1b_remainingProxies`. Carries the
    ///         "loadFrom" sources (systemConfig + optimismPortal) that step1b
    ///         needs to drive subsequent `_loadOrDeployProxy` calls.
    struct ChainContractsCore {
        IProxyAdmin proxyAdmin;
        IAddressManager addressManager;
        ISystemConfig systemConfig;
        IOptimismPortal optimismPortal;
        IETHLockbox ethLockbox;
    }

    struct FullConfig {
        string saltMixer;
        ISuperchainConfig superchainConfig;
        address proxyAdminOwner;
        address systemConfigOwner;
        address unsafeBlockSigner;
        address batcher;
        Proposal startingAnchorRoot;
        GameType startingRespectedGameType;
        uint32 basefeeScalar;
        uint32 blobBasefeeScalar;
        uint64 gasLimit;
        uint256 l2ChainId;
        IResourceMetering.ResourceConfig resourceConfig;
        IOPContractsManagerUtils.DisputeGameConfig[] disputeGameConfigs;
        bool useCustomGasToken;
    }

    struct UpgradeInput {
        ISystemConfig systemConfig;
        IOPContractsManagerUtils.DisputeGameConfig[] disputeGameConfigs;
        IOPContractsManagerUtils.ExtraInstruction[] extraInstructions;
    }

    /// @notice Number of dispute game configs a full config must supply. Mirror of
    ///         `OPContractsManagerV2.VALID_GAME_TYPE_COUNT`.
    uint256 internal constant VALID_GAME_TYPE_COUNT = 6;

    /// @notice The valid game types, packed low-to-high as six uint32s in the order the dispute
    ///         game configs must be supplied: CANNON, PERMISSIONED_CANNON, CANNON_KONA,
    ///         SUPER_PERMISSIONED, SUPER_CANNON_KONA, ZK_DISPUTE_GAME. Mirror of
    ///         `OPContractsManagerV2.VALID_GAME_TYPES`.
    uint256 internal constant VALID_GAME_TYPES = 0x0000000a_00000009_00000005_00000008_00000001_00000000;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error RSKOPCMSplitter_NotDeployer();
    error RSKOPCMSplitter_AlreadySealed();
    error RSKOPCMSplitter_AlreadyStarted();
    error RSKOPCMSplitter_NotStarted();
    error RSKOPCMSplitter_InvalidGameConfigs();
    error RSKOPCMSplitter_SuperchainConfigNeedsUpgrade();
    error RSKOPCMSplitter_CannotUpgradeToCustomGasToken();
    error RSKOPCMSplitter_InvalidEthLockbox();
    error RSKOPCMSplitter_ZeroGameImplementation(GameType _gameType);

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    /// @notice Container that holds the Implementations + Blueprints arrays.
    ///         Read-through from `blueprints()` / `implementations()`.
    IOPContractsManagerContainer public immutable container;

    /// @notice The operator EOA that constructed this splitter. Only this
    ///         account may drive the stage methods.
    address public immutable deployer;

    /// @notice Standard validator + migrator addresses, mirrored from
    ///         the OPCMv2 release. Only `migrator` is referenced post-
    ///         construction (via `migrate`).
    IOPContractsManagerStandardValidator public immutable opcmStandardValidator;
    IOPContractsManagerMigrator public immutable opcmMigrator;

    // -----------------------------------------------------------------------
    // Per-session state
    // -----------------------------------------------------------------------

    /// @notice Phase tracker:
    ///   0 = not started
    ///   1 = step1a done (core proxies), step1b next        [deploy only]
    ///   2 = step1b done OR upgradeStep1 done, step2 next
    ///   3 = step2 done, step3 next
    ///   4 = step3 done, step4a next
    ///   5 = step4a done (DGF + DelayedWETH upgraded), step4b next
    ///   6 = step4b done (ASR + dispute games), step5 next
    ///   255 = sealed (no further calls accepted).
    ///
    /// @dev Stage 1 is split because, on RSKj regtest, the 12-proxy graph
    ///      empirically lands at ~7.6M raw / ~8.35M padded — over RSKj's
    ///      RSKIP144 6.8M per-tx sublist cap. The split is 5/7 by proxy
    ///      count (the heavier ProxyAdmin + AddressManager land in 1a).
    ///
    /// @dev Stage 4 is split because the combined gas of DGF._upgrade +
    ///      DelayedWETH._upgrade + ASR._upgrade + the 6-game dispute config
    ///      loop empirically lands at ~7.17M raw / ~7.89M padded, also over
    ///      the cap. Splitting into 4a (DGF + DelayedWETH) and 4b (ASR +
    ///      games) keeps both substages well under.
    uint8 public phase;

    /// @notice True when the active session is an initial deployment (gates
    ///         terminal ownership transfers in step5). False on upgrades.
    bool public isInitialDeployment;

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// @param _utils    OPContractsManagerUtils — same instance the deployed
    ///                  OPCMv2 references.
    /// @param _container OPContractsManagerContainer — same instance the
    ///                  deployed OPCMv2 references. Holds the shared
    ///                  Implementations + Blueprints arrays.
    /// @param _validator Standard validator (forwarded; not invoked here).
    /// @param _migrator OPCMMigrator (delegatecalled by `migrate`).
    constructor(
        IOPContractsManagerUtils _utils,
        IOPContractsManagerContainer _container,
        IOPContractsManagerStandardValidator _validator,
        IOPContractsManagerMigrator _migrator
    )
        OPContractsManagerUtilsCaller(_utils)
    {
        container = _container;
        deployer = msg.sender;
        opcmStandardValidator = _validator;
        opcmMigrator = _migrator;
    }

    // -----------------------------------------------------------------------
    // Read-throughs to the container.
    //
    // OPContractsManagerUtilsCaller's helpers reach into `implementations()`
    // and `blueprints()` via local function calls, so we override the names
    // exposed by upstream OPCMv2 here. (The caller uses `implementations()`
    // and `blueprints()` from within `_loadOrDeployProxy` body that runs in
    // *this* contract's context after delegatecall — see the `containedRead`
    // pattern in OPContractsManagerUtils itself.)
    // -----------------------------------------------------------------------
    function blueprints() public view returns (IOPContractsManagerContainer.Blueprints memory) {
        return container.blueprints();
    }

    function implementations() public view returns (IOPContractsManagerContainer.Implementations memory) {
        return container.implementations();
    }

    function contractsContainer() public view returns (IOPContractsManagerContainer) {
        return container;
    }

    function isDevFeatureEnabled(bytes32 _feature) public view returns (bool) {
        return container.isDevFeatureEnabled(_feature);
    }

    function devFeatureBitmap() public view returns (bytes32) {
        return container.devFeatureBitmap();
    }

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------
    modifier onlyDeployer() {
        _checkDeployer();
        _;
    }

    /// @dev Extracted modifier body — saves bytecode at every call site.
    function _checkDeployer() internal view {
        if (msg.sender != deployer) revert RSKOPCMSplitter_NotDeployer();
        if (phase == 255) revert RSKOPCMSplitter_AlreadySealed();
    }

    // =======================================================================
    // INITIAL DEPLOY — split version of OPCMv2.deploy(FullConfig)
    //
    // Stages collectively reproduce OPCMv2.deploy() line-for-line. Line
    // numbers refer to OPContractsManagerV2.sol at op-node/v1.19.9:
    //   step1a = _loadChainContracts, ProxyAdmin..ETHLockbox proxies
    //                                                 (upstream lines 403-471)
    //   step1b = _loadChainContracts, LCDM..DelayedWETH proxies
    //                                                 (upstream lines 474-549)
    //   step2  = _apply, prelude + SystemConfig + Portal + ETHLockbox +
    //            liquidity migration                  (lines 818-904)
    //   step3  = _apply, LCDM + bridges + factory     (lines 906-939)
    //   step4a = _apply, DGF + DelayedWETH            (lines 941-955)
    //   step4b = _apply, ASR + dispute games + SUPER_CANNON clear + CGT
    //                                                 (lines 957-1018)
    //   step5  = _apply, terminal ownership transfers (lines 1019-1032)
    //
    // Stages 1 and 4 are each split to keep every tx under RSKj's RSKIP144
    // 6.8M per-tx sublist gas cap; the unsplit forms land at ~7.6M and
    // ~7.2M raw respectively (well over cap once forge applies its 110%
    // padding).
    // =======================================================================

    /// @notice Deploy stage 1a: deploy the *core* proxies (ProxyAdmin,
    ///         AddressManager, SystemConfig, OptimismPortal, ETHLockbox).
    ///         Mirror of `OPCMv2._loadChainContracts` upstream lines
    ///         403-471 (initial-deployment branch).
    function deployStep1a_coreProxies(FullConfig memory _cfg)
        external
        onlyDeployer
        returns (ChainContractsCore memory core)
    {
        if (phase != 0) revert RSKOPCMSplitter_AlreadyStarted();
        isInitialDeployment = true;

        // Mirror OPCMv2.deploy lines 207-220 (saltMixer + ALL-permit).
        string memory saltMixer = string(bytes.concat(bytes20(deployer), bytes(_cfg.saltMixer)));
        IOPContractsManagerUtils.ExtraInstruction[] memory instructions =
            new IOPContractsManagerUtils.ExtraInstruction[](1);
        instructions[0] = IOPContractsManagerUtils.ExtraInstruction({
            key: Constants.PERMITTED_PROXY_DEPLOYMENT_KEY,
            data: Constants.PERMIT_ALL_CONTRACTS_INSTRUCTION
        });

        core = _loadCoreProxies(_cfg.l2ChainId, saltMixer, instructions);
        phase = 1;
        return core;
    }

    /// @notice Deploy stage 1b: deploy the remaining proxies (LCDM,
    ///         L1ERC721Bridge, L1StandardBridge, OptimismMintableERC20Factory,
    ///         DisputeGameFactory, AnchorStateRegistry, DelayedWETH).
    ///         Mirror of `OPCMv2._loadChainContracts` upstream lines
    ///         474-549. Returns the combined `ChainContracts` struct.
    function deployStep1b_remainingProxies(FullConfig memory _cfg, ChainContractsCore memory _core)
        external
        onlyDeployer
        returns (ChainContracts memory cts)
    {
        if (phase != 1) revert RSKOPCMSplitter_NotStarted();

        // Re-derive saltMixer + ALL-permit just like step1a, so the same
        // CREATE2 addresses computed during step1a continue to be honoured
        // here.
        string memory saltMixer = string(bytes.concat(bytes20(deployer), bytes(_cfg.saltMixer)));
        IOPContractsManagerUtils.ExtraInstruction[] memory instructions =
            new IOPContractsManagerUtils.ExtraInstruction[](1);
        instructions[0] = IOPContractsManagerUtils.ExtraInstruction({
            key: Constants.PERMITTED_PROXY_DEPLOYMENT_KEY,
            data: Constants.PERMIT_ALL_CONTRACTS_INSTRUCTION
        });

        cts = _loadRemainingProxies(_core, _cfg.l2ChainId, saltMixer, instructions);
        phase = 2;
        return cts;
    }

    // NOTE: `upgradeStep1_loadExisting`, `migrate`, the `_loadProxies` upgrade
    // helper, and `_loadFullConfigForUpgrade` were moved out of this contract
    // to fit under EIP-170's 24,576-byte runtime cap once stage 1 was split
    // into 1a/1b. They will be re-added in a sibling `RSKOPCMSplitterUpgrade`
    // contract (deployed from the same out-of-tree package) when the first
    // upgrade or migrate scenario is exercised on RSK. The existing splitter
    // logic for steps 2-5 is shared between both flows, so factoring out
    // is a mechanical lift.
    //
    // Tracked as F1.1 in RSK_COMPATIBILITY_BLOCKERS.md.

    /// @notice Stage 2: SystemConfig + Portal + ETHLockbox + liquidity
    ///         migration. Mirror of `OPCMv2._apply` lines 818-904.
    function step2_systemConfigAndPortal(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 2) revert RSKOPCMSplitter_NotStarted();

        // Lines 818-819
        _assertValidFullConfig(_cfg, isInitialDeployment);

        // Lines 821-822
        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 824-827
        if (SemverComp.lt(_cfg.superchainConfig.version(), ISuperchainConfig(impls.superchainConfigImpl).version())) {
            revert RSKOPCMSplitter_SuperchainConfigNeedsUpgrade();
        }

        // Lines 829-836 — the upgrade-sequence check only runs on upgrades,
        // and this splitter only supports initial deployments (see the note
        // above this stage).

        // Lines 838-865 — SystemConfig. `opcm` is the splitter: the chain is
        // deployed by it rather than by an OPCMv2 instance, and SystemConfig
        // stores it as the OPCM that last managed the chain.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.systemConfig),
            impls.systemConfigImpl,
            _encodeSystemConfigInit(
                SystemConfigInitArgs({
                    owner: _cfg.systemConfigOwner,
                    basefeeScalar: _cfg.basefeeScalar,
                    blobbasefeeScalar: _cfg.blobBasefeeScalar,
                    batcherHash: bytes32(uint256(uint160(_cfg.batcher))),
                    gasLimit: _cfg.gasLimit,
                    unsafeBlockSigner: _cfg.unsafeBlockSigner,
                    resourceConfig: _cfg.resourceConfig,
                    addrs: ISystemConfig.Addresses({
                        l1CrossDomainMessenger: address(_cts.l1CrossDomainMessenger),
                        l1ERC721Bridge: address(_cts.l1ERC721Bridge),
                        l1StandardBridge: address(_cts.l1StandardBridge),
                        optimismPortal: address(_cts.optimismPortal),
                        optimismMintableERC20Factory: address(_cts.optimismMintableERC20Factory),
                        delayedWETH: address(_cts.delayedWETH),
                        opcm: address(this)
                    }),
                    l2ChainId: _cfg.l2ChainId,
                    superchainConfig: _cfg.superchainConfig
                })
            )
        );

        // Lines 867-878 — enable ETHLockbox before updating the portal.
        bool wasEthLockboxEnabled = _cts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX);
        bool wasUsingEthLockbox = !isInitialDeployment && wasEthLockboxEnabled
            && address(_cts.optimismPortal.ethLockbox()) != address(0);
        if (address(_cts.ethLockbox) == address(0)) {
            revert RSKOPCMSplitter_InvalidEthLockbox();
        }
        if (!wasEthLockboxEnabled) {
            _cts.systemConfig.setFeature(Features.ETH_LOCKBOX, true);
        }

        // Lines 880-886 — OptimismPortal.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.optimismPortal),
            impls.optimismPortalImpl,
            abi.encodeCall(IOptimismPortal.initialize, (_cts.systemConfig, _cts.anchorStateRegistry, _cts.ethLockbox))
        );

        // Lines 891-899 — ETHLockbox.
        IOptimismPortal[] memory portals = new IOptimismPortal[](1);
        portals[0] = _cts.optimismPortal;
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.ethLockbox),
            impls.ethLockboxImpl,
            abi.encodeCall(IETHLockbox.initialize, (_cts.systemConfig.superchainConfig(), portals))
        );

        // Lines 901-904 — custom gas token chains keep custody in the portal.
        if (!wasUsingEthLockbox && !_cfg.useCustomGasToken) {
            _cts.optimismPortal.migrateLiquidity();
        }

        phase = 3;
    }

    /// @notice Stage 3: LCDM + bridges + OptimismMintableERC20Factory. Mirror
    ///         of `OPCMv2._apply` lines 906-939.
    function step3_messengerAndBridges(FullConfig memory /* _cfg */, ChainContracts memory _cts)
        external
        onlyDeployer
    {
        if (phase != 3) revert RSKOPCMSplitter_NotStarted();

        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 906-915 — L1CrossDomainMessenger (slot 0, offset 20).
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1CrossDomainMessenger),
            impls.l1CrossDomainMessengerImpl,
            abi.encodeCall(IL1CrossDomainMessenger.initialize, (_cts.systemConfig, _cts.optimismPortal)),
            bytes32(0),
            20
        );

        // Lines 917-923 — L1StandardBridge.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1StandardBridge),
            impls.l1StandardBridgeImpl,
            abi.encodeCall(IL1StandardBridge.initialize, (_cts.l1CrossDomainMessenger, _cts.systemConfig))
        );

        // Lines 925-931 — L1ERC721Bridge.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1ERC721Bridge),
            impls.l1ERC721BridgeImpl,
            abi.encodeCall(IL1ERC721Bridge.initialize, (_cts.l1CrossDomainMessenger, _cts.systemConfig))
        );

        // Lines 933-939 — OptimismMintableERC20Factory.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.optimismMintableERC20Factory),
            impls.optimismMintableERC20FactoryImpl,
            abi.encodeCall(IOptimismMintableERC20Factory.initialize, (address(_cts.l1StandardBridge)))
        );

        phase = 4;
    }

    /// @notice Stage 4a: DisputeGameFactory + DelayedWETH. Mirror of
    ///         `OPCMv2._apply` lines 941-955 — first half of stage 4.
    function step4a_disputeFactoryAndWeth(FullConfig memory /* _cfg */, ChainContracts memory _cts)
        external
        onlyDeployer
    {
        if (phase != 4) revert RSKOPCMSplitter_NotStarted();

        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 941-947 — DisputeGameFactory.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.disputeGameFactory),
            impls.disputeGameFactoryImpl,
            abi.encodeCall(IDisputeGameFactory.initialize, (address(this)))
        );

        // Lines 949-955 — DelayedWETH.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.delayedWETH),
            impls.delayedWETHImpl,
            abi.encodeCall(IDelayedWETH.initialize, (_cts.ethLockbox))
        );

        phase = 5;
    }

    /// @notice Stage 4b: AnchorStateRegistry + dispute-game config loop +
    ///         SUPER_CANNON clear + custom gas token branch. Mirror of
    ///         `OPCMv2._apply` lines 957-1018 — second half of stage 4.
    function step4b_anchorAndGames(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 5) revert RSKOPCMSplitter_NotStarted();

        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 957-966 — AnchorStateRegistry.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.anchorStateRegistry),
            impls.anchorStateRegistryImpl,
            abi.encodeCall(
                IAnchorStateRegistry.initialize,
                (_cts.ethLockbox, _cts.disputeGameFactory, _cfg.startingAnchorRoot, _cfg.startingRespectedGameType)
            )
        );

        // Lines 968-995 — dispute games loop.
        for (uint256 i = 0; i < _cfg.disputeGameConfigs.length; i++) {
            IDisputeGame gameImpl = IDisputeGame(address(0));
            bytes memory gameArgs = bytes("");

            if (_cfg.disputeGameConfigs[i].enabled) {
                gameImpl = _getGameImpl(_cfg.disputeGameConfigs[i].gameType);
                if (address(gameImpl) == address(0) || address(gameImpl).code.length == 0) {
                    revert RSKOPCMSplitter_ZeroGameImplementation(_cfg.disputeGameConfigs[i].gameType);
                }
                gameArgs = _makeGameArgs(
                    _cfg.l2ChainId, _cts.anchorStateRegistry, _cts.delayedWETH, _cfg.disputeGameConfigs[i]
                );
            }

            _cts.disputeGameFactory.setImplementation(_cfg.disputeGameConfigs[i].gameType, gameImpl, gameArgs);
            _cts.disputeGameFactory.setInitBond(
                _cfg.disputeGameConfigs[i].gameType, _cfg.disputeGameConfigs[i].initBond
            );
        }

        // Lines 997-1005 — SUPER_CANNON is retired from the allow-list; clear
        // it unconditionally (a no-op state-wise on initial deployment).
        _cts.disputeGameFactory.setImplementation(GameTypes.SUPER_CANNON, IDisputeGame(address(0)), hex"");
        _cts.disputeGameFactory.setInitBond(GameTypes.SUPER_CANNON, 0);

        // Lines 1006-1018 — custom gas token (conditional, initial-deploy only).
        if (_cfg.useCustomGasToken && !_cts.systemConfig.isCustomGasToken()) {
            if (!isInitialDeployment) {
                revert RSKOPCMSplitter_CannotUpgradeToCustomGasToken();
            }
            _cts.systemConfig.setFeature(Features.CUSTOM_GAS_TOKEN, true);
        }

        phase = 6;
    }

    /// @notice Stage 5: terminal ownership transfers (initial deploy only).
    ///         Mirror of `OPCMv2._apply` lines 1019-1032. Seals the splitter.
    function step5_finalize(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 6) revert RSKOPCMSplitter_NotStarted();

        // Lines 1019-1032. On upgrade we skip the terminal transfers entirely
        // (matches upstream's `if (_isInitialDeployment) { ... }`).
        if (isInitialDeployment) {
            _cts.disputeGameFactory.transferOwnership(_cfg.proxyAdminOwner);
            _cts.proxyAdmin.transferOwnership(_cfg.proxyAdminOwner);
        }

        phase = 255; // seal
    }

    // =======================================================================
    // MIGRATE — moved to RSKOPCMSplitterUpgrade (see note above stage 2). The
    // migrator immutable is still wired through the constructor so the future
    // sibling contract can read it from a deployed splitter if needed.
    // =======================================================================

    // =======================================================================
    // PRIVATE HELPERS — only `_loadProxies`, `_loadFullConfigForUpgrade` and
    // `_assertValidFullConfig` need to be local. Everything else
    // (`_upgrade`, `_loadOrDeployProxy`, `_encodeSystemConfigInit`, etc.) is
    // inherited from OPContractsManagerUtilsCaller.
    // =======================================================================

    // _loadProxies (upgrade path) was here — moved to the upcoming sibling
    // RSKOPCMSplitterUpgrade contract (see note above stage 2). Until that
    // contract lands, only initial-deployment loads via _loadCoreProxies +
    // _loadRemainingProxies are supported.
    /*
    function _loadProxies(
        ISystemConfig _systemConfig,
        uint256 _l2ChainId,
        string memory _saltMixer,
        IOPContractsManagerUtils.ExtraInstruction[] memory _extraInstructions
    )
        internal
        returns (ChainContracts memory)
    {
        IProxyAdmin proxyAdmin = _systemConfig.proxyAdmin();
        IAddressManager addressManager = proxyAdmin.addressManager();
        ISystemConfig systemConfig = _systemConfig;

        IOPContractsManagerUtils.ProxyDeployArgs memory proxyDeployArgs = IOPContractsManagerUtils.ProxyDeployArgs({
            proxyAdmin: proxyAdmin,
            addressManager: addressManager,
            l2ChainId: _l2ChainId,
            saltMixer: _saltMixer
        });

        IOptimismPortal optimismPortal = IOptimismPortal(
            _loadOrDeployProxy(
                address(systemConfig),
                systemConfig.optimismPortal.selector,
                proxyDeployArgs,
                "OptimismPortal",
                _extraInstructions
            )
        );

        IETHLockbox ethLockbox;
        if (systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX)) {
            ethLockbox = IETHLockbox(
                _loadOrDeployProxy(
                    address(optimismPortal),
                    optimismPortal.ethLockbox.selector,
                    proxyDeployArgs,
                    "ETHLockbox",
                    _extraInstructions
                )
            );
        }

        return ChainContracts({
            systemConfig: systemConfig,
            proxyAdmin: proxyAdmin,
            addressManager: addressManager,
            optimismPortal: optimismPortal,
            ethLockbox: ethLockbox,
            l1CrossDomainMessenger: IL1CrossDomainMessenger(
                _loadOrDeployProxy(
                    address(systemConfig),
                    systemConfig.l1CrossDomainMessenger.selector,
                    proxyDeployArgs,
                    "L1CrossDomainMessenger",
                    _extraInstructions
                )
            ),
            l1ERC721Bridge: IL1ERC721Bridge(
                _loadOrDeployProxy(
                    address(systemConfig),
                    systemConfig.l1ERC721Bridge.selector,
                    proxyDeployArgs,
                    "L1ERC721Bridge",
                    _extraInstructions
                )
            ),
            l1StandardBridge: IL1StandardBridge(
                _loadOrDeployProxy(
                    address(systemConfig),
                    systemConfig.l1StandardBridge.selector,
                    proxyDeployArgs,
                    "L1StandardBridge",
                    _extraInstructions
                )
            ),
            optimismMintableERC20Factory: IOptimismMintableERC20Factory(
                _loadOrDeployProxy(
                    address(systemConfig),
                    systemConfig.optimismMintableERC20Factory.selector,
                    proxyDeployArgs,
                    "OptimismMintableERC20Factory",
                    _extraInstructions
                )
            ),
            disputeGameFactory: IDisputeGameFactory(
                _loadOrDeployProxy(
                    address(systemConfig),
                    systemConfig.disputeGameFactory.selector,
                    proxyDeployArgs,
                    "DisputeGameFactory",
                    _extraInstructions
                )
            ),
            anchorStateRegistry: IAnchorStateRegistry(
                _loadOrDeployProxy(
                    address(optimismPortal),
                    optimismPortal.anchorStateRegistry.selector,
                    proxyDeployArgs,
                    "AnchorStateRegistry",
                    _extraInstructions
                )
            ),
            delayedWETH: IDelayedWETH(
                _loadOrDeployProxy(
                    address(systemConfig),
                    systemConfig.delayedWETH.selector,
                    proxyDeployArgs,
                    "DelayedWETH",
                    _extraInstructions
                )
            )
        });
    }
    */

    /// @dev Initial-deploy proxy loader, first half. Deploys ProxyAdmin,
    ///      AddressManager, SystemConfig proxy, OptimismPortal proxy, and
    ///      ETHLockbox proxy. Mirror of `OPCMv2._loadChainContracts` upstream
    ///      lines 403-471 (initial-deployment branch).
    function _loadCoreProxies(
        uint256 _l2ChainId,
        string memory _saltMixer,
        IOPContractsManagerUtils.ExtraInstruction[] memory _extraInstructions
    )
        internal
        returns (ChainContractsCore memory core)
    {
        IProxyAdmin proxyAdmin = IProxyAdmin(
            Blueprint.deployFrom(
                blueprints().proxyAdmin,
                _computeSalt(_l2ChainId, _saltMixer, "ProxyAdmin"),
                abi.encode(address(this))
            )
        );

        IAddressManager addressManager = IAddressManager(
            Blueprint.deployFrom(
                blueprints().addressManager, _computeSalt(_l2ChainId, _saltMixer, "AddressManager"), abi.encode()
            )
        );

        proxyAdmin.setAddressManager(addressManager);
        addressManager.transferOwnership(address(proxyAdmin));

        ISystemConfig systemConfig = ISystemConfig(
            Blueprint.deployFrom(
                blueprints().proxy,
                _computeSalt(_l2ChainId, _saltMixer, "SystemConfig"),
                abi.encode(address(proxyAdmin))
            )
        );

        IOPContractsManagerUtils.ProxyDeployArgs memory proxyDeployArgs = IOPContractsManagerUtils.ProxyDeployArgs({
            proxyAdmin: proxyAdmin,
            addressManager: addressManager,
            l2ChainId: _l2ChainId,
            saltMixer: _saltMixer
        });

        IOptimismPortal optimismPortal = IOptimismPortal(
            _loadOrDeployProxy(
                address(systemConfig),
                systemConfig.optimismPortal.selector,
                proxyDeployArgs,
                "OptimismPortal",
                _extraInstructions
            )
        );

        // Lines 463-471 — load or deploy the ETHLockbox.
        IETHLockbox ethLockbox = IETHLockbox(
            _loadOrDeployProxy(
                address(optimismPortal),
                optimismPortal.ethLockbox.selector,
                proxyDeployArgs,
                "ETHLockbox",
                _extraInstructions
            )
        );

        core = ChainContractsCore({
            proxyAdmin: proxyAdmin,
            addressManager: addressManager,
            systemConfig: systemConfig,
            optimismPortal: optimismPortal,
            ethLockbox: ethLockbox
        });
    }

    /// @dev Initial-deploy proxy loader, second half. Deploys
    ///      L1CrossDomainMessenger, L1ERC721Bridge, L1StandardBridge,
    ///      OptimismMintableERC20Factory, DisputeGameFactory,
    ///      AnchorStateRegistry, DelayedWETH proxies. Mirror of
    ///      `OPCMv2._loadChainContracts` upstream lines 474-549.
    function _loadRemainingProxies(
        ChainContractsCore memory _core,
        uint256 _l2ChainId,
        string memory _saltMixer,
        IOPContractsManagerUtils.ExtraInstruction[] memory _extraInstructions
    )
        internal
        returns (ChainContracts memory)
    {
        IOPContractsManagerUtils.ProxyDeployArgs memory proxyDeployArgs = IOPContractsManagerUtils.ProxyDeployArgs({
            proxyAdmin: _core.proxyAdmin,
            addressManager: _core.addressManager,
            l2ChainId: _l2ChainId,
            saltMixer: _saltMixer
        });

        return ChainContracts({
            systemConfig: _core.systemConfig,
            proxyAdmin: _core.proxyAdmin,
            addressManager: _core.addressManager,
            optimismPortal: _core.optimismPortal,
            ethLockbox: _core.ethLockbox,
            l1CrossDomainMessenger: IL1CrossDomainMessenger(
                _loadOrDeployProxy(
                    address(_core.systemConfig),
                    _core.systemConfig.l1CrossDomainMessenger.selector,
                    proxyDeployArgs,
                    "L1CrossDomainMessenger",
                    _extraInstructions
                )
            ),
            l1ERC721Bridge: IL1ERC721Bridge(
                _loadOrDeployProxy(
                    address(_core.systemConfig),
                    _core.systemConfig.l1ERC721Bridge.selector,
                    proxyDeployArgs,
                    "L1ERC721Bridge",
                    _extraInstructions
                )
            ),
            l1StandardBridge: IL1StandardBridge(
                _loadOrDeployProxy(
                    address(_core.systemConfig),
                    _core.systemConfig.l1StandardBridge.selector,
                    proxyDeployArgs,
                    "L1StandardBridge",
                    _extraInstructions
                )
            ),
            optimismMintableERC20Factory: IOptimismMintableERC20Factory(
                _loadOrDeployProxy(
                    address(_core.systemConfig),
                    _core.systemConfig.optimismMintableERC20Factory.selector,
                    proxyDeployArgs,
                    "OptimismMintableERC20Factory",
                    _extraInstructions
                )
            ),
            disputeGameFactory: IDisputeGameFactory(
                _loadOrDeployProxy(
                    address(_core.systemConfig),
                    _core.systemConfig.disputeGameFactory.selector,
                    proxyDeployArgs,
                    "DisputeGameFactory",
                    _extraInstructions
                )
            ),
            anchorStateRegistry: IAnchorStateRegistry(
                _loadOrDeployProxy(
                    address(_core.optimismPortal),
                    _core.optimismPortal.anchorStateRegistry.selector,
                    proxyDeployArgs,
                    "AnchorStateRegistry",
                    _extraInstructions
                )
            ),
            delayedWETH: IDelayedWETH(
                _loadOrDeployProxy(
                    address(_core.systemConfig),
                    _core.systemConfig.delayedWETH.selector,
                    proxyDeployArgs,
                    "DelayedWETH",
                    _extraInstructions
                )
            )
        });
    }

    // _loadFullConfigForUpgrade was here — moved with the rest of the
    // upgrade path to the upcoming sibling RSKOPCMSplitterUpgrade contract.
    /*
    function _loadFullConfigForUpgrade(UpgradeInput memory _inp, ChainContracts memory _cts)
        internal
        view
        returns (FullConfig memory)
    {
        return FullConfig({
            disputeGameConfigs: _inp.disputeGameConfigs,
            saltMixer: string(bytes.concat(bytes32(uint256(uint160(address(_cts.systemConfig)))))),
            superchainConfig: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.superchainConfig.selector,
                    "overrides.cfg.superchainConfig",
                    _inp.extraInstructions
                ),
                (ISuperchainConfig)
            ),
            proxyAdminOwner: abi.decode(
                _loadBytes(
                    address(_cts.proxyAdmin),
                    IProxyAdmin.owner.selector,
                    "overrides.cfg.proxyAdminOwner",
                    _inp.extraInstructions
                ),
                (address)
            ),
            systemConfigOwner: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.owner.selector,
                    "overrides.cfg.systemConfigOwner",
                    _inp.extraInstructions
                ),
                (address)
            ),
            unsafeBlockSigner: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.unsafeBlockSigner.selector,
                    "overrides.cfg.unsafeBlockSigner",
                    _inp.extraInstructions
                ),
                (address)
            ),
            batcher: address(
                uint160(
                    uint256(
                        abi.decode(
                            _loadBytes(
                                address(_cts.systemConfig),
                                _cts.systemConfig.batcherHash.selector,
                                "overrides.cfg.batcher",
                                _inp.extraInstructions
                            ),
                            (bytes32)
                        )
                    )
                )
            ),
            startingAnchorRoot: abi.decode(
                _loadBytes(
                    address(_cts.anchorStateRegistry),
                    _cts.anchorStateRegistry.getAnchorRoot.selector,
                    "overrides.cfg.startingAnchorRoot",
                    _inp.extraInstructions
                ),
                (Proposal)
            ),
            startingRespectedGameType: abi.decode(
                _loadBytes(
                    address(_cts.optimismPortal),
                    _cts.optimismPortal.respectedGameType.selector,
                    "overrides.cfg.startingRespectedGameType",
                    _inp.extraInstructions
                ),
                (GameType)
            ),
            basefeeScalar: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.basefeeScalar.selector,
                    "overrides.cfg.basefeeScalar",
                    _inp.extraInstructions
                ),
                (uint32)
            ),
            blobBasefeeScalar: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.blobbasefeeScalar.selector,
                    "overrides.cfg.blobBasefeeScalar",
                    _inp.extraInstructions
                ),
                (uint32)
            ),
            gasLimit: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.gasLimit.selector,
                    "overrides.cfg.gasLimit",
                    _inp.extraInstructions
                ),
                (uint64)
            ),
            l2ChainId: _cts.systemConfig.l2ChainId(),
            resourceConfig: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.resourceConfig.selector,
                    "overrides.cfg.resourceConfig",
                    _inp.extraInstructions
                ),
                (IResourceMetering.ResourceConfig)
            ),
            useCustomGasToken: abi.decode(
                _loadBytes(
                    address(_cts.systemConfig),
                    _cts.systemConfig.isCustomGasToken.selector,
                    "overrides.cfg.useCustomGasToken",
                    _inp.extraInstructions
                ),
                (bool)
            )
        });
    }
    */

    /// @dev Port of `OPCMv2._assertValidFullConfig` (upstream lines 691-803).
    ///      Two RSK divergences, both marked inline and both about
    ///      PERMISSIONED_CANNON: it is valid in an initial deployment despite the
    ///      super-root flag, and it may carry a zero init bond (PAYROLLUP-191).
    function _assertValidFullConfig(FullConfig memory _cfg, bool _isInitialDeployment) internal view {
        if (_cfg.disputeGameConfigs.length != VALID_GAME_TYPE_COUNT) {
            revert RSKOPCMSplitter_InvalidGameConfigs();
        }

        // An initial anchor must have a nonzero root and leave room for a uint64 successor.
        if (
            _isInitialDeployment
                && (
                    _cfg.startingAnchorRoot.root.raw() == bytes32(0)
                        || _cfg.startingAnchorRoot.l2SequenceNumber >= type(uint64).max
                )
        ) {
            revert RSKOPCMSplitter_InvalidGameConfigs();
        }

        bool superRootGamesMigrationEnabled = isDevFeatureEnabled(DevFeatures.SUPER_ROOT_GAMES_MIGRATION);

        for (uint256 i = 0; i < _cfg.disputeGameConfigs.length; i++) {
            uint32 rawGameType = uint32(VALID_GAME_TYPES >> (i * 32));
            bool isCannonGame = rawGameType == GameTypes.CANNON.raw();
            bool isPermissionedCannonGame = rawGameType == GameTypes.PERMISSIONED_CANNON.raw();
            bool isCannonKonaGame = rawGameType == GameTypes.CANNON_KONA.raw();
            bool isSuperPermissionedGame = rawGameType == GameTypes.SUPER_PERMISSIONED.raw();
            bool isSuperCannonKonaGame = rawGameType == GameTypes.SUPER_CANNON_KONA.raw();
            bool isZkDisputeGame = rawGameType == GameTypes.ZK_DISPUTE_GAME.raw();

            if (_cfg.disputeGameConfigs[i].gameType.raw() != rawGameType) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }

            if (!_cfg.disputeGameConfigs[i].enabled && _cfg.disputeGameConfigs[i].initBond != 0) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }

            if (isSuperPermissionedGame && _cfg.disputeGameConfigs[i].initBond != 0) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }

            // An enabled game needs a non-zero init bond. Upstream exempts only
            // SUPER_PERMISSIONED. RSK divergence: PERMISSIONED_CANNON is exempt too,
            // because only the proposer can create those games and the bond would
            // only park its capital (PAYROLLUP-191).
            if (
                !isSuperPermissionedGame && !isPermissionedCannonGame && _cfg.disputeGameConfigs[i].enabled
                    && _cfg.disputeGameConfigs[i].initBond == 0
            ) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }

            // RSK divergence: upstream lets an initial deployment enable only the
            // super-root games while SUPER_ROOT_GAMES_MIGRATION is on, and
            // op-contracts v9 hard-wires that flag on (DevFeatures). RSK runs one L2
            // per L1 with no interop, so it keeps deploying PERMISSIONED_CANNON, the
            // output-root game OptimismPortal2 still proves withdrawals against.
            bool validForInitialDeploy = isPermissionedCannonGame
                || (
                    superRootGamesMigrationEnabled
                        ? (isSuperPermissionedGame || isSuperCannonKonaGame)
                        : isCannonKonaGame
                );
            if (_isInitialDeployment && _cfg.disputeGameConfigs[i].enabled && !validForInitialDeploy) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }

            if (
                isZkDisputeGame && _cfg.disputeGameConfigs[i].enabled
                    && !isDevFeatureEnabled(DevFeatures.ZK_DISPUTE_GAME)
            ) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }

            if (_cfg.disputeGameConfigs[i].enabled && (isCannonGame || isCannonKonaGame || isSuperCannonKonaGame)) {
                if (
                    _isInitialDeployment
                        && _cfg.startingAnchorRoot.root.raw() == Constants.PLACEHOLDER_STARTING_ANCHOR_ROOT
                ) {
                    revert RSKOPCMSplitter_InvalidGameConfigs();
                }

                IOPContractsManagerUtils.FaultDisputeGameConfig memory faultGameConfig =
                    abi.decode(_cfg.disputeGameConfigs[i].gameArgs, (IOPContractsManagerUtils.FaultDisputeGameConfig));
                if (faultGameConfig.absolutePrestate.raw() == bytes32(0)) {
                    revert RSKOPCMSplitter_InvalidGameConfigs();
                }
            }

            if (_cfg.disputeGameConfigs[i].enabled && isZkDisputeGame) {
                IOPContractsManagerUtils.ZKDisputeGameConfig memory zkGameConfig =
                    abi.decode(_cfg.disputeGameConfigs[i].gameArgs, (IOPContractsManagerUtils.ZKDisputeGameConfig));
                if (zkGameConfig.absolutePrestate.raw() == bytes32(0)) {
                    revert RSKOPCMSplitter_InvalidGameConfigs();
                }
            }
        }

        bool startingGameTypeFound = false;
        for (uint256 i = 0; i < _cfg.disputeGameConfigs.length; i++) {
            if (
                _cfg.disputeGameConfigs[i].gameType.raw() == _cfg.startingRespectedGameType.raw()
                    && _cfg.disputeGameConfigs[i].enabled
            ) {
                startingGameTypeFound = true;
                break;
            }
        }
        if (!startingGameTypeFound) {
            revert RSKOPCMSplitter_InvalidGameConfigs();
        }
    }
}
