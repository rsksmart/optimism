// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// =============================================================================
// RSKOPCMSplitterBase
//
// The OPContractsManagerV2 9.0.2 port shared by the two RSK chain managers:
// RSKOPCMSplitter (initial deployment, staged across transactions) and
// RSKOPCMSplitterUpgrade (upgrade of an existing chain, one transaction).
//
//   * The constructor takes the deployed OPCMv2, requires it to be version
//     9.0.2 (the release this port mirrors) and reads its utils and container
//     from it, so the inherited `OPContractsManagerUtilsCaller` helpers and
//     the read-throughs act on that release.
//   * `_assertValidFullConfig` is upstream's, with the two RSK divergences
//     about PERMISSIONED_CANNON documented on it.
//   * `_apply` is cut into four contiguous slices of upstream's straight-line
//     code (`_applySystemConfigAndPortal`, `_applyMessengerAndBridges`,
//     `_applyDisputeFactoryAndWeth`, `_applyAnchorAndGames`); nothing is
//     reordered. The prelude (config validation, SuperchainConfig version,
//     upgrade sequence) and the terminal ownership transfers stay with each
//     caller, because they differ between a deployment and an upgrade.
//
// Line numbers refer to OPContractsManagerV2.sol at op-node/v1.19.9 (version
// 9.0.2; there is no op-contracts/v9 release tag). An upstream sync that
// changes the OPCMv2 version must re-port this file.
// =============================================================================

import { OPContractsManagerUtilsCaller } from "src/L1/opcm/OPContractsManagerUtilsCaller.sol";

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
import { IOPContractsManagerUtils } from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import { IOPContractsManagerV2 } from "interfaces/L1/opcm/IOPContractsManagerV2.sol";

abstract contract RSKOPCMSplitterBase is OPContractsManagerUtilsCaller {
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

    /// @notice Number of dispute game configs a full config must supply. Mirror of
    ///         `OPContractsManagerV2.VALID_GAME_TYPE_COUNT`.
    uint256 internal constant VALID_GAME_TYPE_COUNT = 6;

    /// @notice The valid game types, packed low-to-high as six uint32s in the order the dispute
    ///         game configs must be supplied: CANNON, PERMISSIONED_CANNON, CANNON_KONA,
    ///         SUPER_PERMISSIONED, SUPER_CANNON_KONA, ZK_DISPUTE_GAME. Mirror of
    ///         `OPContractsManagerV2.VALID_GAME_TYPES`.
    uint256 internal constant VALID_GAME_TYPES = 0x0000000a_00000009_00000005_00000008_00000001_00000000;

    /// @notice The OPCMv2 version whose `_loadChainContracts` and `_apply` the
    ///         stages port. An upstream sync that changes it must re-port them.
    string internal constant MIRRORED_OPCM_VERSION = "9.0.2";

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error RSKOPCMSplitter_InvalidGameConfigs();
    error RSKOPCMSplitter_SuperchainConfigNeedsUpgrade();
    error RSKOPCMSplitter_CannotUpgradeToCustomGasToken();
    error RSKOPCMSplitter_InvalidEthLockbox();
    error RSKOPCMSplitter_ZeroGameImplementation(GameType _gameType);
    error RSKOPCMSplitter_UnsupportedOPCMVersion(string _version);

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    /// @notice The OPCMv2 this contract mirrors. The SystemConfig slice records
    ///         it as the chain's last-used OPCM, as upstream records itself, so
    ///         a stock OPCMv2 can later read `lastUsedOPCMVersion()`.
    IOPContractsManagerV2 public immutable opcmV2;

    /// @notice Container that holds the Implementations + Blueprints arrays.
    ///         Read-through from `blueprints()` / `implementations()`.
    IOPContractsManagerContainer public immutable container;

    /// @param _opcmV2 The deployed OPCMv2, which must be `MIRRORED_OPCM_VERSION`.
    ///                Its utils and container are read here, so the inherited
    ///                helpers delegatecall into the same OPContractsManagerUtils
    ///                and read the same Implementations + Blueprints as that
    ///                OPCMv2.
    constructor(IOPContractsManagerV2 _opcmV2) OPContractsManagerUtilsCaller(_opcmV2.opcmUtils()) {
        string memory version = _opcmV2.version();
        if (!SemverComp.eq(version, MIRRORED_OPCM_VERSION)) revert RSKOPCMSplitter_UnsupportedOPCMVersion(version);
        opcmV2 = _opcmV2;
        container = _opcmV2.contractsContainer();
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

    // =======================================================================
    // _apply SLICES — upstream lines 838-1018, in order. Every caller runs all
    // four, in this order, after its own prelude, passing the
    // `implementations()` it read (upstream reads them once, at line 822).
    // =======================================================================

    /// @dev `_apply` lines 838-904: SystemConfig, ETHLockbox feature, Portal,
    ///      ETHLockbox and the liquidity migration.
    function _applySystemConfigAndPortal(
        FullConfig memory _cfg,
        ChainContracts memory _cts,
        IOPContractsManagerContainer.Implementations memory _impls,
        bool _isInitialDeployment
    )
        internal
    {

        // Lines 838-865 — SystemConfig. `opcm` is `opcmV2`, as upstream, so
        // `lastUsedOPCM` has a `version()` and a stock OPCMv2 can upgrade the
        // chain (with a non-zero PERMISSIONED_CANNON bond, see
        // `_assertValidFullConfig`).
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.systemConfig),
            _impls.systemConfigImpl,
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
                        opcm: address(opcmV2)
                    }),
                    l2ChainId: _cfg.l2ChainId,
                    superchainConfig: _cfg.superchainConfig
                })
            )
        );

        // Lines 867-878 — enable ETHLockbox before updating the portal.
        bool wasEthLockboxEnabled = _cts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX);
        bool wasUsingEthLockbox = !_isInitialDeployment && wasEthLockboxEnabled
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
            _impls.optimismPortalImpl,
            abi.encodeCall(IOptimismPortal.initialize, (_cts.systemConfig, _cts.anchorStateRegistry, _cts.ethLockbox))
        );

        // Lines 891-899 — ETHLockbox.
        IOptimismPortal[] memory portals = new IOptimismPortal[](1);
        portals[0] = _cts.optimismPortal;
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.ethLockbox),
            _impls.ethLockboxImpl,
            abi.encodeCall(IETHLockbox.initialize, (_cts.systemConfig.superchainConfig(), portals))
        );

        // Lines 901-904 — custom gas token chains keep custody in the portal.
        if (!wasUsingEthLockbox && !_cfg.useCustomGasToken) {
            _cts.optimismPortal.migrateLiquidity();
        }
    }

    /// @dev `_apply` lines 906-939: L1CrossDomainMessenger, both bridges and
    ///      the OptimismMintableERC20Factory.
    function _applyMessengerAndBridges(
        ChainContracts memory _cts,
        IOPContractsManagerContainer.Implementations memory _impls
    )
        internal
    {

        // Lines 906-915 — L1CrossDomainMessenger (slot 0, offset 20).
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1CrossDomainMessenger),
            _impls.l1CrossDomainMessengerImpl,
            abi.encodeCall(IL1CrossDomainMessenger.initialize, (_cts.systemConfig, _cts.optimismPortal)),
            bytes32(0),
            20
        );

        // Lines 917-923 — L1StandardBridge.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1StandardBridge),
            _impls.l1StandardBridgeImpl,
            abi.encodeCall(IL1StandardBridge.initialize, (_cts.l1CrossDomainMessenger, _cts.systemConfig))
        );

        // Lines 925-931 — L1ERC721Bridge.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.l1ERC721Bridge),
            _impls.l1ERC721BridgeImpl,
            abi.encodeCall(IL1ERC721Bridge.initialize, (_cts.l1CrossDomainMessenger, _cts.systemConfig))
        );

        // Lines 933-939 — OptimismMintableERC20Factory.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.optimismMintableERC20Factory),
            _impls.optimismMintableERC20FactoryImpl,
            abi.encodeCall(IOptimismMintableERC20Factory.initialize, (address(_cts.l1StandardBridge)))
        );
    }

    /// @dev `_apply` lines 941-955: DisputeGameFactory and DelayedWETH. The
    ///      factory is reinitialized with this contract as its owner, so the
    ///      game loop in `_applyAnchorAndGames` may configure it.
    function _applyDisputeFactoryAndWeth(
        ChainContracts memory _cts,
        IOPContractsManagerContainer.Implementations memory _impls
    )
        internal
    {

        // Lines 941-947 — DisputeGameFactory.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.disputeGameFactory),
            _impls.disputeGameFactoryImpl,
            abi.encodeCall(IDisputeGameFactory.initialize, (address(this)))
        );

        // Lines 949-955 — DelayedWETH.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.delayedWETH),
            _impls.delayedWETHImpl,
            abi.encodeCall(IDelayedWETH.initialize, (_cts.ethLockbox))
        );
    }

    /// @dev `_apply` lines 957-1018: AnchorStateRegistry, the dispute game
    ///      loop, the SUPER_CANNON clear and the custom gas token branch.
    function _applyAnchorAndGames(
        FullConfig memory _cfg,
        ChainContracts memory _cts,
        IOPContractsManagerContainer.Implementations memory _impls,
        bool _isInitialDeployment
    )
        internal
    {

        // Lines 957-966 — AnchorStateRegistry.
        _upgrade(
            _cts.proxyAdmin,
            address(_cts.anchorStateRegistry),
            _impls.anchorStateRegistryImpl,
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
            if (!_isInitialDeployment) {
                revert RSKOPCMSplitter_CannotUpgradeToCustomGasToken();
            }
            _cts.systemConfig.setFeature(Features.CUSTOM_GAS_TOKEN, true);
        }
    }

    // =======================================================================
    // VALIDATION
    // =======================================================================

    /// @dev Upstream lines 824-827: the SuperchainConfig must be at least as
    ///      new as this release's implementation.
    function _assertSuperchainConfigUpToDate(ISuperchainConfig _superchainConfig, address _impl) internal view {
        if (SemverComp.lt(_superchainConfig.version(), ISuperchainConfig(_impl).version())) {
            revert RSKOPCMSplitter_SuperchainConfigNeedsUpgrade();
        }
    }

    /// @dev Port of `OPCMv2._assertValidFullConfig` (upstream lines 691-803).
    ///      Two RSK divergences, both marked inline and both about
    ///      PERMISSIONED_CANNON: it is valid in an initial deployment despite the
    ///      super-root flag, in place of the super-root games, and it may carry
    ///      a zero init bond (PAYROLLUP-191). A stock OPCMv2 rejects that zero
    ///      bond, so its upgrade input has to give the game a non-zero one.
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
            // super-root games while SUPER_ROOT_GAMES_MIGRATION is on, and OPCMv2
            // 9.0.2 hard-wires that flag on (DevFeatures). RSK runs one L2 per L1
            // with no interop, so it keeps deploying PERMISSIONED_CANNON, the
            // output-root game OptimismPortal2 still proves withdrawals against.
            // With the flag on that is the only valid game: the super-root games
            // are not, so a deployment never mixes the two families. The
            // CANNON_KONA arm keeps upstream's flag-off case and stays
            // unreachable until upstream stops hard-wiring the flag.
            bool validForInitialDeploy =
                isPermissionedCannonGame || (!superRootGamesMigrationEnabled && isCannonKonaGame);
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
