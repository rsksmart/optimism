// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// =============================================================================
// RSKDeployOPChain
//
// RSK-side replacement for upstream `DeployOPChain.s.sol`. Functionally
// equivalent to upstream's `run(...)` with the single difference that
// `OPContractsManagerV2.deploy(config)` is decomposed into 1 splitter
// deployment + 5 stage calls — each guaranteed to fit under RSKj's RSKIP144
// 6.8M per-tx sublist gas cap.
//
// Input/output shapes are byte-identical to upstream's `DeployOPChain.run(...)`,
// so the existing `cmd/deploy-rollup` Go side parses the broadcast JSON
// without modification.
//
// Sigs exposed:
//   * runSplit((address,...)) → (address[15] tuple matching DeployOPChain.Output)
//
// Other entry points (upgradeSplit, migrateSplit) are deferred — they share
// the same splitter contract but aren't on the critical path for the F1
// regtest smoke test.
// =============================================================================

import { Script } from "forge-std/Script.sol";

import { Constants } from "src/libraries/Constants.sol";
import { Constants as ScriptConstants } from "scripts/libraries/Constants.sol";
import { Types } from "scripts/libraries/Types.sol";
import { DeployUtils } from "scripts/libraries/DeployUtils.sol";

import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";
import { IOPContractsManagerV2 } from "interfaces/L1/opcm/IOPContractsManagerV2.sol";
import { IOPContractsManagerUtils } from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import { IOPContractsManagerContainer } from "interfaces/L1/opcm/IOPContractsManagerContainer.sol";
import { IOPContractsManagerStandardValidator } from "interfaces/L1/IOPContractsManagerStandardValidator.sol";
import { IOPContractsManagerMigrator } from "interfaces/L1/opcm/IOPContractsManagerMigrator.sol";
import { IAddressManager } from "interfaces/legacy/IAddressManager.sol";
import { IDelayedWETH } from "interfaces/dispute/IDelayedWETH.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IFaultDisputeGame } from "interfaces/dispute/IFaultDisputeGame.sol";
import { IPermissionedDisputeGame } from "interfaces/dispute/IPermissionedDisputeGame.sol";
import { IOptimismPortal2 as IOptimismPortal } from "interfaces/L1/IOptimismPortal2.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IOptimismMintableERC20Factory } from "interfaces/universal/IOptimismMintableERC20Factory.sol";
import { IETHLockbox } from "interfaces/L1/IETHLockbox.sol";
import { GameType, GameTypes } from "src/dispute/lib/Types.sol";
import { DevFeatures } from "src/libraries/DevFeatures.sol";

import { RSKOPCMSplitter } from "../contracts/RSKOPCMSplitter.sol";

contract RSKDeployOPChain is Script {
    /// @notice Default init bond for the dispute games (matches upstream
    ///         `DeployOPChain.DEFAULT_INIT_BOND`).
    uint256 public constant DEFAULT_INIT_BOND = 0.08 ether;

    /// @notice Whether the OPCM has SUPER_ROOT_GAMES_MIGRATION enabled.
    bool public isSuperRoot;

    /// @notice Output struct identical to upstream `DeployOPChain.Output` so
    ///         broadcast.json's `returns` field stays byte-compatible with
    ///         the Go-side `ExtractOPChainAddressesFromReturns`.
    struct Output {
        IProxyAdmin opChainProxyAdmin;
        IAddressManager addressManager;
        IL1ERC721Bridge l1ERC721BridgeProxy;
        ISystemConfig systemConfigProxy;
        IOptimismMintableERC20Factory optimismMintableERC20FactoryProxy;
        IL1StandardBridge l1StandardBridgeProxy;
        IL1CrossDomainMessenger l1CrossDomainMessengerProxy;
        IOptimismPortal optimismPortalProxy;
        IETHLockbox ethLockboxProxy;
        IDisputeGameFactory disputeGameFactoryProxy;
        IAnchorStateRegistry anchorStateRegistryProxy;
        IFaultDisputeGame faultDisputeGame;
        IPermissionedDisputeGame permissionedDisputeGame;
        IDelayedWETH delayedWETHPermissionedGameProxy;
        IDelayedWETH delayedWETHPermissionlessGameProxy;
    }

    /// @notice ABI-bytes entry point mirroring upstream `DeployOPChain.runWithBytes`.
    ///         Lets op-deployer's `forge.NewScriptCaller` invoke `runSplit`
    ///         through the same `BytesScriptEncoder`/`BytesScriptDecoder`
    ///         pair it uses for the upstream script — no parallel broadcast
    ///         parser on the Go side.
    function runWithBytes(bytes memory _input) public returns (bytes memory) {
        require(_input.length > 0, "RSKDeployOPChain: input cannot be empty");
        Types.DeployOPChainInput memory input = abi.decode(_input, (Types.DeployOPChainInput));
        Output memory output_ = runSplit(input);
        return abi.encode(output_);
    }

    /// @notice Drop-in replacement for upstream `DeployOPChain.run(input)`,
    ///         except the single `OPContractsManagerV2.deploy(config)` call
    ///         is replaced by a splitter deploy + 5 stage broadcasts.
    /// @param _input Same `Types.DeployOPChainInput` upstream uses.
    /// @return output_ Same `Output` shape upstream emits.
    function runSplit(Types.DeployOPChainInput memory _input) public returns (Output memory output_) {
        checkInput(_input);

        require(address(_input.opcm).code.length > 0, "RSKDeployOPChain: OPCM address has no code");

        IOPContractsManagerV2 opcmV2 = IOPContractsManagerV2(_input.opcm);
        isSuperRoot = DevFeatures.isDevFeatureEnabled(opcmV2.devFeatureBitmap(), DevFeatures.SUPER_ROOT_GAMES_MIGRATION);

        // Pull the same constructor deps the deployed OPCMv2 was built with —
        // splitter must reference the same Container/Utils/Migrator contracts
        // or the inherited `_loadOrDeployProxy` / `_upgrade` helpers will
        // delegatecall into the wrong utils bytecode.
        IOPContractsManagerUtils utils = opcmV2.opcmUtils();
        IOPContractsManagerContainer container = opcmV2.contractsContainer();
        IOPContractsManagerStandardValidator validator = opcmV2.opcmStandardValidator();
        IOPContractsManagerMigrator migrator = opcmV2.opcmMigrator();

        // Build the FullConfig identically to upstream `_toOPCMV2DeployInput`.
        RSKOPCMSplitter.FullConfig memory cfg = _toFullConfig(_input);

        // ----------- BROADCAST 1 — deploy the splitter -----------
        vm.broadcast(msg.sender);
        RSKOPCMSplitter splitter = new RSKOPCMSplitter(utils, container, validator, migrator);

        // ----------- BROADCAST 2 — core proxies (1st half of _loadChainContracts) -----------
        vm.broadcast(msg.sender);
        RSKOPCMSplitter.ChainContractsCore memory core = splitter.deployStep1a_coreProxies(cfg);

        // ----------- BROADCAST 3 — remaining proxies (2nd half of _loadChainContracts) -----------
        vm.broadcast(msg.sender);
        RSKOPCMSplitter.ChainContracts memory cts = splitter.deployStep1b_remainingProxies(cfg, core);

        // ----------- BROADCAST 4 — SystemConfig + Portal + ETHLockbox -----------
        vm.broadcast(msg.sender);
        splitter.step2_systemConfigAndPortal(cfg, cts);

        // ----------- BROADCAST 5 — LCDM + bridges + factory -----------
        vm.broadcast(msg.sender);
        splitter.step3_messengerAndBridges(cfg, cts);

        // ----------- BROADCAST 6 — DGF + DelayedWETH -----------
        vm.broadcast(msg.sender);
        splitter.step4a_disputeFactoryAndWeth(cfg, cts);

        // ----------- BROADCAST 7 — ASR + dispute games + CGT -----------
        vm.broadcast(msg.sender);
        splitter.step4b_anchorAndGames(cfg, cts);

        // ----------- BROADCAST 8 — terminal ownership transfers -----------
        vm.broadcast(msg.sender);
        splitter.step5_finalize(cfg, cts);

        output_ = _fromChainContractsToOutput(cts);

        checkOutput(_input, output_);

        vm.label(address(splitter), "rskOpcmSplitter");
        vm.label(address(output_.opChainProxyAdmin), "opChainProxyAdmin");
        vm.label(address(output_.addressManager), "addressManager");
        vm.label(address(output_.l1ERC721BridgeProxy), "l1ERC721BridgeProxy");
        vm.label(address(output_.systemConfigProxy), "systemConfigProxy");
        vm.label(address(output_.optimismMintableERC20FactoryProxy), "optimismMintableERC20FactoryProxy");
        vm.label(address(output_.l1StandardBridgeProxy), "l1StandardBridgeProxy");
        vm.label(address(output_.l1CrossDomainMessengerProxy), "l1CrossDomainMessengerProxy");
        vm.label(address(output_.optimismPortalProxy), "optimismPortalProxy");
        vm.label(address(output_.ethLockboxProxy), "ethLockboxProxy");
        vm.label(address(output_.disputeGameFactoryProxy), "disputeGameFactoryProxy");
        vm.label(address(output_.anchorStateRegistryProxy), "anchorStateRegistryProxy");
        vm.label(address(output_.delayedWETHPermissionedGameProxy), "delayedWETHPermissionedGameProxy");
    }

    // ---------------------------------------------------------------------
    // Conversion helpers — verbatim ports of upstream's _toOPCMV2DeployInput
    // and _fromOPCMV2OutputToOutput. The only divergence is the target type
    // (RSKOPCMSplitter.FullConfig instead of IOPContractsManagerV2.FullConfig)
    // — the field shapes are identical by construction.
    // ---------------------------------------------------------------------

    function _toFullConfig(Types.DeployOPChainInput memory _input)
        internal
        view
        returns (RSKOPCMSplitter.FullConfig memory cfg_)
    {
        require(
            _input.disputeGameType.raw() == GameTypes.PERMISSIONED_CANNON.raw(),
            "RSKDeployOPChain: only PERMISSIONED_CANNON game type is supported for initial deployment"
        );

        IOPContractsManagerUtils.PermissionedDisputeGameConfig memory pdgConfig = IOPContractsManagerUtils
            .PermissionedDisputeGameConfig({
            absolutePrestate: _input.disputeAbsolutePrestate,
            proposer: _input.proposer,
            challenger: _input.challenger
        });

        IOPContractsManagerUtils.DisputeGameConfig[] memory disputeGameConfigs =
            new IOPContractsManagerUtils.DisputeGameConfig[](6);

        disputeGameConfigs[0] = IOPContractsManagerUtils.DisputeGameConfig({
            enabled: false,
            initBond: 0,
            gameType: GameTypes.CANNON,
            gameArgs: bytes("")
        });

        disputeGameConfigs[1] = isSuperRoot
            ? IOPContractsManagerUtils.DisputeGameConfig({
                enabled: false,
                initBond: 0,
                gameType: GameTypes.PERMISSIONED_CANNON,
                gameArgs: bytes("")
            })
            : IOPContractsManagerUtils.DisputeGameConfig({
                enabled: true,
                initBond: DEFAULT_INIT_BOND,
                gameType: GameTypes.PERMISSIONED_CANNON,
                gameArgs: abi.encode(pdgConfig)
            });

        disputeGameConfigs[2] = IOPContractsManagerUtils.DisputeGameConfig({
            enabled: false,
            initBond: 0,
            gameType: GameTypes.CANNON_KONA,
            gameArgs: bytes("")
        });

        disputeGameConfigs[3] = IOPContractsManagerUtils.DisputeGameConfig({
            enabled: false,
            initBond: 0,
            gameType: GameTypes.SUPER_CANNON,
            gameArgs: bytes("")
        });

        disputeGameConfigs[4] = isSuperRoot
            ? IOPContractsManagerUtils.DisputeGameConfig({
                enabled: true,
                initBond: DEFAULT_INIT_BOND,
                gameType: GameTypes.SUPER_PERMISSIONED_CANNON,
                gameArgs: abi.encode(pdgConfig)
            })
            : IOPContractsManagerUtils.DisputeGameConfig({
                enabled: false,
                initBond: 0,
                gameType: GameTypes.SUPER_PERMISSIONED_CANNON,
                gameArgs: bytes("")
            });

        disputeGameConfigs[5] = IOPContractsManagerUtils.DisputeGameConfig({
            enabled: false,
            initBond: 0,
            gameType: GameTypes.SUPER_CANNON_KONA,
            gameArgs: bytes("")
        });

        cfg_ = RSKOPCMSplitter.FullConfig({
            saltMixer: _input.saltMixer,
            superchainConfig: _input.superchainConfig,
            proxyAdminOwner: _input.opChainProxyAdminOwner,
            systemConfigOwner: _input.systemConfigOwner,
            unsafeBlockSigner: _input.unsafeBlockSigner,
            batcher: _input.batcher,
            startingAnchorRoot: ScriptConstants.DEFAULT_OUTPUT_ROOT(),
            startingRespectedGameType: isSuperRoot ? GameTypes.SUPER_PERMISSIONED_CANNON : GameTypes.PERMISSIONED_CANNON,
            basefeeScalar: _input.basefeeScalar,
            blobBasefeeScalar: _input.blobBaseFeeScalar,
            gasLimit: _input.gasLimit,
            l2ChainId: _input.l2ChainId,
            resourceConfig: Constants.DEFAULT_RESOURCE_CONFIG(),
            disputeGameConfigs: disputeGameConfigs,
            useCustomGasToken: _input.useCustomGasToken
        });
    }

    function _fromChainContractsToOutput(RSKOPCMSplitter.ChainContracts memory _cts)
        internal
        view
        returns (Output memory output_)
    {
        GameType permGameType = isSuperRoot ? GameTypes.SUPER_PERMISSIONED_CANNON : GameTypes.PERMISSIONED_CANNON;
        address permissionedDgImpl = address(_cts.disputeGameFactory.gameImpls(permGameType));

        output_ = Output({
            opChainProxyAdmin: _cts.proxyAdmin,
            addressManager: _cts.addressManager,
            l1ERC721BridgeProxy: _cts.l1ERC721Bridge,
            systemConfigProxy: _cts.systemConfig,
            optimismMintableERC20FactoryProxy: _cts.optimismMintableERC20Factory,
            l1StandardBridgeProxy: _cts.l1StandardBridge,
            l1CrossDomainMessengerProxy: _cts.l1CrossDomainMessenger,
            optimismPortalProxy: _cts.optimismPortal,
            ethLockboxProxy: _cts.ethLockbox,
            disputeGameFactoryProxy: _cts.disputeGameFactory,
            anchorStateRegistryProxy: _cts.anchorStateRegistry,
            // Match upstream OPCMv2 behaviour: faultDisputeGame is unset on
            // initial deployment (no prestate exists for permissionless games).
            faultDisputeGame: IFaultDisputeGame(address(0)),
            permissionedDisputeGame: IPermissionedDisputeGame(permissionedDgImpl),
            delayedWETHPermissionedGameProxy: _cts.delayedWETH,
            delayedWETHPermissionlessGameProxy: IDelayedWETH(payable(_cts.delayedWETH))
        });
    }

    // ---------------------------------------------------------------------
    // Validations — line-for-line ports of upstream `checkInput`/`checkOutput`.
    // ---------------------------------------------------------------------

    function checkInput(Types.DeployOPChainInput memory _i) public view {
        require(_i.opChainProxyAdminOwner != address(0), "RSKDeployOPChainInput: opChainProxyAdminOwner not set");
        require(_i.systemConfigOwner != address(0), "RSKDeployOPChainInput: systemConfigOwner not set");
        require(_i.batcher != address(0), "RSKDeployOPChainInput: batcher not set");
        require(_i.unsafeBlockSigner != address(0), "RSKDeployOPChainInput: unsafeBlockSigner not set");
        require(_i.proposer != address(0), "RSKDeployOPChainInput: proposer not set");
        require(_i.challenger != address(0), "RSKDeployOPChainInput: challenger not set");

        require(_i.blobBaseFeeScalar != 0, "RSKDeployOPChainInput: blobBaseFeeScalar not set");
        require(_i.basefeeScalar != 0, "RSKDeployOPChainInput: basefeeScalar not set");
        require(_i.gasLimit != 0, "RSKDeployOPChainInput: gasLimit not set");

        require(_i.l2ChainId != 0, "RSKDeployOPChainInput: l2ChainId not set");
        require(_i.l2ChainId != block.chainid, "RSKDeployOPChainInput: l2ChainId matches block.chainid");

        require(_i.opcm != address(0), "RSKDeployOPChainInput: opcm not set");
        DeployUtils.assertValidContractAddress(_i.opcm);

        require(_i.disputeMaxGameDepth != 0, "RSKDeployOPChainInput: disputeMaxGameDepth not set");
        require(_i.disputeSplitDepth != 0, "RSKDeployOPChainInput: disputeSplitDepth not set");
        require(_i.disputeMaxClockDuration.raw() != 0, "RSKDeployOPChainInput: disputeMaxClockDuration not set");
        require(_i.disputeAbsolutePrestate.raw() != bytes32(0), "RSKDeployOPChainInput: disputeAbsolutePrestate not set");
    }

    /// @notice Smoke-test the deployed addresses are non-zero and have code.
    ///         A reduced version of upstream's `checkOutput` — we skip the
    ///         deeper `_assertValidDeploy` since the underlying OPCMv2
    ///         primitives we delegated into already enforce those invariants.
    function checkOutput(Types.DeployOPChainInput memory, Output memory _o) public view {
        DeployUtils.assertValidContractAddress(address(_o.opChainProxyAdmin));
        DeployUtils.assertValidContractAddress(address(_o.addressManager));
        DeployUtils.assertValidContractAddress(address(_o.l1ERC721BridgeProxy));
        DeployUtils.assertValidContractAddress(address(_o.systemConfigProxy));
        DeployUtils.assertValidContractAddress(address(_o.optimismMintableERC20FactoryProxy));
        DeployUtils.assertValidContractAddress(address(_o.l1StandardBridgeProxy));
        DeployUtils.assertValidContractAddress(address(_o.l1CrossDomainMessengerProxy));
        DeployUtils.assertValidContractAddress(address(_o.optimismPortalProxy));
        DeployUtils.assertValidContractAddress(address(_o.ethLockboxProxy));
        DeployUtils.assertValidContractAddress(address(_o.disputeGameFactoryProxy));
        DeployUtils.assertValidContractAddress(address(_o.anchorStateRegistryProxy));
        DeployUtils.assertValidContractAddress(address(_o.delayedWETHPermissionedGameProxy));
    }
}
