// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {IProxyAdmin} from "interfaces/universal/IProxyAdmin.sol";
import {IETHLockbox} from "interfaces/L1/IETHLockbox.sol";
import {IOptimismPortal2} from "interfaces/L1/IOptimismPortal2.sol";
import {ISystemConfig} from "interfaces/L1/ISystemConfig.sol";
import {IOPContractsManagerContainer} from "interfaces/L1/opcm/IOPContractsManagerContainer.sol";
import {IOPContractsManagerUtils} from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import {IDelayedWETH} from "interfaces/dispute/IDelayedWETH.sol";
import {IDisputeGame} from "interfaces/dispute/IDisputeGame.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {IFaultDisputeGame} from "interfaces/dispute/IFaultDisputeGame.sol";
import {Features} from "src/libraries/Features.sol";
import {DevFeatures} from "src/libraries/DevFeatures.sol";
import {Claim, GameStatus, GameTypes, Hash, Proposal} from "src/dispute/lib/Types.sol";

import {RSKOPCMSplitter} from "../contracts/RSKOPCMSplitter.sol";
import {RSKOPCMSplitter_Harness} from "./helpers/RSKOPCMSplitterHarness.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

contract RSKOPCMSplitter_Test is RSKOPCTestBase {
    using stdStorage for StdStorage;

    function test_constructorAndGetters() public view {
        assertEq(address(splitter.opcmV2()), address(implementationsOutput.opcmV2));
        assertEq(address(splitter.opcmUtils()), address(implementationsOutput.opcmUtils));
        assertEq(address(splitter.container()), address(implementationsOutput.opcmContainer));
        assertEq(address(splitter.contractsContainer()), address(implementationsOutput.opcmContainer));
        assertEq(splitter.deployer(), address(this));
        assertEq(splitter.phase(), 0);
        assertFalse(splitter.isInitialDeployment());
        assertEq(splitter.cfgHash(), bytes32(0));
        assertEq(splitter.ctsHash(), bytes32(0));
        assertEq(splitter.devFeatureBitmap(), bytes32(0));
        assertFalse(splitter.isDevFeatureEnabled(bytes32(uint256(1))));
        assertEq(address(splitter.implementations().systemConfigImpl), address(implementationsOutput.systemConfigImpl));
    }

    /// @notice The stages port OPCMv2 9.0.2, so the splitter refuses any other
    ///         release rather than record it as the chain's last-used OPCM.
    function test_constructor_otherOpcmVersion_reverts() public {
        vm.mockCall(
            address(implementationsOutput.opcmV2),
            abi.encodeWithSignature("version()"),
            abi.encode("10.0.0")
        );
        vm.expectRevert(
            abi.encodeWithSelector(RSKOPCMSplitter.RSKOPCMSplitter_UnsupportedOPCMVersion.selector, "10.0.0")
        );
        new RSKOPCMSplitter(implementationsOutput.opcmV2);
    }

    /// @notice SystemConfig records the OPCMv2 the splitter mirrors, not the
    ///         splitter, so the upgrade-sequence check a stock OPCMv2 runs
    ///         before `upgrade` can read the chain's last-used version.
    function test_lastUsedOPCM_isOpcmV2_succeeds() public {
        RSKOPCMSplitter.ChainContracts memory cts = _runSplitter();

        assertEq(cts.systemConfig.lastUsedOPCM(), address(implementationsOutput.opcmV2));
        assertEq(cts.systemConfig.lastUsedOPCMVersion(), implementationsOutput.opcmV2.version());
        assertTrue(
            IOPContractsManagerUtils(address(implementationsOutput.opcmUtils)).isPermittedUpgradeSequence(
                cts.systemConfig, address(implementationsOutput.opcmV2)
            )
        );
    }

    /// @notice OPCMv2 9.0.2 hard-wires SUPER_ROOT_GAMES_MIGRATION on, which
    ///         upstream's OPCM reads as "initial deployments use super-root
    ///         games only". The splitter keeps PERMISSIONED_CANNON deployable
    ///         as the respected game (RSK divergence, see its header).
    function test_permissionedCannon_superRootHardwired_succeeds() public {
        assertEq(splitter.devFeatureBitmap(), bytes32(0));
        assertTrue(splitter.isDevFeatureEnabled(DevFeatures.SUPER_ROOT_GAMES_MIGRATION));

        RSKOPCMSplitter.ChainContracts memory cts = _runSplitter();

        IDisputeGameFactory dgf = IDisputeGameFactory(address(cts.disputeGameFactory));
        assertEq(
            address(dgf.gameImpls(GameTypes.PERMISSIONED_CANNON)), address(implementationsOutput.permissionedDisputeGameImpl)
        );
        assertEq(address(dgf.gameImpls(GameTypes.SUPER_PERMISSIONED)), address(0));
        assertEq(cts.optimismPortal.respectedGameType().raw(), GameTypes.PERMISSIONED_CANNON.raw());
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
        RSKOPCMSplitter.FullConfig memory cfg = fullConfig;
        assertEq(splitter.cfgHash(), keccak256(abi.encode(cfg)));
        RSKOPCMSplitter.ChainContractsCore memory coreCopy = core;
        assertEq(splitter.ctsHash(), keccak256(abi.encode(coreCopy)));

        chainContracts = splitter.deployStep1b_remainingProxies(fullConfig, core);
        assertEq(splitter.phase(), 2);
        assertGt(address(chainContracts.disputeGameFactory).code.length, 0);
        RSKOPCMSplitter.ChainContracts memory cts = chainContracts;
        assertEq(splitter.ctsHash(), keccak256(abi.encode(cts)));

        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 3);
        // OPCMv2 9.0.2: the ETHLockbox is mandatory, so step 2 turns the
        // feature on and points the portal at it.
        assertTrue(chainContracts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX));
        assertEq(address(chainContracts.optimismPortal.ethLockbox()), address(chainContracts.ethLockbox));

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
        fullConfig.disputeGameConfigs.pop();
        _assertStep1aRejectsConfig();
    }

    function test_invalidGameConfigs_order_revertsAndLeavesPhase() public {
        fullConfig.disputeGameConfigs[0].gameType = GameTypes.PERMISSIONED_CANNON;
        _assertStep1aRejectsConfig();
    }

    function test_invalidGameConfigs_disabledBond_revertsAndLeavesPhase() public {
        fullConfig.disputeGameConfigs[0].initBond = 1;
        _assertStep1aRejectsConfig();
    }

    /// @notice CANNON gets a bond, a prestate and a real anchor, so the
    ///         initial-deploy game rule is the only one that rejects it.
    function test_invalidGameConfigs_nonPermissionedEnabled_revertsAndLeavesPhase() public {
        fullConfig.startingAnchorRoot = _realAnchor();
        _enableFaultGame(0);
        _assertStep1aRejectsConfig();
    }

    /// @notice PERMISSIONED_CANNON is the only game an initial deployment may
    ///         enable while SUPER_ROOT_GAMES_MIGRATION is on, so it never
    ///         shares a deployment with a super-root game.
    function test_invalidGameConfigs_withSuperPermissioned_revertsAndLeavesPhase() public {
        fullConfig.disputeGameConfigs[3].enabled = true;
        fullConfig.disputeGameConfigs[3].gameArgs = fullConfig.disputeGameConfigs[1].gameArgs;
        _assertStep1aRejectsConfig();
    }

    function test_invalidGameConfigs_withSuperCannonKona_revertsAndLeavesPhase() public {
        fullConfig.startingAnchorRoot = _realAnchor();
        _enableFaultGame(4);
        _assertStep1aRejectsConfig();
    }

    function test_invalidGameConfigs_startingTypeDisabled_revertsAndLeavesPhase() public {
        fullConfig.disputeGameConfigs[1].enabled = false;
        fullConfig.disputeGameConfigs[1].initBond = 0;
        _assertStep1aRejectsConfig();
    }

    function test_invalidGameConfigs_zeroAnchorRoot_revertsAndLeavesPhase() public {
        fullConfig.startingAnchorRoot = Proposal({root: Hash.wrap(bytes32(0)), l2SequenceNumber: 0});
        _assertStep1aRejectsConfig();
    }

    function test_invalidGameConfigs_maxAnchorSequenceNumber_revertsAndLeavesPhase() public {
        fullConfig.startingAnchorRoot.l2SequenceNumber = type(uint64).max;
        _assertStep1aRejectsConfig();
    }

    /// @notice Every stage after 1a must get the config 1a pinned. The changed
    ///         config has a zero starting anchor root, which step 4b would
    ///         otherwise write to the AnchorStateRegistry without validation.
    function test_inputMismatch_changedConfig_revertsAndLeavesPhase() public {
        RSKOPCMSplitter.FullConfig memory changed = fullConfig;
        changed.startingAnchorRoot = Proposal({root: Hash.wrap(bytes32(0)), l2SequenceNumber: 0});

        core = splitter.deployStep1a_coreProxies(fullConfig);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ConfigMismatch.selector);
        splitter.deployStep1b_remainingProxies(changed, core);
        assertEq(splitter.phase(), 1);
        chainContracts = splitter.deployStep1b_remainingProxies(fullConfig, core);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ConfigMismatch.selector);
        splitter.step2_systemConfigAndPortal(changed, chainContracts);
        assertEq(splitter.phase(), 2);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ConfigMismatch.selector);
        splitter.step3_messengerAndBridges(changed, chainContracts);
        assertEq(splitter.phase(), 3);
        splitter.step3_messengerAndBridges(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ConfigMismatch.selector);
        splitter.step4a_disputeFactoryAndWeth(changed, chainContracts);
        assertEq(splitter.phase(), 4);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ConfigMismatch.selector);
        splitter.step4b_anchorAndGames(changed, chainContracts);
        assertEq(splitter.phase(), 5);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ConfigMismatch.selector);
        splitter.step5_finalize(changed, chainContracts);
        assertEq(splitter.phase(), 6);
        splitter.step5_finalize(fullConfig, chainContracts);
        assertEq(splitter.phase(), 255);
    }

    /// @notice Every stage after 1b must get the contracts 1b returned.
    function test_inputMismatch_changedContracts_revertsAndLeavesPhase() public {
        _startAtStep2();
        RSKOPCMSplitter.ChainContracts memory changed = chainContracts;
        changed.delayedWETH = IDelayedWETH(payable(makeAddr("otherDelayedWETH")));

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ContractsMismatch.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, changed);
        assertEq(splitter.phase(), 2);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ContractsMismatch.selector);
        splitter.step3_messengerAndBridges(fullConfig, changed);
        assertEq(splitter.phase(), 3);
        splitter.step3_messengerAndBridges(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ContractsMismatch.selector);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, changed);
        assertEq(splitter.phase(), 4);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ContractsMismatch.selector);
        splitter.step4b_anchorAndGames(fullConfig, changed);
        assertEq(splitter.phase(), 5);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ContractsMismatch.selector);
        splitter.step5_finalize(fullConfig, changed);
        assertEq(splitter.phase(), 6);
        splitter.step5_finalize(fullConfig, chainContracts);
        assertEq(splitter.phase(), 255);
    }

    /// @notice Step 1b must get the core proxies step 1a returned, in the
    ///         same fields: swapping two of them would deploy each
    ///         implementation behind the other's proxy.
    function test_inputMismatch_changedCore_revertsAndLeavesPhase() public {
        core = splitter.deployStep1a_coreProxies(fullConfig);
        RSKOPCMSplitter.ChainContractsCore memory swapped = core;
        swapped.optimismPortal = IOptimismPortal2(payable(address(core.ethLockbox)));
        swapped.ethLockbox = IETHLockbox(address(core.optimismPortal));

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_ContractsMismatch.selector);
        splitter.deployStep1b_remainingProxies(fullConfig, swapped);
        assertEq(splitter.phase(), 1);
        chainContracts = splitter.deployStep1b_remainingProxies(fullConfig, core);
        assertEq(splitter.phase(), 2);
    }

    /// @notice The pins keep a zero lockbox from reaching step 2 in a deploy,
    ///         so the test pins one by hand to reach the guard.
    function test_invalidEthLockbox_revertsAndLeavesPhase() public {
        _startAtStep2();
        chainContracts.ethLockbox = IETHLockbox(address(0));
        RSKOPCMSplitter.ChainContracts memory cts = chainContracts;
        stdstore.target(address(splitter)).sig("ctsHash()").checked_write(keccak256(abi.encode(cts)));

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidEthLockbox.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    /// @notice A SuperchainConfig older than the release's implementation is
    ///         refused by step 1a, before any proxy exists, and by step 2.
    function test_outdatedSuperchainConfig_revertsAndLeavesPhase() public {
        vm.mockCall(address(superchainConfig), abi.encodeWithSignature("version()"), abi.encode("0.0.1"));
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_SuperchainConfigNeedsUpgrade.selector);
        splitter.deployStep1a_coreProxies(fullConfig);
        assertEq(splitter.phase(), 0);

        vm.clearMockedCalls();
        _startAtStep2();
        vm.mockCall(address(superchainConfig), abi.encodeWithSignature("version()"), abi.encode("0.0.1"));
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_SuperchainConfigNeedsUpgrade.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    /// @notice Step 2 keeps upstream's config check (lines 818-819), which
    ///         step 1a already ran on a deploy. Pinning an invalid config by
    ///         hand shows step 2 still rejects it.
    function test_step2_invalidPinnedConfig_revertsAndLeavesPhase() public {
        _startAtStep2();
        fullConfig.startingAnchorRoot = Proposal({root: Hash.wrap(bytes32(0)), l2SequenceNumber: 0});
        RSKOPCMSplitter.FullConfig memory cfg = fullConfig;
        stdstore.target(address(splitter)).sig("cfgHash()").checked_write(keccak256(abi.encode(cfg)));

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        assertEq(splitter.phase(), 2);
    }

    /// @notice Upstream's upgrade-sequence check (lines 829-836) only runs on
    ///         upgrades. The upgrade path is not here yet (F1.1), so the test
    ///         clears `isInitialDeployment` by hand and mocks the check.
    function test_step2_upgradeSequenceNotPermitted_revertsAndLeavesPhase() public {
        _startAtStep2();
        // phase (uint8) and isInitialDeployment (bool) share slot 0.
        vm.store(address(splitter), bytes32(0), bytes32(uint256(2)));
        assertEq(splitter.phase(), 2);
        assertFalse(splitter.isInitialDeployment());

        vm.mockCall(
            address(implementationsOutput.opcmUtils),
            abi.encodeCall(
                IOPContractsManagerUtils.isPermittedUpgradeSequence,
                (chainContracts.systemConfig, address(implementationsOutput.opcmV2))
            ),
            abi.encode(false)
        );
        vm.mockCall(
            address(chainContracts.systemConfig),
            abi.encodeCall(ISystemConfig.lastUsedOPCMVersion, ()),
            abi.encode("7.0.0")
        );

        vm.expectRevert(
            abi.encodeWithSelector(RSKOPCMSplitter.RSKOPCMSplitter_InvalidUpgradeSequence.selector, "7.0.0", "9.0.2")
        );
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

    /// @notice Step 4b clears the retired SUPER_CANNON slot. The slot is
    ///         already empty on a fresh chain, so only the calls show the
    ///         clear ran. `setImplementation` is overloaded, hence the
    ///         signature string.
    function test_step4b_clearsSuperCannon_succeeds() public {
        _startAtStep4b();
        address dgf = address(chainContracts.disputeGameFactory);

        vm.expectCall(
            dgf,
            abi.encodeWithSignature(
                "setImplementation(uint32,address,bytes)", GameTypes.SUPER_CANNON, address(0), bytes("")
            )
        );
        vm.expectCall(dgf, abi.encodeCall(IDisputeGameFactory.setInitBond, (GameTypes.SUPER_CANNON, 0)));
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
    }

    /// @notice An enabled game whose implementation is zero or has no code
    ///         stops step 4b before it registers anything.
    function test_zeroGameImplementation_revertsAndLeavesPhase() public {
        _startAtStep4b();
        IOPContractsManagerContainer.Implementations memory impls = splitter.implementations();
        bytes memory zeroImplError = abi.encodeWithSelector(
            RSKOPCMSplitter.RSKOPCMSplitter_ZeroGameImplementation.selector, GameTypes.PERMISSIONED_CANNON
        );

        impls.permissionedDisputeGameImpl = address(0);
        _mockImplementations(impls);
        vm.expectRevert(zeroImplError);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
        assertEq(splitter.phase(), 5);

        impls.permissionedDisputeGameImpl = makeAddr("noCodeGameImpl");
        _mockImplementations(impls);
        vm.expectRevert(zeroImplError);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
        assertEq(splitter.phase(), 5);

        vm.clearMockedCalls();
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
        assertEq(splitter.phase(), 6);
    }

    /// @notice Step 2 moves the portal's ETH into the lockbox.
    function test_step2_migratesPortalLiquidity_succeeds() public {
        _startAtStep2();
        vm.deal(address(chainContracts.optimismPortal), 1 ether);

        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);

        assertEq(address(chainContracts.optimismPortal).balance, 0);
        assertEq(address(chainContracts.ethLockbox).balance, 1 ether);
    }

    /// @notice A custom gas token chain keeps its ETH in the portal, and step
    ///         4b turns the feature on.
    function test_step2_customGasToken_keepsPortalLiquidity_succeeds() public {
        fullConfig.useCustomGasToken = true;
        _startAtStep2();
        vm.deal(address(chainContracts.optimismPortal), 1 ether);

        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);

        assertEq(address(chainContracts.optimismPortal).balance, 1 ether);
        assertEq(address(chainContracts.ethLockbox).balance, 0);

        splitter.step3_messengerAndBridges(fullConfig, chainContracts);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);
        splitter.step4b_anchorAndGames(fullConfig, chainContracts);
        assertTrue(chainContracts.systemConfig.isCustomGasToken());
    }

    /// @dev Step 1a runs step 2's checks before it pins the config or deploys
    ///      a proxy, so an invalid config never leaves phase 0.
    function _assertStep1aRejectsConfig() internal {
        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        splitter.deployStep1a_coreProxies(fullConfig);
        assertEq(splitter.phase(), 0);
    }

    function _startAtStep4b() internal {
        _startAtStep2();
        splitter.step2_systemConfigAndPortal(fullConfig, chainContracts);
        splitter.step3_messengerAndBridges(fullConfig, chainContracts);
        splitter.step4a_disputeFactoryAndWeth(fullConfig, chainContracts);
    }

    /// @dev Both the splitter and OPContractsManagerUtils read the
    ///      implementations from the container.
    function _mockImplementations(IOPContractsManagerContainer.Implementations memory _impls) internal {
        vm.mockCall(
            address(implementationsOutput.opcmContainer),
            abi.encodeCall(IOPContractsManagerContainer.implementations, ()),
            abi.encode(_impls)
        );
    }
}

/// @notice The two RSK divergences in `_assertValidFullConfig`, reached
///         through the harness.
contract RSKOPCMSplitter_AssertValidFullConfig_Test is RSKOPCTestBase {
    RSKOPCMSplitter_Harness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new RSKOPCMSplitter_Harness(implementationsOutput.opcmV2);
    }

    /// @notice Upgrade mode skips the initial-deploy game rule, so the same
    ///         CANNON config the initial deployment rejects passes here.
    function test_assertValidFullConfig_upgradeNonPermissioned_succeeds() public {
        fullConfig.startingAnchorRoot = _realAnchor();
        _enableFaultGame(0);
        harness.assertValidFullConfig(fullConfig, false);
    }

    /// @notice Only the permissioned games are exempt from the bond rule.
    function test_assertValidFullConfig_zeroBondCannonKona_reverts() public {
        _enableFaultGame(2);
        fullConfig.disputeGameConfigs[2].initBond = 0;

        vm.expectRevert(RSKOPCMSplitter.RSKOPCMSplitter_InvalidGameConfigs.selector);
        harness.assertValidFullConfig(fullConfig, false);

        fullConfig.disputeGameConfigs[2].initBond = 1;
        harness.assertValidFullConfig(fullConfig, false);
    }

    /// @notice RSK divergence: PERMISSIONED_CANNON may carry a zero bond
    ///         (PAYROLLUP-191), in upgrade mode as well.
    function test_assertValidFullConfig_zeroBondPermissionedCannon_succeeds() public {
        fullConfig.disputeGameConfigs[1].initBond = 0;
        harness.assertValidFullConfig(fullConfig, true);
        harness.assertValidFullConfig(fullConfig, false);
    }
}
