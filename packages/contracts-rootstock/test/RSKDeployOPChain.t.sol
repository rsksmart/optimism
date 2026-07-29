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
import {Claim, Duration, GameTypes} from "src/dispute/lib/Types.sol";

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

    function test_runSplit_unsupportedGameType_revertsBeforeDeployment() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        deployInput.disputeGameType = GameTypes.CANNON;

        vm.expectRevert("RSKDeployOPChain: only PERMISSIONED_CANNON game type is supported for initial deployment");
        script.runSplit(deployInput);
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
        assertEq(address(IETHLockbox(address(output_.ethLockboxProxy)).systemConfig()), address(systemConfig_));
        assertEq(address(anchorStateRegistry_.systemConfig()), address(systemConfig_));
        assertEq(address(anchorStateRegistry_.disputeGameFactory()), address(disputeGameFactory_));
        assertEq(disputeGameFactory_.owner(), proxyAdminOwner);
        assertEq(
            address(disputeGameFactory_.gameImpls(GameTypes.PERMISSIONED_CANNON)),
            address(output_.permissionedDisputeGame)
        );
        assertEq(
            address(IDelayedWETH(payable(address(output_.delayedWETHPermissionedGameProxy))).systemConfig()),
            address(systemConfig_)
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
