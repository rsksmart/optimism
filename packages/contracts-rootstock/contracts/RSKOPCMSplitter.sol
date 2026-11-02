// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// =============================================================================
// RSKOPCMSplitter
//
// A thin one-shot helper contract that decomposes the upstream
// OPContractsManagerV2 initial deployment (`deploy`) into a multi-tx sequence
// in which each transaction fits under RSKj's RSKIP144 6.8M per-tx sublist
// gas cap. Upgrading an existing chain is RSKOPCMSplitterUpgrade's job (F1.1);
// both share the `_apply` port in RSKOPCMSplitterBase.
//
// Invariants vs upstream:
//   * Inherits `OPContractsManagerUtilsCaller` (through RSKOPCMSplitterBase)
//     to reuse the inherited `_loadOrDeployProxy`, `_upgrade`,
//     `_makeGameArgs`, `_getGameImpl` and `_encodeSystemConfigInit` helpers
//     verbatim. The actual bodies of most of those helpers live in the
//     deployed `OPContractsManagerUtils` contract and are reached via
//     delegatecall — so the StorageSetter dance, the L1StandardBridge
//     ChugSplash quirk, downgrade protection, version-tag checks, etc. all
//     carry over exactly.
//   * `_loadChainContracts` is lifted line-for-line from
//     `OPContractsManagerV2.sol` (version 9.0.2, as `develop` ships it at
//     op-node/v1.19.9; there is no op-contracts/v9 release tag) and split
//     into the two step-1 stages; `_apply` comes from RSKOPCMSplitterBase as
//     four slices, one per later stage. Each stage's body is a contiguous
//     slice of upstream's straight-line code; nothing is reordered.
//   * The base constructor requires the OPCMv2 to be version 9.0.2 and reads
//     its utils and container. Step 2 records that OPCMv2, not the splitter,
//     as the chain's `lastUsedOPCM`, as upstream does, so RSKOPCMSplitterUpgrade
//     or a stock OPCMv2 can later upgrade the chain. A stock OPCMv2's upgrade
//     input has to give PERMISSIONED_CANNON a non-zero bond: it rejects the
//     zero bond allowed below.
//   * Every stage gets the same inputs. Upstream's `deploy` is one call, so
//     `_apply` acts on the config it validated. Split into transactions,
//     each stage takes its inputs from the caller again. Step 1a validates
//     the config and pins `keccak256(abi.encode(_cfg))` and
//     `keccak256(abi.encode(core))`; step 1b re-pins the contracts as
//     `keccak256(abi.encode(cts))`. Every later stage must pass the same
//     values. Without the pins, step 4b and step 5 would act on values step 2
//     never validated. Validating in step 1a means a config step 2 would
//     reject is refused before any proxy exists.
//   * Two deliberate divergences in `_assertValidFullConfig`, both about
//     PERMISSIONED_CANNON (the output-root permissioned game RSK deploys):
//     - an initial deployment may enable it although OPCMv2 9.0.2
//       hard-wires SUPER_ROOT_GAMES_MIGRATION on, which upstream reads as
//       "initial deployments use super-root games only". RSK runs one L2
//       per L1 with no interop, so a super-root game buys nothing and would
//       make the proposer depend on a super-root RPC. With the flag on it
//       is the only game an initial deployment may enable: the super-root
//       games stay off, so one deployment never mixes the two families;
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
// ownership to `_cfg.proxyAdminOwner` at the very end of stage 5.
// =============================================================================

import { RSKOPCMSplitterBase } from "./RSKOPCMSplitterBase.sol";

import { Blueprint } from "src/libraries/Blueprint.sol";
import { Constants } from "src/libraries/Constants.sol";

import { IAddressManager } from "interfaces/legacy/IAddressManager.sol";
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";
import { IOptimismPortal2 as IOptimismPortal } from "interfaces/L1/IOptimismPortal2.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IOptimismMintableERC20Factory } from "interfaces/universal/IOptimismMintableERC20Factory.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IDelayedWETH } from "interfaces/dispute/IDelayedWETH.sol";
import { IOPContractsManagerContainer } from "interfaces/L1/opcm/IOPContractsManagerContainer.sol";
import { IOPContractsManagerUtils } from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import { IOPContractsManagerV2 } from "interfaces/L1/opcm/IOPContractsManagerV2.sol";

contract RSKOPCMSplitter is RSKOPCMSplitterBase {
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

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error RSKOPCMSplitter_NotDeployer();
    error RSKOPCMSplitter_AlreadySealed();
    error RSKOPCMSplitter_AlreadyStarted();
    error RSKOPCMSplitter_NotStarted();
    error RSKOPCMSplitter_ConfigMismatch();
    error RSKOPCMSplitter_ContractsMismatch();

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    /// @notice The operator EOA that constructed this splitter. Only this
    ///         account may drive the stage methods.
    address public immutable deployer;

    // -----------------------------------------------------------------------
    // Per-session state
    // -----------------------------------------------------------------------

    /// @notice Phase tracker:
    ///   0 = not started
    ///   1 = step1a done (core proxies), step1b next
    ///   2 = step1b done, step2 next
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

    /// @notice True once step 1a starts an initial deployment (gates the
    ///         terminal ownership transfers in step5). This contract only
    ///         deploys, so it is never false after step 1a.
    bool public isInitialDeployment;

    /// @notice keccak256 of the `FullConfig` passed to step 1a. Every later
    ///         stage must pass the same config.
    bytes32 public cfgHash;

    /// @notice keccak256 of the contracts the next stage must get: the
    ///         `ChainContractsCore` step 1a returned, then, from step 1b on,
    ///         the `ChainContracts` step 1b returned.
    bytes32 public ctsHash;

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// @param _opcmV2 The deployed OPCMv2, which must be `MIRRORED_OPCM_VERSION`
    ///                (checked by RSKOPCMSplitterBase).
    constructor(IOPContractsManagerV2 _opcmV2) RSKOPCMSplitterBase(_opcmV2) {
        deployer = msg.sender;
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

    /// @dev Reverts unless `_cfg` is the config step 1a pinned.
    function _checkConfig(FullConfig memory _cfg) internal view {
        if (keccak256(abi.encode(_cfg)) != cfgHash) revert RSKOPCMSplitter_ConfigMismatch();
    }

    /// @dev Reverts unless `_encodedContracts` are the contracts the previous
    ///      stage pinned.
    function _checkContracts(bytes memory _encodedContracts) internal view {
        if (keccak256(_encodedContracts) != ctsHash) revert RSKOPCMSplitter_ContractsMismatch();
    }

    /// @dev Reverts unless `_cfg` is the config step 1a pinned and `_cts` the
    ///      contracts step 1b returned.
    function _checkInputs(FullConfig memory _cfg, ChainContracts memory _cts) internal view {
        _checkConfig(_cfg);
        _checkContracts(abi.encode(_cts));
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

        // Run step 2's checks before pinning: once pinned, a config step 2
        // rejects could not be replaced and the proxies would be stranded.
        _assertValidFullConfig(_cfg, true);
        _assertSuperchainConfigUpToDate(_cfg.superchainConfig, implementations().superchainConfigImpl);
        isInitialDeployment = true;
        cfgHash = keccak256(abi.encode(_cfg));

        // Mirror OPCMv2.deploy lines 207-220 (saltMixer + ALL-permit).
        string memory saltMixer = string(bytes.concat(bytes20(deployer), bytes(_cfg.saltMixer)));
        IOPContractsManagerUtils.ExtraInstruction[] memory instructions =
            new IOPContractsManagerUtils.ExtraInstruction[](1);
        instructions[0] = IOPContractsManagerUtils.ExtraInstruction({
            key: Constants.PERMITTED_PROXY_DEPLOYMENT_KEY,
            data: Constants.PERMIT_ALL_CONTRACTS_INSTRUCTION
        });

        core = _loadCoreProxies(_cfg.l2ChainId, saltMixer, instructions);
        ctsHash = keccak256(abi.encode(core));
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
        _checkConfig(_cfg);
        _checkContracts(abi.encode(_core));

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
        ctsHash = keccak256(abi.encode(cts));
        phase = 2;
        return cts;
    }

    /// @notice Stage 2: SystemConfig + Portal + ETHLockbox + liquidity
    ///         migration. Mirror of `OPCMv2._apply` lines 818-904.
    function step2_systemConfigAndPortal(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 2) revert RSKOPCMSplitter_NotStarted();
        _checkInputs(_cfg, _cts);

        // Lines 818-827. Step 1a already ran these checks on the pinned
        // config. Lines 829-836 (the upgrade-sequence check) only run on
        // upgrades, which RSKOPCMSplitterUpgrade does.
        _assertValidFullConfig(_cfg, isInitialDeployment);

        // Lines 821-822
        IOPContractsManagerContainer.Implementations memory impls = implementations();

        // Lines 824-827
        _assertSuperchainConfigUpToDate(_cfg.superchainConfig, impls.superchainConfigImpl);

        // Lines 838-904.
        _applySystemConfigAndPortal(_cfg, _cts, impls, isInitialDeployment);

        phase = 3;
    }

    /// @notice Stage 3: LCDM + bridges + OptimismMintableERC20Factory. Mirror
    ///         of `OPCMv2._apply` lines 906-939.
    function step3_messengerAndBridges(FullConfig memory _cfg, ChainContracts memory _cts)
        external
        onlyDeployer
    {
        if (phase != 3) revert RSKOPCMSplitter_NotStarted();
        _checkInputs(_cfg, _cts);

        _applyMessengerAndBridges(_cts, implementations());

        phase = 4;
    }

    /// @notice Stage 4a: DisputeGameFactory + DelayedWETH. Mirror of
    ///         `OPCMv2._apply` lines 941-955 — first half of stage 4.
    function step4a_disputeFactoryAndWeth(FullConfig memory _cfg, ChainContracts memory _cts)
        external
        onlyDeployer
    {
        if (phase != 4) revert RSKOPCMSplitter_NotStarted();
        _checkInputs(_cfg, _cts);

        _applyDisputeFactoryAndWeth(_cts, implementations());

        phase = 5;
    }

    /// @notice Stage 4b: AnchorStateRegistry + dispute-game config loop +
    ///         SUPER_CANNON clear + custom gas token branch. Mirror of
    ///         `OPCMv2._apply` lines 957-1018 — second half of stage 4.
    function step4b_anchorAndGames(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 5) revert RSKOPCMSplitter_NotStarted();
        _checkInputs(_cfg, _cts);

        _applyAnchorAndGames(_cfg, _cts, implementations(), isInitialDeployment);

        phase = 6;
    }

    /// @notice Stage 5: terminal ownership transfers (initial deploy only).
    ///         Mirror of `OPCMv2._apply` lines 1019-1032. Seals the splitter.
    function step5_finalize(FullConfig memory _cfg, ChainContracts memory _cts) external onlyDeployer {
        if (phase != 6) revert RSKOPCMSplitter_NotStarted();
        _checkInputs(_cfg, _cts);

        // Lines 1019-1032 (upstream's `if (_isInitialDeployment) { ... }`).
        if (isInitialDeployment) {
            _cts.disputeGameFactory.transferOwnership(_cfg.proxyAdminOwner);
            _cts.proxyAdmin.transferOwnership(_cfg.proxyAdminOwner);
        }

        phase = 255; // seal
    }

    // =======================================================================
    // PRIVATE HELPERS — the initial-deployment proxy loaders. Everything else
    // (`_upgrade`, `_loadOrDeployProxy`, `_encodeSystemConfigInit`, etc.) is
    // inherited from OPContractsManagerUtilsCaller, and the `_apply` slices
    // and `_assertValidFullConfig` from RSKOPCMSplitterBase.
    // =======================================================================

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
}
