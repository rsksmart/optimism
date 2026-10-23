// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IProxyAdmin} from "interfaces/universal/IProxyAdmin.sol";
import {ISystemConfig} from "interfaces/L1/ISystemConfig.sol";
import {IETHLockbox} from "interfaces/L1/IETHLockbox.sol";
import {IOptimismPortal2} from "interfaces/L1/IOptimismPortal2.sol";
import {IL1CrossDomainMessenger} from "interfaces/L1/IL1CrossDomainMessenger.sol";
import {IL1ERC721Bridge} from "interfaces/L1/IL1ERC721Bridge.sol";
import {IL1StandardBridge} from "interfaces/L1/IL1StandardBridge.sol";
import {IAnchorStateRegistry} from "interfaces/dispute/IAnchorStateRegistry.sol";
import {IDelayedWETH} from "interfaces/dispute/IDelayedWETH.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {IResourceMetering} from "interfaces/L1/IResourceMetering.sol";
import {Claim, Duration, GameType, GameTypes, Hash, Proposal} from "src/dispute/lib/Types.sol";
import {Constants} from "src/libraries/Constants.sol";
import {Features} from "src/libraries/Features.sol";

import {RSKDeployOPChain} from "../script/RSKDeployOPChain.s.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

contract RSKDeployOPChain_Test is RSKOPCTestBase {
    function test_checkInput_validFixture_succeeds() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        script.checkInput(deployInput);
    }

    function test_runSplit_succeedsAndPreservesOutputQuirks() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        _assertOutputSemantics(output_);
    }

    function test_runWithBytes_roundTripsFifteenFieldOutput() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        bytes memory encodedOutput = script.runWithBytes(abi.encode(deployInput));
        RSKDeployOPChain.Output memory output_ = abi.decode(encodedOutput, (RSKDeployOPChain.Output));

        _assertOutputSemantics(output_);
    }

    function test_runWithBytes_emptyInput_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        vm.expectRevert("RSKDeployOPChain: input cannot be empty");
        script.runWithBytes(bytes(""));
    }

    function test_runWithBytes_malformedInput_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        vm.expectRevert(bytes(""));
        script.runWithBytes(bytes("malformed"));
    }

    function test_checkInput_zeroRequiredFields_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();

        deployInput.opChainProxyAdminOwner = address(0);
        vm.expectRevert("RSKDeployOPChainInput: opChainProxyAdminOwner not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.systemConfigOwner = address(0);
        vm.expectRevert("RSKDeployOPChainInput: systemConfigOwner not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.batcher = address(0);
        vm.expectRevert("RSKDeployOPChainInput: batcher not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.unsafeBlockSigner = address(0);
        vm.expectRevert("RSKDeployOPChainInput: unsafeBlockSigner not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.proposer = address(0);
        vm.expectRevert("RSKDeployOPChainInput: proposer not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.challenger = address(0);
        vm.expectRevert("RSKDeployOPChainInput: challenger not set");
        script.checkInput(deployInput);
    }

    function test_checkInput_numericAndContractGuards_revert() public {
        RSKDeployOPChain script = new RSKDeployOPChain();

        deployInput.blobBaseFeeScalar = 0;
        vm.expectRevert("RSKDeployOPChainInput: blobBaseFeeScalar not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.basefeeScalar = 0;
        vm.expectRevert("RSKDeployOPChainInput: basefeeScalar not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.gasLimit = 0;
        vm.expectRevert("RSKDeployOPChainInput: gasLimit not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.l2ChainId = 0;
        vm.expectRevert("RSKDeployOPChainInput: l2ChainId not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.l2ChainId = block.chainid;
        vm.expectRevert("RSKDeployOPChainInput: l2ChainId matches block.chainid");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.opcm = address(0);
        vm.expectRevert("RSKDeployOPChainInput: opcm not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.opcm = makeAddr("opcmEoa");
        vm.expectRevert(bytes(string.concat("DeployUtils: no code at ", vm.toString(deployInput.opcm))));
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.disputeMaxGameDepth = 0;
        vm.expectRevert("RSKDeployOPChainInput: disputeMaxGameDepth not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.disputeSplitDepth = 0;
        vm.expectRevert("RSKDeployOPChainInput: disputeSplitDepth not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.disputeMaxClockDuration = Duration.wrap(0);
        vm.expectRevert("RSKDeployOPChainInput: disputeMaxClockDuration not set");
        script.checkInput(deployInput);

        deployInput = _defaultDeployInput();
        deployInput.disputeAbsolutePrestate = Claim.wrap(bytes32(0));
        vm.expectRevert("RSKDeployOPChainInput: disputeAbsolutePrestate not set");
        script.checkInput(deployInput);
    }

    /// @notice Ported from upstream's DeployOPChain tests (zero, max and above-max
    ///         starting anchor).
    function test_checkInput_zeroStartingAnchorRoot_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.startingAnchorRoot = Proposal({root: Hash.wrap(bytes32(0)), l2SequenceNumber: 0});
        vm.expectRevert("RSKDeployOPChainInput: startingAnchorRoot not set");
        script.checkInput(deployInput);
    }

    function test_checkInput_maxStartingAnchorRootSequenceNumber_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.startingAnchorRoot.l2SequenceNumber = type(uint64).max;
        vm.expectRevert("RSKDeployOPChainInput: startingAnchorRoot.l2SequenceNumber too large");
        script.checkInput(deployInput);
    }

    function test_checkInput_aboveMaxStartingAnchorRootSequenceNumber_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.startingAnchorRoot.l2SequenceNumber = uint256(type(uint64).max) + 1;
        vm.expectRevert("RSKDeployOPChainInput: startingAnchorRoot.l2SequenceNumber too large");
        script.checkInput(deployInput);
    }

    /// @notice The fixture's anchor is the 0xdead default with sequence 0, so
    ///         a deploy that ignored the input would still pass the other tests.
    function test_runSplit_customStartingAnchorRoot_succeeds() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.startingAnchorRoot = Proposal({root: Hash.wrap(keccak256("customAnchor")), l2SequenceNumber: 1234});

        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        Proposal memory stored =
            IAnchorStateRegistry(address(output_.anchorStateRegistryProxy)).getStartingAnchorRoot();
        assertEq(stored.root.raw(), keccak256("customAnchor"));
        assertEq(stored.l2SequenceNumber, 1234);
    }

    function test_runSplit_unsupportedGameType_revertsBeforeDeployment() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        GameType[4] memory unsupported =
            [GameTypes.CANNON, GameTypes.CANNON_KONA, GameTypes.SUPER_PERMISSIONED, GameTypes.SUPER_CANNON_KONA];

        for (uint256 i = 0; i < unsupported.length; i++) {
            deployInput.disputeGameType = unsupported[i];
            vm.expectRevert("RSKDeployOPChain: only PERMISSIONED_CANNON game type is supported for initial deployment");
            script.runSplit(deployInput);
        }
    }

    function _assertOutputSemantics(RSKDeployOPChain.Output memory output_) internal view {
        _assertOutputAddresses(output_);

        IProxyAdmin proxyAdmin_ = IProxyAdmin(address(output_.opChainProxyAdmin));
        ISystemConfig systemConfig_ = ISystemConfig(address(output_.systemConfigProxy));
        IOptimismPortal2 portal_ = IOptimismPortal2(payable(address(output_.optimismPortalProxy)));
        IL1CrossDomainMessenger messenger_ = IL1CrossDomainMessenger(address(output_.l1CrossDomainMessengerProxy));
        IDisputeGameFactory disputeGameFactory_ = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        IAnchorStateRegistry anchorStateRegistry_ = IAnchorStateRegistry(address(output_.anchorStateRegistryProxy));

        assertEq(proxyAdmin_.owner(), proxyAdminOwner);
        assertEq(address(proxyAdmin_.addressManager()), address(output_.addressManager));
        assertEq(systemConfig_.owner(), systemConfigOwner);
        assertEq(systemConfig_.l2ChainId(), L2_CHAIN_ID);
        assertEq(systemConfig_.optimismMintableERC20Factory(), address(output_.optimismMintableERC20FactoryProxy));
        assertEq(address(portal_.systemConfig()), address(systemConfig_));
        // OPCMv2 9.0.2: the ETHLockbox is mandatory, and DelayedWETH and the
        // AnchorStateRegistry read the pause state through it.
        IETHLockbox lockbox_ = IETHLockbox(address(output_.ethLockboxProxy));
        assertTrue(systemConfig_.isFeatureEnabled(Features.ETH_LOCKBOX));
        assertEq(address(portal_.ethLockbox()), address(lockbox_));
        assertTrue(lockbox_.authorizedPortals(portal_));
        assertEq(address(lockbox_.superchainConfig()), address(superchainConfig));
        assertEq(address(anchorStateRegistry_.ethLockbox()), address(lockbox_));
        assertEq(address(anchorStateRegistry_.disputeGameFactory()), address(disputeGameFactory_));
        assertEq(disputeGameFactory_.owner(), proxyAdminOwner);
        assertEq(
            address(disputeGameFactory_.gameImpls(GameTypes.PERMISSIONED_CANNON)),
            address(output_.permissionedDisputeGame)
        );
        assertEq(
            address(IDelayedWETH(payable(address(output_.delayedWETHPermissionedGameProxy))).ethLockbox()),
            address(lockbox_)
        );
        assertEq(address(messenger_.systemConfig()), address(systemConfig_));
        assertEq(address(messenger_.portal()), address(portal_));
        assertEq(
            address(IL1StandardBridge(payable(address(output_.l1StandardBridgeProxy))).messenger()), address(messenger_)
        );
        assertEq(address(IL1ERC721Bridge(address(output_.l1ERC721BridgeProxy)).messenger()), address(messenger_));
        assertEq(address(output_.faultDisputeGame), address(0));
        assertEq(address(output_.permissionedDisputeGame), address(implementationsOutput.permissionedDisputeGameImpl));
        assertEq(address(output_.delayedWETHPermissionlessGameProxy), address(output_.delayedWETHPermissionedGameProxy));
        assertEq(disputeGameFactory_.initBonds(GameTypes.PERMISSIONED_CANNON), DEFAULT_INIT_BOND);
    }

    function _assertOutputAddresses(RSKDeployOPChain.Output memory output_) internal view {
        assertGt(address(output_.opChainProxyAdmin).code.length, 0);
        assertGt(address(output_.addressManager).code.length, 0);
        assertGt(address(output_.l1ERC721BridgeProxy).code.length, 0);
        assertGt(address(output_.systemConfigProxy).code.length, 0);
        assertGt(address(output_.optimismMintableERC20FactoryProxy).code.length, 0);
        assertGt(address(output_.l1StandardBridgeProxy).code.length, 0);
        assertGt(address(output_.l1CrossDomainMessengerProxy).code.length, 0);
        assertGt(address(output_.optimismPortalProxy).code.length, 0);
        assertGt(address(output_.ethLockboxProxy).code.length, 0);
        assertGt(address(output_.disputeGameFactoryProxy).code.length, 0);
        assertGt(address(output_.anchorStateRegistryProxy).code.length, 0);
        assertGt(address(output_.permissionedDisputeGame).code.length, 0);
        assertGt(address(output_.delayedWETHPermissionedGameProxy).code.length, 0);
        assertGt(address(output_.delayedWETHPermissionlessGameProxy).code.length, 0);
    }
}

/// @notice `_resourceConfigForGasLimit`, ported from upstream's DeployOPChain
///         gas-limit tests. The fixture's 60M gas limit never reaches the
///         shrinking branch.
contract RSKDeployOPChain_GasLimit_Test is RSKOPCTestBase {
    /// @notice At the default's reserved gas (21M) the config is the default.
    function test_runSplit_gasLimitAtDefaultThreshold_succeeds() public {
        IResourceMetering.ResourceConfig memory defaults = Constants.DEFAULT_RESOURCE_CONFIG();
        uint64 gasLimit = uint64(defaults.maxResourceLimit) + uint64(defaults.systemTxMaxGas);
        _assertDeployedResourceConfig(gasLimit, defaults.maxResourceLimit);
    }

    /// @notice Below it, maxResourceLimit shrinks so the reserved gas is the
    ///         gas limit.
    function test_runSplit_gasLimitFiveMillion_succeeds() public {
        _assertDeployedResourceConfig(5_000_000, 4_000_000);
    }

    /// @notice maxResourceLimit rounds down to a multiple of the elasticity
    ///         multiplier, so the reserved gas stays below the gas limit.
    function test_runSplit_gasLimitNotMultipleOfElasticity_succeeds() public {
        _assertDeployedResourceConfig(5_000_005, 4_000_000);
    }

    function test_runSplit_gasLimitBelowSystemTxMaxGas_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.gasLimit = uint64(Constants.DEFAULT_RESOURCE_CONFIG().systemTxMaxGas);
        vm.expectRevert("RSKDeployOPChain: gasLimit must exceed systemTxMaxGas");
        script.runSplit(deployInput);
    }

    /// @notice 5 gas above systemTxMaxGas rounds down to a zero budget under an
    ///         elasticity multiplier of 10.
    function test_runSplit_gasLimitTooSmallForDeposits_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.gasLimit = uint64(Constants.DEFAULT_RESOURCE_CONFIG().systemTxMaxGas) + 5;
        vm.expectRevert("RSKDeployOPChain: gasLimit too small for any deposit budget");
        script.runSplit(deployInput);
    }

    function _assertDeployedResourceConfig(uint64 _gasLimit, uint32 _expectedMaxResourceLimit) internal {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.gasLimit = _gasLimit;
        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        ISystemConfig systemConfig_ = ISystemConfig(address(output_.systemConfigProxy));
        IResourceMetering.ResourceConfig memory actual = systemConfig_.resourceConfig();
        IResourceMetering.ResourceConfig memory defaults = Constants.DEFAULT_RESOURCE_CONFIG();

        assertEq(systemConfig_.gasLimit(), _gasLimit, "gasLimit");
        assertEq(actual.maxResourceLimit, _expectedMaxResourceLimit, "maxResourceLimit");
        assertEq(actual.maxResourceLimit % actual.elasticityMultiplier, 0, "maxResourceLimit divisible");
        assertLe(uint64(actual.maxResourceLimit) + uint64(actual.systemTxMaxGas), _gasLimit, "reserved gas");
        assertEq(actual.systemTxMaxGas, defaults.systemTxMaxGas, "systemTxMaxGas");
        assertEq(actual.elasticityMultiplier, defaults.elasticityMultiplier, "elasticityMultiplier");
        assertEq(
            actual.baseFeeMaxChangeDenominator, defaults.baseFeeMaxChangeDenominator, "baseFeeMaxChangeDenominator"
        );
        assertEq(actual.minimumBaseFee, defaults.minimumBaseFee, "minimumBaseFee");
        assertEq(actual.maximumBaseFee, defaults.maximumBaseFee, "maximumBaseFee");
    }
}
