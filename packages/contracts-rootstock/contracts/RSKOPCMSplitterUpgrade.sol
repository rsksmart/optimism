// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// =============================================================================
// RSKOPCMSplitterUpgrade
//
// Upgrades an existing RSK chain to the OPCMv2 9.0.2 release in one
// transaction: the RSK counterpart of `OPContractsManagerV2.upgrade`, with
// `upgradeSuperchain` folded in when the SuperchainConfig is behind (F1.1 in
// RSK_COMPATIBILITY_BLOCKERS.md). It shares the `_apply` port with the deploy
// splitter through RSKOPCMSplitterBase.
//
// A stock OPCMv2 9.0.2 cannot upgrade these chains: `upgrade` only runs under
// DELEGATECALL from the ProxyAdmin owner, its sequence check reads
// `lastUsedOPCMVersion()`, which reverts on chains the 7.1.17 splitter
// deployed, and it requires a non-zero PERMISSIONED_CANNON bond.
//
// Differences from upstream's `upgrade`:
//   * Called directly, not delegatecalled. The owner of the chain's ProxyAdmin
//     (and of the superchain's, when the SuperchainConfig needs upgrading)
//     hands it to this contract with `transferOwnership`. The constructor
//     records both owners; `upgrade` returns each ProxyAdmin to its recorded
//     owner at the end of the same transaction, and `abort` does so without
//     upgrading.
//   * `_apply` reinitializes the DisputeGameFactory with this contract as its
//     owner (upstream: the delegatecalling ProxyAdmin owner) so the game loop
//     can configure it; `upgrade` then gives it back to the owner it had.
//   * `_loadChainContracts` and `_loadFullConfig` are upstream's upgrade
//     branch: every address and value is derived from the SystemConfig. Two
//     exceptions: `proxyAdminOwner` is the recorded owner (upstream reads the
//     Portal, which during the session answers this contract; an upgrade
//     never uses it), and the `overrides.cts.ethLockbox` instruction, see
//     `_loadEthLockbox`.
//   * The upgrade-sequence check accepts chains the pre-9.0.2 splitter
//     deployed, see `_assertPermittedUpgradeSequence`.
//   * The withdrawal-path delays and the fault games' depths and clocks must
//     be the same in the 9.0.2 implementations as on the chain, see
//     `_assertImmutablesUnchanged`.
//   * `_assertValidFullConfig` keeps the PAYROLLUP-191 zero bond for
//     PERMISSIONED_CANNON, as the deploy splitter does. The game loop
//     regenerates every game's args from the input.
//
// Each instance upgrades one chain once: deploy it for that chain's
// SystemConfig, hand it the ProxyAdmin(s), call `upgrade`, throw it away.
// Only the `deployer` (the account that constructed it) may call it.
// =============================================================================

import { RSKOPCMSplitterBase } from "./RSKOPCMSplitterBase.sol";

import { GameType, Proposal } from "src/dispute/lib/Types.sol";
import { SemverComp } from "src/libraries/SemverComp.sol";
import { Constants } from "src/libraries/Constants.sol";

import { IDelayedWETH } from "interfaces/dispute/IDelayedWETH.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IAddressManager } from "interfaces/legacy/IAddressManager.sol";
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IFaultDisputeGame } from "interfaces/dispute/IFaultDisputeGame.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IOptimismPortal2 as IOptimismPortal } from "interfaces/L1/IOptimismPortal2.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IOptimismMintableERC20Factory } from "interfaces/universal/IOptimismMintableERC20Factory.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { IOPContractsManagerContainer } from "interfaces/L1/opcm/IOPContractsManagerContainer.sol";
import { IOPContractsManagerUtils } from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import { IOPContractsManagerV2 } from "interfaces/L1/opcm/IOPContractsManagerV2.sol";

contract RSKOPCMSplitterUpgrade is RSKOPCMSplitterBase {
    /// @notice Mirror of `OPContractsManagerV2.UpgradeInput`.
    struct UpgradeInput {
        ISystemConfig systemConfig;
        IOPContractsManagerUtils.DisputeGameConfig[] disputeGameConfigs;
        IOPContractsManagerUtils.ExtraInstruction[] extraInstructions;
    }

    /// @notice The SystemConfig version the pre-9.0.2 splitter (OPCMv2 7.1.17)
    ///         deployed. See `_assertPermittedUpgradeSequence`.
    string internal constant LEGACY_SPLITTER_SYSTEM_CONFIG_VERSION = "3.14.2";

    /// @notice RSK instruction naming an existing ETHLockbox proxy to adopt.
    ///         Its data is `abi.encode(address)`. See `_loadEthLockbox`.
    string internal constant ETH_LOCKBOX_OVERRIDE_KEY = "overrides.cts.ethLockbox";

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error RSKOPCMSplitterUpgrade_NotDeployer();
    error RSKOPCMSplitterUpgrade_AlreadyFinished();
    error RSKOPCMSplitterUpgrade_WrongSystemConfig();
    error RSKOPCMSplitterUpgrade_NotProxyAdminOwner(IProxyAdmin _proxyAdmin);
    error RSKOPCMSplitterUpgrade_InvalidUpgradeInstruction(string _key);
    error RSKOPCMSplitterUpgrade_DuplicateUpgradeInstruction(string _key);
    error RSKOPCMSplitterUpgrade_InvalidUpgradeSequence(string _lastVersion, string _thisVersion);
    error RSKOPCMSplitterUpgrade_ImmutableChanged(string _name, uint256 _current, uint256 _next);
    error RSKOPCMSplitterUpgrade_InvalidEthLockboxOverride(address _ethLockbox);
    error RSKOPCMSplitterUpgrade_OwnerIsUpgrader(IProxyAdmin _proxyAdmin);

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    /// @notice The account that constructed this contract. Only it may call
    ///         `upgrade` or `abort`.
    address public immutable deployer;

    /// @notice The SystemConfig of the chain this instance upgrades.
    ISystemConfig public immutable systemConfig;

    /// @notice The chain's ProxyAdmin and its owner at construction, who gets
    ///         it back.
    IProxyAdmin public immutable chainProxyAdmin;
    address public immutable chainProxyAdminOwner;

    /// @notice The SuperchainConfig's ProxyAdmin and its owner at
    ///         construction, who gets it back.
    IProxyAdmin public immutable superchainProxyAdmin;
    address public immutable superchainProxyAdminOwner;

    /// @notice True once `upgrade` or `abort` ran; no further calls accepted.
    bool public finished;

    /// @param _opcmV2 The deployed OPCMv2, which must be `MIRRORED_OPCM_VERSION`
    ///                (checked by RSKOPCMSplitterBase).
    /// @param _systemConfig The SystemConfig of the chain to upgrade. Its
    ///                ProxyAdmin owners are read here, so they must hand the
    ///                ProxyAdmins over only after this contract exists: an
    ///                owner read as this contract would never get them back.
    constructor(IOPContractsManagerV2 _opcmV2, ISystemConfig _systemConfig) RSKOPCMSplitterBase(_opcmV2) {
        IProxyAdmin chainAdmin = _systemConfig.proxyAdmin();
        IProxyAdmin superchainAdmin = _systemConfig.superchainConfig().proxyAdmin();
        address chainOwner = chainAdmin.owner();
        address superchainOwner = superchainAdmin.owner();
        if (chainOwner == address(this)) revert RSKOPCMSplitterUpgrade_OwnerIsUpgrader(chainAdmin);
        if (superchainOwner == address(this)) revert RSKOPCMSplitterUpgrade_OwnerIsUpgrader(superchainAdmin);

        deployer = msg.sender;
        systemConfig = _systemConfig;
        chainProxyAdmin = chainAdmin;
        chainProxyAdminOwner = chainOwner;
        superchainProxyAdmin = superchainAdmin;
        superchainProxyAdminOwner = superchainOwner;
    }

    // -----------------------------------------------------------------------
    // Entry points
    // -----------------------------------------------------------------------

    /// @notice Upgrades the chain to this release and returns every ProxyAdmin
    ///         to its recorded owner. Mirror of `OPCMv2.upgrade` (upstream
    ///         lines 245-276), preceded by `OPCMv2.upgradeSuperchain` (lines
    ///         197-214) when the SuperchainConfig is older than this release's.
    /// @param _inp The upgrade input; `systemConfig` must be this instance's.
    /// @return cts_ The upgraded chain contracts.
    function upgrade(UpgradeInput memory _inp) external returns (ChainContracts memory cts_) {
        _checkDeployer();
        if (_inp.systemConfig != systemConfig) revert RSKOPCMSplitterUpgrade_WrongSystemConfig();
        _assertOwns(chainProxyAdmin);

        // Line 266.
        _assertValidUpgradeInstructions(_inp.extraInstructions);

        IOPContractsManagerContainer.Implementations memory impls = implementations();
        _upgradeSuperchainIfBehind(impls);

        // Lines 269-273.
        cts_ = _loadChainContracts(
            _inp.systemConfig, _inp.systemConfig.l2ChainId(), "salt mixer", _inp.extraInstructions
        );
        if (cts_.proxyAdmin != chainProxyAdmin) revert RSKOPCMSplitterUpgrade_NotProxyAdminOwner(cts_.proxyAdmin);
        FullConfig memory cfg = _loadFullConfig(_inp, cts_);

        // `_apply` prelude, lines 818-836.
        _assertValidFullConfig(cfg, false);
        _assertSuperchainConfigUpToDate(cfg.superchainConfig, impls.superchainConfigImpl);
        _assertPermittedUpgradeSequence(cts_.systemConfig);
        _assertImmutablesUnchanged(cfg, cts_, impls);

        // `_apply` lines 838-1018. The factory owner is read before the
        // DisputeGameFactory slice makes this contract its owner.
        address disputeGameFactoryOwner = cts_.disputeGameFactory.owner();
        _applySystemConfigAndPortal(cfg, cts_, impls, false);
        _applyMessengerAndBridges(cts_, impls);
        _applyDisputeFactoryAndWeth(cts_, impls);
        _applyAnchorAndGames(cfg, cts_, impls, false);
        cts_.disputeGameFactory.transferOwnership(disputeGameFactoryOwner);

        _handBack();
    }

    /// @notice Returns every ProxyAdmin this contract holds to its recorded
    ///         owner without upgrading anything, and finishes the session.
    function abort() external {
        _checkDeployer();
        _handBack();
    }

    // -----------------------------------------------------------------------
    // Session helpers
    // -----------------------------------------------------------------------

    function _checkDeployer() internal view {
        if (msg.sender != deployer) revert RSKOPCMSplitterUpgrade_NotDeployer();
        if (finished) revert RSKOPCMSplitterUpgrade_AlreadyFinished();
    }

    function _assertOwns(IProxyAdmin _proxyAdmin) internal view {
        if (_proxyAdmin.owner() != address(this)) revert RSKOPCMSplitterUpgrade_NotProxyAdminOwner(_proxyAdmin);
    }

    /// @dev Gives each ProxyAdmin this contract holds back to the owner the
    ///      constructor recorded, and finishes the session.
    function _handBack() internal {
        finished = true;
        if (chainProxyAdmin.owner() == address(this)) {
            chainProxyAdmin.transferOwnership(chainProxyAdminOwner);
        }
        if (superchainProxyAdmin != chainProxyAdmin && superchainProxyAdmin.owner() == address(this)) {
            superchainProxyAdmin.transferOwnership(superchainProxyAdminOwner);
        }
    }

    /// @dev `OPCMv2.upgradeSuperchain` (lines 197-214), run only when the
    ///      SuperchainConfig is older than this release's. Upstream leaves
    ///      that to a separate call and `_apply` reverts while it is behind;
    ///      folding it in keeps the whole upgrade in one transaction. An
    ///      up-to-date SuperchainConfig is left alone, so its ProxyAdmin need
    ///      not be handed over.
    function _upgradeSuperchainIfBehind(IOPContractsManagerContainer.Implementations memory _impls) internal {
        ISuperchainConfig superchainConfig = systemConfig.superchainConfig();
        if (!SemverComp.lt(superchainConfig.version(), ISuperchainConfig(_impls.superchainConfigImpl).version())) {
            return;
        }
        _assertOwns(superchainProxyAdmin);
        _upgrade(
            superchainProxyAdmin,
            address(superchainConfig),
            _impls.superchainConfigImpl,
            abi.encodeCall(ISuperchainConfig.initialize, (superchainConfig.guardian()))
        );
    }

    // -----------------------------------------------------------------------
    // Upgrade checks
    // -----------------------------------------------------------------------

    /// @dev Port of `OPCMv2._assertValidUpgradeInstructions` (lines 323-342).
    function _assertValidUpgradeInstructions(IOPContractsManagerUtils.ExtraInstruction[] memory _extraInstructions)
        internal
        view
    {
        for (uint256 i = 0; i < _extraInstructions.length; i++) {
            if (!_isMatchingInstructionByKey(_extraInstructions[i], Constants.PERMITTED_PROXY_DEPLOYMENT_KEY)) {
                for (uint256 j = i + 1; j < _extraInstructions.length; j++) {
                    if (keccak256(bytes(_extraInstructions[i].key)) == keccak256(bytes(_extraInstructions[j].key))) {
                        revert RSKOPCMSplitterUpgrade_DuplicateUpgradeInstruction(_extraInstructions[i].key);
                    }
                }
            }

            if (!_isPermittedInstruction(_extraInstructions[i])) {
                revert RSKOPCMSplitterUpgrade_InvalidUpgradeInstruction(_extraInstructions[i].key);
            }
        }
    }

    /// @dev Port of `OPCMv2._isPermittedInstruction` (lines 348-377) plus the
    ///      RSK `overrides.cts.ethLockbox` instruction.
    function _isPermittedInstruction(IOPContractsManagerUtils.ExtraInstruction memory _instruction)
        internal
        view
        returns (bool)
    {
        if (SemverComp.parse(MIRRORED_OPCM_VERSION).major == 9) {
            // Allow deploying an ETHLockbox for existing chains only in the v9 release.
            if (_isMatchingInstruction(_instruction, Constants.PERMITTED_PROXY_DEPLOYMENT_KEY, bytes("ETHLockbox"))) {
                return true;
            }
        }

        if (_isMatchingInstructionByKey(_instruction, "overrides.cfg.startingRespectedGameType")) {
            return true;
        }

        // RSK: adopt the ETHLockbox proxy the pre-9.0.2 splitter left unused.
        if (_isMatchingInstructionByKey(_instruction, ETH_LOCKBOX_OVERRIDE_KEY)) {
            return true;
        }

        return false;
    }

    /// @dev Upstream lines 829-836, plus the chains the pre-9.0.2 splitter
    ///      deployed. That splitter recorded itself as `lastUsedOPCM` and has
    ///      no `version()`, so `lastUsedOPCMVersion()` reverts and upstream's
    ///      check cannot run. It only ever mirrored OPCMv2 7.1.17, whose
    ///      SystemConfig is 3.14.2: while the SystemConfig still runs that
    ///      version nothing has upgraded the chain since, and it goes straight
    ///      to 9.0.2. The fork never had an OPCMv2 8.x, so 7 to 9 is the only
    ///      path; upstream would require 8.x in between.
    function _assertPermittedUpgradeSequence(ISystemConfig _systemConfig) internal view {
        try _systemConfig.lastUsedOPCMVersion() returns (string memory lastVersion) {
            if (!_isPermittedUpgradeSequence(_systemConfig, address(opcmV2))) {
                revert RSKOPCMSplitterUpgrade_InvalidUpgradeSequence(lastVersion, MIRRORED_OPCM_VERSION);
            }
        } catch {
            if (!SemverComp.eq(_systemConfig.version(), LEGACY_SPLITTER_SYSTEM_CONFIG_VERSION)) {
                revert RSKOPCMSplitterUpgrade_InvalidUpgradeSequence("", MIRRORED_OPCM_VERSION);
            }
        }
    }

    /// @dev RSK check, not in upstream. The proof maturity delay
    ///      (OptimismPortal2), the dispute game finality delay
    ///      (AnchorStateRegistry), the withdrawal delay (DelayedWETH) and the
    ///      depths and clocks of the output-root fault games are constructor
    ///      immutables of the implementations, so implementations built with
    ///      other values would change them without any input saying so.
    ///      Refuses that before anything is touched: changing one is a
    ///      separate decision from a release upgrade. A game is compared only
    ///      when the input enables it and the chain already runs it.
    function _assertImmutablesUnchanged(
        FullConfig memory _cfg,
        ChainContracts memory _cts,
        IOPContractsManagerContainer.Implementations memory _impls
    )
        internal
        view
    {
        _assertUnchanged(
            "proofMaturityDelaySeconds",
            _cts.optimismPortal.proofMaturityDelaySeconds(),
            IOptimismPortal(payable(_impls.optimismPortalImpl)).proofMaturityDelaySeconds()
        );
        _assertUnchanged(
            "disputeGameFinalityDelaySeconds",
            _cts.anchorStateRegistry.disputeGameFinalityDelaySeconds(),
            IAnchorStateRegistry(_impls.anchorStateRegistryImpl).disputeGameFinalityDelaySeconds()
        );
        _assertUnchanged("delay", _cts.delayedWETH.delay(), IDelayedWETH(payable(_impls.delayedWETHImpl)).delay());

        // The first three configs are CANNON, PERMISSIONED_CANNON and
        // CANNON_KONA; `_assertValidFullConfig` checked the order.
        for (uint256 i = 0; i < 3; i++) {
            GameType gameType = _cfg.disputeGameConfigs[i].gameType;
            IFaultDisputeGame current = IFaultDisputeGame(address(_cts.disputeGameFactory.gameImpls(gameType)));
            IFaultDisputeGame next = IFaultDisputeGame(address(_getGameImpl(gameType)));
            if (!_cfg.disputeGameConfigs[i].enabled || address(current) == address(0) || address(next) == address(0)) {
                continue;
            }
            _assertUnchanged("maxGameDepth", current.maxGameDepth(), next.maxGameDepth());
            _assertUnchanged("splitDepth", current.splitDepth(), next.splitDepth());
            _assertUnchanged("clockExtension", current.clockExtension().raw(), next.clockExtension().raw());
            _assertUnchanged("maxClockDuration", current.maxClockDuration().raw(), next.maxClockDuration().raw());
        }
    }

    function _assertUnchanged(string memory _name, uint256 _current, uint256 _next) internal pure {
        if (_current != _next) revert RSKOPCMSplitterUpgrade_ImmutableChanged(_name, _current, _next);
    }

    // -----------------------------------------------------------------------
    // Loaders
    // -----------------------------------------------------------------------

    /// @dev Port of the upgrade branch of `OPCMv2._loadChainContracts` (lines
    ///      385-549), with the ETHLockbox loaded by `_loadEthLockbox`.
    function _loadChainContracts(
        ISystemConfig _systemConfig,
        uint256 _l2ChainId,
        string memory _saltMixer,
        IOPContractsManagerUtils.ExtraInstruction[] memory _extraInstructions
    )
        internal
        returns (ChainContracts memory)
    {
        // Lines 438-440.
        IProxyAdmin proxyAdmin = _systemConfig.proxyAdmin();
        IAddressManager addressManager = proxyAdmin.addressManager();

        IOPContractsManagerUtils.ProxyDeployArgs memory proxyDeployArgs = IOPContractsManagerUtils.ProxyDeployArgs({
            proxyAdmin: proxyAdmin,
            addressManager: addressManager,
            l2ChainId: _l2ChainId,
            saltMixer: _saltMixer
        });

        // Lines 453-461.
        IOptimismPortal optimismPortal = IOptimismPortal(
            _loadOrDeployProxy(
                address(_systemConfig),
                _systemConfig.optimismPortal.selector,
                proxyDeployArgs,
                "OptimismPortal",
                _extraInstructions
            )
        );

        // Lines 464-472.
        IETHLockbox ethLockbox = _loadEthLockbox(_systemConfig, optimismPortal, proxyDeployArgs, _extraInstructions);

        // Lines 480-549.
        return ChainContracts({
            systemConfig: _systemConfig,
            proxyAdmin: proxyAdmin,
            addressManager: addressManager,
            optimismPortal: optimismPortal,
            ethLockbox: ethLockbox,
            l1CrossDomainMessenger: IL1CrossDomainMessenger(
                _loadOrDeployProxy(
                    address(_systemConfig),
                    _systemConfig.l1CrossDomainMessenger.selector,
                    proxyDeployArgs,
                    "L1CrossDomainMessenger",
                    _extraInstructions
                )
            ),
            l1ERC721Bridge: IL1ERC721Bridge(
                _loadOrDeployProxy(
                    address(_systemConfig),
                    _systemConfig.l1ERC721Bridge.selector,
                    proxyDeployArgs,
                    "L1ERC721Bridge",
                    _extraInstructions
                )
            ),
            l1StandardBridge: IL1StandardBridge(
                _loadOrDeployProxy(
                    address(_systemConfig),
                    _systemConfig.l1StandardBridge.selector,
                    proxyDeployArgs,
                    "L1StandardBridge",
                    _extraInstructions
                )
            ),
            optimismMintableERC20Factory: IOptimismMintableERC20Factory(
                _loadOrDeployProxy(
                    address(_systemConfig),
                    _systemConfig.optimismMintableERC20Factory.selector,
                    proxyDeployArgs,
                    "OptimismMintableERC20Factory",
                    _extraInstructions
                )
            ),
            disputeGameFactory: IDisputeGameFactory(
                _loadOrDeployProxy(
                    address(_systemConfig),
                    _systemConfig.disputeGameFactory.selector,
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
                    address(_systemConfig),
                    _systemConfig.delayedWETH.selector,
                    proxyDeployArgs,
                    "DelayedWETH",
                    _extraInstructions
                )
            )
        });
    }

    /// @dev Upstream lines 464-472 with an RSK override. The pre-9.0.2
    ///      splitter deployed and initialized an ETHLockbox proxy that the
    ///      5.6.1 portal never pointed at, so `ethLockbox()` answers zero and
    ///      upstream either deploys a new proxy (with the
    ///      PERMITTED_PROXY_DEPLOYMENT "ETHLockbox" instruction) or reverts
    ///      with ProxyMustLoad. `overrides.cts.ethLockbox` adopts the existing
    ///      proxy instead, so the address in the chain's deploy output stays
    ///      the lockbox. It is accepted only when the portal has no lockbox,
    ///      without the deployment permission, and for a proxy this chain's
    ///      ProxyAdmin administers whose `systemConfig()` (ETHLockbox 1.x) is
    ///      this chain's SystemConfig.
    function _loadEthLockbox(
        ISystemConfig _systemConfig,
        IOptimismPortal _optimismPortal,
        IOPContractsManagerUtils.ProxyDeployArgs memory _proxyDeployArgs,
        IOPContractsManagerUtils.ExtraInstruction[] memory _extraInstructions
    )
        internal
        returns (IETHLockbox)
    {
        IOPContractsManagerUtils.ExtraInstruction memory lockboxOverride = abi.decode(
            _staticcall(
                abi.encodeCall(
                    IOPContractsManagerUtils.getInstructionByKey, (_extraInstructions, ETH_LOCKBOX_OVERRIDE_KEY)
                )
            ),
            (IOPContractsManagerUtils.ExtraInstruction)
        );
        if (bytes(lockboxOverride.key).length == 0) {
            return IETHLockbox(
                _loadOrDeployProxy(
                    address(_optimismPortal),
                    _optimismPortal.ethLockbox.selector,
                    _proxyDeployArgs,
                    "ETHLockbox",
                    _extraInstructions
                )
            );
        }

        address ethLockbox = abi.decode(lockboxOverride.data, (address));
        bool deployPermitted = abi.decode(
            _staticcall(
                abi.encodeCall(
                    IOPContractsManagerUtils.hasInstruction,
                    (_extraInstructions, Constants.PERMITTED_PROXY_DEPLOYMENT_KEY, bytes("ETHLockbox"))
                )
            ),
            (bool)
        );
        if (
            deployPermitted || address(_optimismPortal.ethLockbox()) != address(0)
                || !_isProxyOf(_proxyDeployArgs.proxyAdmin, ethLockbox)
                || !_answersAddress(ethLockbox, "systemConfig()", address(_systemConfig))
        ) {
            revert RSKOPCMSplitterUpgrade_InvalidEthLockboxOverride(ethLockbox);
        }
        return IETHLockbox(ethLockbox);
    }

    /// @dev True when `_proxyAdmin` administers `_proxy`.
    function _isProxyOf(IProxyAdmin _proxyAdmin, address _proxy) internal view returns (bool) {
        if (_proxy.code.length == 0) return false;
        try _proxyAdmin.getProxyAdmin(payable(_proxy)) returns (address admin_) {
            return admin_ == address(_proxyAdmin);
        } catch {
            return false;
        }
    }

    /// @dev True when the getter `_signature` on `_target` returns `_expected`.
    function _answersAddress(address _target, string memory _signature, address _expected)
        internal
        view
        returns (bool)
    {
        (bool success, bytes memory result) = _target.staticcall(abi.encodeWithSignature(_signature));
        return success && result.length == 32 && abi.decode(result, (address)) == _expected;
    }

    /// @dev Port of `OPCMv2._loadFullConfig` (lines 556-686), except
    ///      `proxyAdminOwner`: see the header.
    function _loadFullConfig(
        UpgradeInput memory _upgradeInput,
        ChainContracts memory _chainContracts
    )
        internal
        view
        returns (FullConfig memory)
    {
        return FullConfig({
            disputeGameConfigs: _upgradeInput.disputeGameConfigs,
            saltMixer: string(bytes.concat(bytes32(uint256(uint160(address(_chainContracts.systemConfig)))))),
            superchainConfig: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.superchainConfig.selector,
                    "overrides.cfg.superchainConfig",
                    _upgradeInput.extraInstructions
                ),
                (ISuperchainConfig)
            ),
            proxyAdminOwner: chainProxyAdminOwner,
            systemConfigOwner: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.owner.selector,
                    "overrides.cfg.systemConfigOwner",
                    _upgradeInput.extraInstructions
                ),
                (address)
            ),
            unsafeBlockSigner: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.unsafeBlockSigner.selector,
                    "overrides.cfg.unsafeBlockSigner",
                    _upgradeInput.extraInstructions
                ),
                (address)
            ),
            batcher: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.batcherHash.selector,
                    "overrides.cfg.batcher",
                    _upgradeInput.extraInstructions
                ),
                (address)
            ),
            basefeeScalar: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.basefeeScalar.selector,
                    "overrides.cfg.basefeeScalar",
                    _upgradeInput.extraInstructions
                ),
                (uint32)
            ),
            blobBasefeeScalar: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.blobbasefeeScalar.selector,
                    "overrides.cfg.blobBasefeeScalar",
                    _upgradeInput.extraInstructions
                ),
                (uint32)
            ),
            gasLimit: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.gasLimit.selector,
                    "overrides.cfg.gasLimit",
                    _upgradeInput.extraInstructions
                ),
                (uint64)
            ),
            l2ChainId: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.l2ChainId.selector,
                    "overrides.cfg.l2ChainId",
                    _upgradeInput.extraInstructions
                ),
                (uint256)
            ),
            resourceConfig: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.resourceConfig.selector,
                    "overrides.cfg.resourceConfig",
                    _upgradeInput.extraInstructions
                ),
                (IResourceMetering.ResourceConfig)
            ),
            startingAnchorRoot: abi.decode(
                _loadBytes(
                    address(_chainContracts.anchorStateRegistry),
                    _chainContracts.anchorStateRegistry.getStartingAnchorRoot.selector,
                    "overrides.cfg.startingAnchorRoot",
                    _upgradeInput.extraInstructions
                ),
                (Proposal)
            ),
            startingRespectedGameType: abi.decode(
                _loadBytes(
                    address(_chainContracts.anchorStateRegistry),
                    _chainContracts.anchorStateRegistry.respectedGameType.selector,
                    "overrides.cfg.startingRespectedGameType",
                    _upgradeInput.extraInstructions
                ),
                (GameType)
            ),
            useCustomGasToken: abi.decode(
                _loadBytes(
                    address(_chainContracts.systemConfig),
                    _chainContracts.systemConfig.isCustomGasToken.selector,
                    "overrides.cfg.useCustomGasToken",
                    _upgradeInput.extraInstructions
                ),
                (bool)
            )
        });
    }
}
