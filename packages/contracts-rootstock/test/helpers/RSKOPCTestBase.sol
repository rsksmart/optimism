// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";

import {DeployImplementations} from "scripts/deploy/DeployImplementations.s.sol";
import {DeploySuperchain} from "scripts/deploy/DeploySuperchain.s.sol";
import {StandardConstants} from "scripts/deploy/StandardConstants.sol";
import {Types} from "scripts/libraries/Types.sol";
import {Constants as ScriptConstants} from "scripts/libraries/Constants.sol";

import {Constants} from "src/libraries/Constants.sol";
import {Claim, Duration, GameType, GameTypes} from "src/dispute/lib/Types.sol";

import {IOPContractsManagerUtils} from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import {ISuperchainConfig} from "interfaces/L1/ISuperchainConfig.sol";

import {RSKOPCMSplitter} from "../../contracts/RSKOPCMSplitter.sol";

// LOAD-BEARING ARTIFACT IMPORTS: Bedrock deploy scripts load these concrete
// sources by artifact name through DeployUtils.getCode/vm.getCode. Keep every
// import in this block even when Solidity reports it as statically unused;
// removing one drops the artifact needed by the shared fixture. This keeps
// the out-of-tree package working without a broad test remapping.
import {AddressManager} from "src/legacy/AddressManager.sol";
import {L1ChugSplashProxy} from "src/legacy/L1ChugSplashProxy.sol";
import {ResolvedDelegateProxy} from "src/legacy/ResolvedDelegateProxy.sol";
import {Proxy} from "src/universal/Proxy.sol";
import {ProxyAdmin} from "src/universal/ProxyAdmin.sol";
import {SuperchainConfig} from "src/L1/SuperchainConfig.sol";
import {ProtocolVersions} from "src/L1/ProtocolVersions.sol";
import {SystemConfig} from "src/L1/SystemConfig.sol";
import {L1CrossDomainMessenger} from "src/L1/L1CrossDomainMessenger.sol";
import {L1ERC721Bridge} from "src/L1/L1ERC721Bridge.sol";
import {L1StandardBridge} from "src/L1/L1StandardBridge.sol";
import {OptimismMintableERC20Factory} from "src/universal/OptimismMintableERC20Factory.sol";
import {OptimismPortal2} from "src/L1/OptimismPortal2.sol";
import {ETHLockbox} from "src/L1/ETHLockbox.sol";
import {DelayedWETH} from "src/dispute/DelayedWETH.sol";
import {PreimageOracle} from "src/cannon/PreimageOracle.sol";
import {MIPS64} from "src/cannon/MIPS64.sol";
import {DisputeGameFactory} from "src/dispute/DisputeGameFactory.sol";
import {AnchorStateRegistry} from "src/dispute/AnchorStateRegistry.sol";
import {FaultDisputeGame} from "src/dispute/FaultDisputeGame.sol";
import {PermissionedDisputeGame} from "src/dispute/PermissionedDisputeGame.sol";
import {SuperFaultDisputeGame} from "src/dispute/SuperFaultDisputeGame.sol";
import {SuperPermissionedDisputeGame} from "src/dispute/SuperPermissionedDisputeGame.sol";
import {ZKDisputeGame} from "src/dispute/zk/ZKDisputeGame.sol";
import {StorageSetter} from "src/universal/StorageSetter.sol";
import {OPContractsManagerContainer} from "src/L1/opcm/OPContractsManagerContainer.sol";
import {OPContractsManagerStandardValidator} from "src/L1/OPContractsManagerStandardValidator.sol";
import {OPContractsManagerUtils} from "src/L1/opcm/OPContractsManagerUtils.sol";
import {OPContractsManagerMigrator} from "src/L1/opcm/OPContractsManagerMigrator.sol";
import {OPContractsManagerV2} from "src/L1/opcm/OPContractsManagerV2.sol";
import {OPContractsManagerMigrationValidator} from "src/L1/opcm/OPContractsManagerMigrationValidator.sol";

/// @notice Shared, deterministic OPCMv2 fixture for the Rootstock-only tests.
/// @dev This intentionally follows the existing Bedrock deployment scripts and
///      keeps the six game-type configuration local to the test package.
abstract contract RSKOPCTestBase is Test {
    DeploySuperchain internal deploySuperchain;
    DeployImplementations internal deployImplementations;
    DeployImplementations.Output internal implementationsOutput;

    RSKOPCMSplitter internal splitter;
    RSKOPCMSplitter.FullConfig internal fullConfig;
    RSKOPCMSplitter.ChainContractsCore internal core;
    RSKOPCMSplitter.ChainContracts internal chainContracts;

    Types.DeployOPChainInput internal deployInput;
    ISuperchainConfig internal superchainConfig;

    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");
    address internal systemConfigOwner = makeAddr("systemConfigOwner");
    address internal batcher = makeAddr("batcher");
    address internal unsafeBlockSigner = makeAddr("unsafeBlockSigner");
    address internal proposer = makeAddr("proposer");
    address internal challenger = makeAddr("challenger");

    uint256 internal constant L2_CHAIN_ID = 300;
    uint32 internal constant BASEFEE_SCALAR = 100;
    uint32 internal constant BLOB_BASEFEE_SCALAR = 200;
    uint64 internal constant GAS_LIMIT = 60_000_000;
    uint256 internal constant DISPUTE_MAX_GAME_DEPTH = 73;
    uint256 internal constant DISPUTE_SPLIT_DEPTH = 30;
    uint256 internal constant DEFAULT_INIT_BOND = 0.08 ether;

    Claim internal absolutePrestate = Claim.wrap(0x038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c);
    Duration internal clockExtension = Duration.wrap(3 hours);
    Duration internal maxClockDuration = Duration.wrap(3.5 days);

    function setUp() public virtual {
        // Pin the init-bond env override to the decimal encoding of
        // DEFAULT_INIT_BOND so every suite sees deterministic behaviour even
        // when the developer's shell carries an ambient value (forge has no
        // vm.unsetEnv, so "pin to default" is the closest thing to clearing
        // it). Tests that exercise the override itself live in
        // RSKDeployOPChainBondEnv.t.sol and avoid vm.setEnv around deploys —
        // forge runs tests in parallel and the env is process-global.
        vm.setEnv("RSK_DISPUTE_GAME_INIT_BOND_WEI", "80000000000000000");

        deploySuperchain = new DeploySuperchain();
        deployImplementations = new DeployImplementations();

        DeploySuperchain.Output memory superchain = deploySuperchain.run(
            DeploySuperchain.Input({
                guardian: makeAddr("guardian"),
                protocolVersionsOwner: makeAddr("protocolVersionsOwner"),
                superchainProxyAdminOwner: makeAddr("superchainProxyAdminOwner"),
                paused: false,
                recommendedProtocolVersion: bytes32(uint256(2)),
                requiredProtocolVersion: bytes32(uint256(1))
            })
        );
        superchainConfig = superchain.superchainConfigProxy;

        implementationsOutput = deployImplementations.run(
            DeployImplementations.Input({
                withdrawalDelaySeconds: 100,
                minProposalSizeBytes: 200,
                challengePeriodSeconds: 300,
                proofMaturityDelaySeconds: 400,
                disputeGameFinalityDelaySeconds: 500,
                mipsVersion: StandardConstants.MIPS_VERSION,
                devFeatureBitmap: bytes32(0),
                faultGameV2MaxGameDepth: DISPUTE_MAX_GAME_DEPTH,
                faultGameV2SplitDepth: DISPUTE_SPLIT_DEPTH,
                faultGameV2ClockExtension: 10800,
                faultGameV2MaxClockDuration: 302400,
                superchainConfigProxy: superchain.superchainConfigProxy,
                protocolVersionsProxy: superchain.protocolVersionsProxy,
                superchainProxyAdmin: superchain.superchainProxyAdmin,
                l1ProxyAdminOwner: makeAddr("superchainProxyAdminOwner"),
                challenger: challenger
            })
        );

        _initializeFullConfig();
        splitter = new RSKOPCMSplitter(
            implementationsOutput.opcmUtils,
            implementationsOutput.opcmContainer,
            implementationsOutput.opcmStandardValidator,
            implementationsOutput.opcmMigrator
        );

        deployInput = _defaultDeployInput();
    }

    function _initializeFullConfig() internal {
        fullConfig.saltMixer = "saltMixer";
        fullConfig.superchainConfig = superchainConfig;
        fullConfig.proxyAdminOwner = proxyAdminOwner;
        fullConfig.systemConfigOwner = systemConfigOwner;
        fullConfig.unsafeBlockSigner = unsafeBlockSigner;
        fullConfig.batcher = batcher;
        fullConfig.startingAnchorRoot = ScriptConstants.DEFAULT_OUTPUT_ROOT();
        fullConfig.startingRespectedGameType = GameTypes.PERMISSIONED_CANNON;
        fullConfig.basefeeScalar = BASEFEE_SCALAR;
        fullConfig.blobBasefeeScalar = BLOB_BASEFEE_SCALAR;
        fullConfig.gasLimit = GAS_LIMIT;
        fullConfig.l2ChainId = L2_CHAIN_ID;
        fullConfig.resourceConfig = Constants.DEFAULT_RESOURCE_CONFIG();
        fullConfig.useCustomGasToken = false;

        delete fullConfig.disputeGameConfigs;
        _pushGameConfig(false, 0, GameTypes.CANNON, bytes(""));
        _pushGameConfig(
            true,
            DEFAULT_INIT_BOND,
            GameTypes.PERMISSIONED_CANNON,
            abi.encode(
                IOPContractsManagerUtils.PermissionedDisputeGameConfig({
                    absolutePrestate: absolutePrestate,
                    proposer: proposer,
                    challenger: challenger
                })
            )
        );
        _pushGameConfig(false, 0, GameTypes.CANNON_KONA, bytes(""));
        _pushGameConfig(false, 0, GameTypes.SUPER_CANNON, bytes(""));
        _pushGameConfig(false, 0, GameTypes.SUPER_PERMISSIONED_CANNON, bytes(""));
        _pushGameConfig(false, 0, GameTypes.SUPER_CANNON_KONA, bytes(""));
    }

    function _pushGameConfig(bool enabled_, uint256 bond_, GameType gameType_, bytes memory args_) internal {
        fullConfig.disputeGameConfigs.push();
        uint256 index = fullConfig.disputeGameConfigs.length - 1;
        fullConfig.disputeGameConfigs[index].enabled = enabled_;
        fullConfig.disputeGameConfigs[index].initBond = bond_;
        fullConfig.disputeGameConfigs[index].gameType = gameType_;
        fullConfig.disputeGameConfigs[index].gameArgs = args_;
    }

    function _defaultDeployInput() internal view returns (Types.DeployOPChainInput memory input_) {
        input_ = Types.DeployOPChainInput({
            opChainProxyAdminOwner: proxyAdminOwner,
            systemConfigOwner: systemConfigOwner,
            batcher: batcher,
            unsafeBlockSigner: unsafeBlockSigner,
            proposer: proposer,
            challenger: challenger,
            basefeeScalar: BASEFEE_SCALAR,
            blobBaseFeeScalar: BLOB_BASEFEE_SCALAR,
            l2ChainId: L2_CHAIN_ID,
            opcm: address(implementationsOutput.opcmV2),
            saltMixer: "saltMixer",
            gasLimit: GAS_LIMIT,
            disputeGameType: GameTypes.PERMISSIONED_CANNON,
            disputeAbsolutePrestate: absolutePrestate,
            disputeMaxGameDepth: DISPUTE_MAX_GAME_DEPTH,
            disputeSplitDepth: DISPUTE_SPLIT_DEPTH,
            disputeClockExtension: clockExtension,
            disputeMaxClockDuration: maxClockDuration,
            allowCustomDisputeParameters: false,
            operatorFeeScalar: 0,
            operatorFeeConstant: 0,
            superchainConfig: superchainConfig,
            useCustomGasToken: false
        });
    }

    function _startAtStep2() internal {
        core = splitter.deployStep1a_coreProxies(fullConfig);
        chainContracts = splitter.deployStep1b_remainingProxies(fullConfig, core);
    }

    function _runSplitter() internal returns (RSKOPCMSplitter.ChainContracts memory cts_) {
        core = splitter.deployStep1a_coreProxies(fullConfig);
        cts_ = splitter.deployStep1b_remainingProxies(fullConfig, core);
        splitter.step2_systemConfigAndPortal(fullConfig, cts_);
        splitter.step3_messengerAndBridges(fullConfig, cts_);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, cts_);
        splitter.step4b_anchorAndGames(fullConfig, cts_);
        splitter.step5_finalize(fullConfig, cts_);
    }
}
