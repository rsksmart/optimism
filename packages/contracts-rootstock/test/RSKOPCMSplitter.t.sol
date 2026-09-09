// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IProxyAdmin} from "interfaces/universal/IProxyAdmin.sol";
import {IDisputeGame} from "interfaces/dispute/IDisputeGame.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {IFaultDisputeGame} from "interfaces/dispute/IFaultDisputeGame.sol";
import {Features} from "src/libraries/Features.sol";
import {Claim, GameStatus, GameTypes} from "src/dispute/lib/Types.sol";

import {RSKOPCMSplitter} from "../contracts/RSKOPCMSplitter.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

contract RSKOPCMSplitter_Test is RSKOPCTestBase {
    function test_constructorAndGetters() public {
        assertEq(address(splitter.container()), address(implementationsOutput.opcmContainer));
        assertEq(address(splitter.contractsContainer()), address(implementationsOutput.opcmContainer));
        assertEq(splitter.deployer(), address(this));
        assertEq(address(splitter.opcmStandardValidator()), address(implementationsOutput.opcmStandardValidator));
        assertEq(address(splitter.opcmMigrator()), address(implementationsOutput.opcmMigrator));
        assertEq(splitter.phase(), 0);
        assertFalse(splitter.isInitialDeployment());
        assertEq(splitter.devFeatureBitmap(), bytes32(0));
        assertFalse(splitter.isDevFeatureEnabled(bytes32(uint256(1))));
        assertEq(address(splitter.implementations().systemConfigImpl), address(implementationsOutput.systemConfigImpl));
    }

    function test_onlyDeployer_guardsEveryStage() public {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.deployStep1a_coreProxies(fullConfig);

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.deployStep1b_remainingProxies(fullConfig, core);

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.step3_messengerAndBridges(fullConfig, chainContracts);

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);

        vm.prank(stranger);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.step5_finalize(fullConfig, chainContracts);
    }

    function test_lifecycle_advancesThroughAllPhasesAndSeals() public {
        core = splitter.deployStep1a_coreProxies(fullConfig);
        assertEq(splitter.phase(), 1);
        assertTrue(splitter.isInitialDeployment());
        assertGt(address(core.proxyAdmin).code.length, 0);

        chainContracts = splitter.deployStep1b_remainingProxies(fullConfig, core);
        assertEq(splitter.phase(), 2);
        assertGt(address(chainContracts.disputeGameFactory).code.length, 0);

        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 3);
        assertFalse(chainContracts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX));

        splitter.step3_messengerAndBridges(fullConfig, chainContracts);
        assertEq(splitter.phase(), 4);
        assertGt(address(chainContracts.l1CrossDomainMessenger).code.length, 0);

        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);
        assertEq(splitter.phase(), 5);

        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
        assertEq(splitter.phase(), 6);
        assertEq(
            IDisputeGameFactory(chainContracts.disputeGameFactory).initBonds(GameTypes.PERMISSIONED_CANNON),
            DEFAULT_INIT_BOND
        );
        assertEq(
            address(IDisputeGameFactory(chainContracts.disputeGameFactory).gameImpls(GameTypes.PERMISSIONED_CANNON)),
            address(implementationsOutput.permissionedDisputeGameImpl)
        );

        splitter.step5_finalize(fullConfig, chainContracts);
        assertEq(splitter.phase(), 255);
        assertEq(IProxyAdmin(address(chainContracts.proxyAdmin)).owner(), proxyAdminOwner);
        assertEq(IDisputeGameFactory(address(chainContracts.disputeGameFactory)).owner(), proxyAdminOwner);
        assertEq(address(chainContracts.systemConfig.owner()), systemConfigOwner);
    }

    function test_outOfOrderAndReplay_revertWithoutChangingPhase() public {
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotStarted.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 0);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotStarted.selector);
        splitter.deployStep1b_remainingProxies(fullConfig, core);
        assertEq(splitter.phase(), 0);

        core = splitter.deployStep1a_coreProxies(fullConfig);
        assertEq(splitter.phase(), 1);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_AlreadyStarted.selector);
        splitter.deployStep1a_coreProxies(fullConfig);
        assertEq(splitter.phase(), 1);

        chainContracts = splitter.deployStep1b_remainingProxies(fullConfig, core);
        assertEq(splitter.phase(), 2);
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotStarted.selector);
        splitter.deployStep1b_remainingProxies(fullConfig, core);
        assertEq(splitter.phase(), 2);
    }

    function test_sealed_isTerminalAndAuthCheckPrecedesSealCheck() public {
        _runSplitter();
        assertEq(splitter.phase(), 255);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_AlreadySealed.selector);
        splitter.deployStep1a_coreProxies(fullConfig);

        vm.prank(makeAddr("postSealStranger"));
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_NotDeployer.selector);
        splitter.deployStep1a_coreProxies(fullConfig);
    }

    function test_invalidGameConfigs_length_revertsAndLeavesPhase() public {
        _startAtStep2();
        fullConfig.disputeGameConfigs.pop();

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    function test_invalidGameConfigs_order_revertsAndLeavesPhase() public {
        _startAtStep2();
        fullConfig.disputeGameConfigs[0].gameType = GameTypes.PERMISSIONED_CANNON;

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    function test_invalidGameConfigs_disabledBond_revertsAndLeavesPhase() public {
        _startAtStep2();
        fullConfig.disputeGameConfigs[0].initBond = 1;

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    function test_invalidGameConfigs_nonPermissionedEnabled_revertsAndLeavesPhase() public {
        _startAtStep2();
        fullConfig.disputeGameConfigs[0].enabled = true;

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    function test_invalidGameConfigs_startingTypeDisabled_revertsAndLeavesPhase() public {
        _startAtStep2();
        fullConfig.disputeGameConfigs[1].enabled = false;
        fullConfig.disputeGameConfigs[1].initBond = 0;

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    function test_bondZero_gameCreatesAndResolves() public {
        fullConfig.disputeGameConfigs[1].initBond = 0;
        RSKOPCMSplitter.ChainContracts memory cts = _runSplitter();

        IDisputeGameFactory dgf = IDisputeGameFactory(cts.disputeGameFactory);
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), 0);

        // With a non-zero bond this zero-value create would revert with
        // IncorrectBondAmount; PermissionedDisputeGame requires tx.origin to
        // be the proposer, hence the two-argument prank.
        vm.prank(proposer, proposer);
        IDisputeGame game =
            dgf.create{value: 0}(GameTypes.PERMISSIONED_CANNON, Claim.wrap(bytes32(uint256(1))), abi.encode(uint256(1)));

        vm.warp(block.timestamp + maxClockDuration.raw() + 1);
        IFaultDisputeGame(address(game)).resolveClaim(0, 0);
        game.resolve();

        assertEq(uint8(game.status()), uint8(GameStatus.DEFENDER_WINS));
        assertEq(IFaultDisputeGame(address(game)).credit(proposer), 0);
    }

    function test_lateCollaboratorFailure_isAtomicAndRetryable() public {
        _startAtStep2();

        bytes memory injectedRevert = abi.encodeWithSignature("Error(string)", "late ethLockbox failure");
        bytes memory ethLockboxUpgradePrefix =
            abi.encodeWithSelector(IProxyAdmin.upgradeAndCall.selector, address(chainContracts.ethLockbox));
        vm.mockCallRevert(address(chainContracts.proxyAdmin), ethLockboxUpgradePrefix, injectedRevert);

        vm.expectRevert(injectedRevert);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);

        vm.clearMockedCalls();
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 3);

        splitter.step3_messengerAndBridges(fullConfig, chainContracts);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
        splitter.step5_finalize(fullConfig, chainContracts);
        assertEq(splitter.phase(), 255);
    }
}
