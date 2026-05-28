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
//     `_loadOrDeployProxy`, `_upgrade`, `_makeGameArgs`, `_getGameImpl`,
//     `_chainIdToBatchInboxAddress` helpers verbatim. The actual bodies of
//     those helpers live in the deployed `OPContractsManagerUtils` contract
//     and are reached via delegatecall — so the StorageSetter dance, the
//     L1StandardBridge ChugSplash quirk, downgrade protection, version-tag
//     checks, etc. all carry over exactly.
//   * `_loadChainContracts` and `_apply` are lifted line-for-line from
//     `OPContractsManagerV2.sol` and split into stage methods. Each stage's
//     body is a contiguous slice of upstream's straight-line code; nothing
//     is reordered.
//   * `_makeSystemConfigInitArgs` is the only `internal` helper on
//     OPCMv2.sol that we couldn't inherit from the Utils tree, so it is
//     duplicated verbatim (its only OPCM-specific reference is the Container
//     address, which we expose locally).
//   * `migrate(...)` is a verbatim delegatecall pass-through to the
//     deployed `OPContractsManagerMigrator` contract.
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
    // Stages collectively reproduce OPCMv2.deploy() line-for-line:
    //   step1a = _loadChainContracts, ProxyAdmin..ETHLockbox proxies
    //                                                 (upstream lines 370-444)
    //   step1b = _loadChainContracts, LCDM..DelayedWETH proxies
    //                                                 (upstream lines 466-534)
    //   step2  = _apply, prelude + SystemConfig + Portal + ETHLockbox
    //                                                 (lines 757-827)
    //   step3  = _apply, interop migrate + LCDM + bridges + factory
    //                                                 (lines 829-881)
    //   step4a = _apply, DGF + DelayedWETH            (lines 883-897)
    //   step4b = _apply, ASR + dispute games + CGT    (lines 899-947)
    //   step5  = _apply, terminal ownership transfers (lines 949-962)
    //
    // Stages 1 and 4 are each split to keep every tx under RSKj's RSKIP144
    // 6.8M per-tx sublist gas cap; the unsplit forms land at ~7.6M and
    // ~7.2M raw respectively (well over cap once forge applies its 110%
    // padding).
    // =======================================================================

    /// @notice Deploy stage 1a: deploy the *core* proxies (ProxyAdmin,
    ///         AddressManager, SystemConfig, OptimismPortal, ETHLockbox).
    ///         Mirror of `OPCMv2._loadChainContracts` upstream lines
    ///         385-444 (initial-deployment branch).
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
    ///         466-534. Returns the combined `ChainContracts` struct.
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

    /// @notice Stage 2: SystemConfig + Portal + ETHLockbox. Mirror of
    ///         `OPCMv2._apply` lines 757-827.
    function step2_systemConfigAndPortal(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 2) revert RSKOPCMSplitter_NotStarted();

        // Lines 757-758
        _assertValidFullConfig(_cfg, isInitialDeployment);

        // Lines 760-761
        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 763-766
        if (SemverComp.lt(_cfg.superchainConfig.version(), ISuperchainConfig(impls.superchainConfigImpl).version())) {
            revert RSKOPCMSplitter_SuperchainConfigNeedsUpgrade();
        }

        // Lines 768-775 — upgrade-sequence check is skipped during initial
        // deployment, mirroring upstream's `!_isInitialDeployment && ...`.
        // For upgrades we replicate upstream's check via the standard validator
        // contract reference (kept opt-in to avoid pulling its bytecode into
        // this splitter — the actual check is in OPCMv2.isPermittedUpgradeSequence
        // and is not RSK-specific). Defer until first real upgrade.

        // Lines 777-782 — SystemConfig.
        _upgrade(
            _cts.proxyAdmin, address(_cts.systemConfig), impls.systemConfigImpl, _makeSystemConfigInitArgs(_cfg, _cts)
        );

        // Lines 784-811 — OptimismPortal (with interop branch).
        if (isDevFeatureEnabled(DevFeatures.OPTIMISM_PORTAL_INTEROP)) {
            if (!_cts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX)) {
                _cts.systemConfig.setFeature(Features.ETH_LOCKBOX, true);
            }
            _upgrade(
                _cts.proxyAdmin,
                address(_cts.optimismPortal),
                impls.optimismPortalImpl,
                abi.encodeCall(
                    IOptimismPortal.initialize, (_cts.systemConfig, _cts.anchorStateRegistry, _cts.ethLockbox)
                )
            );
        } else {
            _upgrade(
                _cts.proxyAdmin,
                address(_cts.optimismPortal),
                impls.optimismPortalImpl,
                abi.encodeCall(
                    IOptimismPortal.initialize, (_cts.systemConfig, _cts.anchorStateRegistry, IETHLockbox(address(0)))
                )
            );
        }

        // Lines 816-827 — ETHLockbox (conditional).
        if (isInitialDeployment || _cts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX)) {
            IOptimismPortal[] memory portals = new IOptimismPortal[](1);
            portals[0] = _cts.optimismPortal;
            _upgrade(
                _cts.proxyAdmin,
                address(_cts.ethLockbox),
                impls.ethLockboxImpl,
                abi.encodeCall(IETHLockbox.initialize, (_cts.systemConfig, portals))
            );
        }

        phase = 3;
    }

    /// @notice Stage 3: interop liquidity migration + LCDM + bridges +
    ///         OptimismMintableERC20Factory. Mirror of `OPCMv2._apply` lines 829-881.
    function step3_messengerAndBridges(FullConfig memory /* _cfg */, ChainContracts memory _cts)
        external
        onlyDeployer
    {
        if (phase != 3) revert RSKOPCMSplitter_NotStarted();

        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 829-846 — interop liquidity migration (conditional).
        if (isDevFeatureEnabled(DevFeatures.OPTIMISM_PORTAL_INTEROP)) {
            if (!_cts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX)) {
                _cts.systemConfig.setFeature(Features.ETH_LOCKBOX, true);
            }
            if (!_cts.systemConfig.isFeatureEnabled(Features.INTEROP)) {
                _cts.systemConfig.setFeature(Features.INTEROP, true);
            }
            IOptimismPortal(payable(_cts.optimismPortal)).migrateLiquidity();
        }

        // Lines 848-857 — L1CrossDomainMessenger (slot 0, offset 20).
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1CrossDomainMessenger),
            impls.l1CrossDomainMessengerImpl,
            abi.encodeCall(IL1CrossDomainMessenger.initialize, (_cts.systemConfig, _cts.optimismPortal)),
            bytes32(0),
            20
        );

        // Lines 859-865 — L1StandardBridge.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1StandardBridge),
            impls.l1StandardBridgeImpl,
            abi.encodeCall(IL1StandardBridge.initialize, (_cts.l1CrossDomainMessenger, _cts.systemConfig))
        );

        // Lines 867-873 — L1ERC721Bridge.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1ERC721Bridge),
            impls.l1ERC721BridgeImpl,
            abi.encodeCall(IL1ERC721Bridge.initialize, (_cts.l1CrossDomainMessenger, _cts.systemConfig))
        );

        // Lines 875-881 — OptimismMintableERC20Factory.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.optimismMintableERC20Factory),
            impls.optimismMintableERC20FactoryImpl,
            abi.encodeCall(IOptimismMintableERC20Factory.initialize, (address(_cts.l1StandardBridge)))
        );

        phase = 4;
    }

    /// @notice Stage 4a: DisputeGameFactory + DelayedWETH. Mirror of
    ///         `OPCMv2._apply` lines 883-897 — first half of stage 4.
    function step4a_disputeFactoryAndWeth(FullConfig memory /* _cfg */, ChainContracts memory _cts)
        external
        onlyDeployer
    {
        if (phase != 4) revert RSKOPCMSplitter_NotStarted();

        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 883-889 — DisputeGameFactory.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.disputeGameFactory),
            impls.disputeGameFactoryImpl,
            abi.encodeCall(IDisputeGameFactory.initialize, (address(this)))
        );

        // Lines 891-897 — DelayedWETH.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.delayedWETH),
            impls.delayedWETHImpl,
            abi.encodeCall(IDelayedWETH.initialize, (_cts.systemConfig))
        );

        phase = 5;
    }

    /// @notice Stage 4b: AnchorStateRegistry + dispute-game config loop +
    ///         custom gas token branch. Mirror of `OPCMv2._apply` lines
    ///         899-947 — second half of stage 4.
    function step4b_anchorAndGames(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 5) revert RSKOPCMSplitter_NotStarted();

        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 899-908 — AnchorStateRegistry.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.anchorStateRegistry),
            impls.anchorStateRegistryImpl,
            abi.encodeCall(
                IAnchorStateRegistry.initialize,
                (_cts.systemConfig, _cts.disputeGameFactory, _cfg.startingAnchorRoot, _cfg.startingRespectedGameType)
            )
        );

        // Lines 910-934 — dispute games loop.
        for (uint256 i = 0; i < _cfg.disputeGameConfigs.length; i++) {
            IDisputeGame gameImpl = IDisputeGame(address(0));
            bytes memory gameArgs = bytes("");

            if (_cfg.disputeGameConfigs[i].enabled) {
                gameImpl = _getGameImpl(_cfg.disputeGameConfigs[i].gameType);
                gameArgs = _makeGameArgs(
                    _cfg.l2ChainId, _cts.anchorStateRegistry, _cts.delayedWETH, _cfg.disputeGameConfigs[i]
                );
            }

            _cts.disputeGameFactory.setImplementation(_cfg.disputeGameConfigs[i].gameType, gameImpl, gameArgs);
            _cts.disputeGameFactory.setInitBond(
                _cfg.disputeGameConfigs[i].gameType, _cfg.disputeGameConfigs[i].initBond
            );
        }

        // Lines 936-947 — custom gas token (conditional, initial-deploy only).
        if (_cfg.useCustomGasToken && !_cts.systemConfig.isCustomGasToken()) {
            if (!isInitialDeployment) {
                revert RSKOPCMSplitter_CannotUpgradeToCustomGasToken();
            }
            _cts.systemConfig.setFeature(Features.CUSTOM_GAS_TOKEN, true);
        }

        phase = 6;
    }

    /// @notice Stage 5: terminal ownership transfers (initial deploy only).
    ///         Mirror of `OPCMv2._apply` lines 949-962. Seals the splitter.
    function step5_finalize(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 6) revert RSKOPCMSplitter_NotStarted();

        // Lines 949-962. On upgrade we skip the terminal transfers entirely
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
    // PRIVATE HELPERS — only `_loadProxies`, `_loadFullConfigForUpgrade`,
    // `_assertValidFullConfig`, and `_makeSystemConfigInitArgs` need to be
    // local. Everything else (`_upgrade`, `_loadOrDeployProxy`, etc.) is
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
    ///      lines 385-444 (initial-deployment branch).
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

        // Initial deployment always deploys ETHLockbox (matches upstream's
        // `_isInitialDeployment || systemConfig.isFeatureEnabled(...)`
        // branch with `_isInitialDeployment = true`).
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
    ///      `OPCMv2._loadChainContracts` upstream lines 466-534.
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

    /// @dev Verbatim port of `OPCMv2._assertValidFullConfig` (lines 688-742).
    function _assertValidFullConfig(FullConfig memory _cfg, bool _isInitialDeployment) internal pure {
        GameType[] memory validGameTypes = new GameType[](6);
        validGameTypes[0] = GameTypes.CANNON;
        validGameTypes[1] = GameTypes.PERMISSIONED_CANNON;
        validGameTypes[2] = GameTypes.CANNON_KONA;
        validGameTypes[3] = GameTypes.SUPER_CANNON;
        validGameTypes[4] = GameTypes.SUPER_PERMISSIONED_CANNON;
        validGameTypes[5] = GameTypes.SUPER_CANNON_KONA;

        if (_cfg.disputeGameConfigs.length != validGameTypes.length) {
            revert RSKOPCMSplitter_InvalidGameConfigs();
        }

        for (uint256 i = 0; i < _cfg.disputeGameConfigs.length; i++) {
            if (_cfg.disputeGameConfigs[i].gameType.raw() != validGameTypes[i].raw()) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }
            if (!_cfg.disputeGameConfigs[i].enabled && _cfg.disputeGameConfigs[i].initBond != 0) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
            }
            bool isPermissioned = validGameTypes[i].raw() == GameTypes.PERMISSIONED_CANNON.raw()
                || validGameTypes[i].raw() == GameTypes.SUPER_PERMISSIONED_CANNON.raw();
            if (_isInitialDeployment && !isPermissioned && _cfg.disputeGameConfigs[i].enabled) {
                revert RSKOPCMSplitter_InvalidGameConfigs();
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

    /// @dev Verbatim port of `OPCMv2._makeSystemConfigInitArgs` (lines 973-1009).
    ///      The only OPCMv2-private field used is `opcmV2` (passed into the
    ///      SystemConfig.Addresses struct as `opcm`). Since RSK chains are
    ///      deployed by the splitter rather than by an OPCMv2 instance, we
    ///      bind `opcm` to the splitter's address — the SystemConfig stores
    ///      it as the "OPCM that last managed me", which is structurally
    ///      true here.
    function _makeSystemConfigInitArgs(
        FullConfig memory _cfg,
        ChainContracts memory _cts
    )
        internal
        view
        returns (bytes memory)
    {
        ISystemConfig.Addresses memory addrs = ISystemConfig.Addresses({
            l1CrossDomainMessenger: address(_cts.l1CrossDomainMessenger),
            l1ERC721Bridge: address(_cts.l1ERC721Bridge),
            l1StandardBridge: address(_cts.l1StandardBridge),
            optimismPortal: address(_cts.optimismPortal),
            optimismMintableERC20Factory: address(_cts.optimismMintableERC20Factory),
            delayedWETH: address(_cts.delayedWETH),
            opcm: address(this)
        });

        return abi.encodeCall(
            ISystemConfig.initialize,
            (
                _cfg.systemConfigOwner,
                _cfg.basefeeScalar,
                _cfg.blobBasefeeScalar,
                bytes32(uint256(uint160(_cfg.batcher))),
                _cfg.gasLimit,
                _cfg.unsafeBlockSigner,
                _cfg.resourceConfig,
                _chainIdToBatchInboxAddress(_cfg.l2ChainId),
                addrs,
                _cfg.l2ChainId,
                _cfg.superchainConfig
            )
        );
    }
}
