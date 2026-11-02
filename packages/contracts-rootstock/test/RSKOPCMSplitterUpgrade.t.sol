// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

import {IProxyAdmin} from "interfaces/universal/IProxyAdmin.sol";
import {ISystemConfig} from "interfaces/L1/ISystemConfig.sol";
import {ISuperchainConfig} from "interfaces/L1/ISuperchainConfig.sol";
import {IOptimismPortal2} from "interfaces/L1/IOptimismPortal2.sol";
import {IETHLockbox} from "interfaces/L1/IETHLockbox.sol";
import {IOPContractsManagerUtils} from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import {IOPContractsManagerV2} from "interfaces/L1/opcm/IOPContractsManagerV2.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {IDisputeGame} from "interfaces/dispute/IDisputeGame.sol";
import {IFaultDisputeGame} from "interfaces/dispute/IFaultDisputeGame.sol";
import {IAnchorStateRegistry} from "interfaces/dispute/IAnchorStateRegistry.sol";
import {IDelayedWETH} from "interfaces/dispute/IDelayedWETH.sol";
import {Features} from "src/libraries/Features.sol";
import {Constants} from "src/libraries/Constants.sol";
import {Duration, GameTypes} from "src/dispute/lib/Types.sol";

import {RSKOPCMSplitterBase} from "../contracts/RSKOPCMSplitterBase.sol";
import {RSKOPCMSplitterUpgrade} from "../contracts/RSKOPCMSplitterUpgrade.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

/// @notice Deploys a 9.0.2 chain with the splitter and an upgrader for it. The fixture's
///         implementations are the same 9.0.2 ones, so an upgrade re-applies the release; the
///         RSK-only branches run on a chain `_makeLegacyChain` dresses up as one the pre-9.0.2
///         splitter deployed. RSKOPCMSplitterUpgradeFork_Test runs a real 7.1.17 chain.
abstract contract RSKOPCMSplitterUpgrade_TestInit is RSKOPCTestBase {
    using stdStorage for StdStorage;

    struct SlotWrite {
        address account;
        bytes32 slot;
        bytes32 previous;
        bytes32 last;
    }

    RSKOPCMSplitterBase.ChainContracts internal cts;
    RSKOPCMSplitterUpgrade internal upgrader;
    address internal superchainProxyAdminOwner = makeAddr("superchainProxyAdminOwner");

    function setUp() public virtual override {
        super.setUp();
        cts = _runSplitter();
        upgrader = new RSKOPCMSplitterUpgrade(implementationsOutput.opcmV2, cts.systemConfig);
    }

    function _input() internal view returns (RSKOPCMSplitterUpgrade.UpgradeInput memory inp_) {
        inp_.systemConfig = cts.systemConfig;
        inp_.disputeGameConfigs = fullConfig.disputeGameConfigs;
    }

    function _withInstruction(
        RSKOPCMSplitterUpgrade.UpgradeInput memory _inp,
        string memory _key,
        bytes memory _data
    )
        internal
        pure
        returns (RSKOPCMSplitterUpgrade.UpgradeInput memory)
    {
        uint256 n = _inp.extraInstructions.length;
        IOPContractsManagerUtils.ExtraInstruction[] memory ins = new IOPContractsManagerUtils.ExtraInstruction[](n + 1);
        for (uint256 i = 0; i < n; i++) {
            ins[i] = _inp.extraInstructions[i];
        }
        ins[n] = IOPContractsManagerUtils.ExtraInstruction({key: _key, data: _data});
        _inp.extraInstructions = ins;
        return _inp;
    }

    function _withLockboxOverride(RSKOPCMSplitterUpgrade.UpgradeInput memory _inp, address _lockbox)
        internal
        pure
        returns (RSKOPCMSplitterUpgrade.UpgradeInput memory)
    {
        return _withInstruction(_inp, "overrides.cts.ethLockbox", abi.encode(_lockbox));
    }

    function _handOver() internal {
        vm.prank(proxyAdminOwner);
        cts.proxyAdmin.transferOwnership(address(upgrader));
    }

    function _handOverSuperchain() internal {
        IProxyAdmin superchainProxyAdmin = upgrader.superchainProxyAdmin();
        vm.prank(superchainProxyAdminOwner);
        superchainProxyAdmin.transferOwnership(address(upgrader));
    }

    /// @dev What the pre-9.0.2 splitter leaves behind: `lastUsedOPCM` is a contract without
    ///      `version()` (the splitter itself), SystemConfig is 3.14.2, the portal has no
    ///      lockbox, ETH_LOCKBOX is off and the ETH sits in the portal. The ETHLockbox proxy
    ///      exists unused and answers the 1.x `systemConfig()` getter.
    function _makeLegacyChain(uint256 _portalBalance) internal {
        stdstore.target(address(cts.systemConfig)).sig("lastUsedOPCM()").checked_write(address(splitter));
        vm.mockCall(address(cts.systemConfig), abi.encodeCall(ISystemConfig.version, ()), abi.encode("3.14.2"));
        stdstore.target(address(cts.optimismPortal)).sig("ethLockbox()").checked_write(address(0));
        stdstore.target(address(cts.systemConfig)).sig("isFeatureEnabled(bytes32)").with_key(Features.ETH_LOCKBOX)
            .checked_write(false);
        vm.deal(address(cts.ethLockbox), 0);
        vm.deal(address(cts.optimismPortal), _portalBalance);
        vm.mockCall(address(cts.ethLockbox), abi.encodeWithSignature("systemConfig()"), abi.encode(cts.systemConfig));

        vm.expectRevert();
        cts.systemConfig.lastUsedOPCMVersion();
        assertEq(address(cts.optimismPortal.ethLockbox()), address(0));
    }

    /// @dev The last value each (account, slot) was written to, with the value before the
    ///      first write, skipping reverted writes and `_ignore`'s storage.
    function _slotWrites(Vm.AccountAccess[] memory _accesses, address _ignore)
        internal
        pure
        returns (SlotWrite[] memory writes_)
    {
        uint256 total;
        for (uint256 i = 0; i < _accesses.length; i++) {
            total += _accesses[i].storageAccesses.length;
        }
        writes_ = new SlotWrite[](total);
        uint256 count;
        for (uint256 i = 0; i < _accesses.length; i++) {
            for (uint256 j = 0; j < _accesses[i].storageAccesses.length; j++) {
                Vm.StorageAccess memory s = _accesses[i].storageAccesses[j];
                if (!s.isWrite || s.reverted || s.account == _ignore) continue;
                (bool found, uint256 k) = _indexOf(writes_, count, s.account, s.slot);
                if (found) {
                    writes_[k].last = s.newValue;
                } else {
                    writes_[count++] =
                        SlotWrite({account: s.account, slot: s.slot, previous: s.previousValue, last: s.newValue});
                }
            }
        }
        assembly {
            mstore(writes_, count)
        }
    }

    function _indexOf(SlotWrite[] memory _writes, uint256 _count, address _account, bytes32 _slot)
        internal
        pure
        returns (bool, uint256)
    {
        for (uint256 k = 0; k < _count; k++) {
            if (_writes[k].account == _account && _writes[k].slot == _slot) return (true, k);
        }
        return (false, 0);
    }

    /// @dev Both runs started from the same state, so a slot only one of them wrote must end at
    ///      the value it had before.
    function _assertSameFinalState(SlotWrite[] memory _a, SlotWrite[] memory _b) internal pure {
        for (uint256 i = 0; i < _a.length; i++) {
            (bool found, uint256 k) = _indexOf(_b, _b.length, _a[i].account, _a[i].slot);
            bytes32 other = found ? _b[k].last : _a[i].previous;
            require(_a[i].last == other, _slotLabel(_a[i]));
        }
        for (uint256 i = 0; i < _b.length; i++) {
            (bool found,) = _indexOf(_a, _a.length, _b[i].account, _b[i].slot);
            if (!found) require(_b[i].last == _b[i].previous, _slotLabel(_b[i]));
        }
    }

    function _slotLabel(SlotWrite memory _w) internal pure returns (string memory) {
        return string.concat("final state differs at ", vm.toString(_w.account), " slot ", vm.toString(_w.slot));
    }
}

contract RSKOPCMSplitterUpgrade_Test is RSKOPCMSplitterUpgrade_TestInit {
    using stdStorage for StdStorage;

    function test_constructor_recordsChainAndOwners_succeeds() public view {
        assertEq(address(upgrader.opcmV2()), address(implementationsOutput.opcmV2));
        assertEq(address(upgrader.opcmUtils()), address(implementationsOutput.opcmUtils));
        assertEq(address(upgrader.container()), address(implementationsOutput.opcmContainer));
        assertEq(upgrader.deployer(), address(this));
        assertEq(address(upgrader.systemConfig()), address(cts.systemConfig));
        assertEq(address(upgrader.chainProxyAdmin()), address(cts.proxyAdmin));
        assertEq(upgrader.chainProxyAdminOwner(), proxyAdminOwner);
        assertEq(address(upgrader.superchainProxyAdmin()), address(superchainConfig.proxyAdmin()));
        assertEq(upgrader.superchainProxyAdminOwner(), superchainProxyAdminOwner);
        assertFalse(upgrader.finished());
    }

    function test_constructor_otherOpcmVersion_reverts() public {
        vm.mockCall(
            address(implementationsOutput.opcmV2), abi.encodeWithSignature("version()"), abi.encode("10.0.0")
        );
        vm.expectRevert(
            abi.encodeWithSelector(RSKOPCMSplitterBase.RSKOPCMSplitter_UnsupportedOPCMVersion.selector, "10.0.0")
        );
        new RSKOPCMSplitterUpgrade(implementationsOutput.opcmV2, cts.systemConfig);
    }

    /// @notice A ProxyAdmin handed to the upgrader's address before it was deployed would be
    ///         recorded as the upgrader's own and never come back.
    function test_constructor_ownerIsUpgrader_reverts() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(proxyAdminOwner);
        cts.proxyAdmin.transferOwnership(next);

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_OwnerIsUpgrader.selector, cts.proxyAdmin
            )
        );
        new RSKOPCMSplitterUpgrade(implementationsOutput.opcmV2, cts.systemConfig);
    }

    /// @notice On a chain a stock OPCMv2 9.0.2 accepts (non-zero bond, `lastUsedOPCM` with a
    ///         version), the upgrader leaves every storage slot where the stock `upgrade`,
    ///         delegatecalled by the ProxyAdmin owner, leaves it. The ProxyAdmin round trip and
    ///         the DisputeGameFactory owner hand-back end where upstream's never moved them.
    ///         Every proxy starts on a copy of its implementation and the input changes the
    ///         permissioned game's proposer and bond, so each `_apply` slice has state to move:
    ///         one the upgrader skipped would leave a slot behind.
    function test_upgrade_matchesStockOpcmUpgrade_succeeds() public {
        _moveToImplementationCopies();
        fullConfig.disputeGameConfigs[1].initBond = 1 ether;
        fullConfig.disputeGameConfigs[1].gameArgs = abi.encode(
            IOPContractsManagerUtils.PermissionedDisputeGameConfig({
                absolutePrestate: absolutePrestate,
                proposer: makeAddr("newProposer"),
                challenger: challenger
            })
        );
        uint256 snapshot = vm.snapshotState();

        IOPContractsManagerV2.UpgradeInput memory stockInput;
        stockInput.systemConfig = cts.systemConfig;
        stockInput.disputeGameConfigs = fullConfig.disputeGameConfigs;
        vm.startStateDiffRecording();
        vm.etch(proxyAdminOwner, hex"00");
        vm.prank(proxyAdminOwner, true);
        (bool ok,) = address(implementationsOutput.opcmV2).delegatecall(
            abi.encodeCall(IOPContractsManagerV2.upgrade, (stockInput))
        );
        assertTrue(ok, "stock upgrade failed");
        SlotWrite[] memory stock = _slotWrites(vm.stopAndReturnStateDiff(), address(0));

        vm.revertToState(snapshot);

        vm.startStateDiffRecording();
        _handOver();
        upgrader.upgrade(_input());
        SlotWrite[] memory rsk = _slotWrites(vm.stopAndReturnStateDiff(), address(upgrader));

        assertGt(stock.length, 0);
        assertGt(rsk.length, 0);
        _assertSameFinalState(stock, rsk);
        _assertOnReleaseImplementations();
    }

    /// @dev Points every chain proxy at a copy of its implementation (same code, so the same
    ///      version), so an upgrade has to move each implementation slot back to the release's.
    function _moveToImplementationCopies() internal {
        address[10] memory proxies = _chainProxies();
        for (uint256 i = 0; i < proxies.length; i++) {
            address impl = cts.proxyAdmin.getProxyImplementation(payable(proxies[i]));
            address copy = address(uint160(uint256(keccak256(abi.encode("implementation copy", proxies[i])))));
            vm.etch(copy, impl.code);
            vm.prank(proxyAdminOwner);
            cts.proxyAdmin.upgrade(payable(proxies[i]), copy);
            assertEq(cts.proxyAdmin.getProxyImplementation(payable(proxies[i])), copy);
        }
    }

    function _assertOnReleaseImplementations() internal view {
        address[10] memory proxies = _chainProxies();
        address[10] memory impls = [
            address(implementationsOutput.systemConfigImpl),
            address(implementationsOutput.optimismPortalImpl),
            address(implementationsOutput.ethLockboxImpl),
            address(implementationsOutput.l1CrossDomainMessengerImpl),
            address(implementationsOutput.l1StandardBridgeImpl),
            address(implementationsOutput.l1ERC721BridgeImpl),
            address(implementationsOutput.optimismMintableERC20FactoryImpl),
            address(implementationsOutput.disputeGameFactoryImpl),
            address(implementationsOutput.anchorStateRegistryImpl),
            address(implementationsOutput.delayedWETHImpl)
        ];
        for (uint256 i = 0; i < proxies.length; i++) {
            assertEq(cts.proxyAdmin.getProxyImplementation(payable(proxies[i])), impls[i]);
        }
    }

    function _chainProxies() internal view returns (address[10] memory) {
        return [
            address(cts.systemConfig),
            address(cts.optimismPortal),
            address(cts.ethLockbox),
            address(cts.l1CrossDomainMessenger),
            address(cts.l1StandardBridge),
            address(cts.l1ERC721Bridge),
            address(cts.optimismMintableERC20Factory),
            address(cts.disputeGameFactory),
            address(cts.anchorStateRegistry),
            address(cts.delayedWETH)
        ];
    }

    function test_upgrade_handsEverythingBack_succeeds() public {
        address factoryOwner = makeAddr("factoryOwner");
        vm.prank(proxyAdminOwner);
        IDisputeGameFactory(address(cts.disputeGameFactory)).transferOwnership(factoryOwner);
        _handOver();
        _handOverSuperchain();

        RSKOPCMSplitterBase.ChainContracts memory upgraded = upgrader.upgrade(_input());

        assertEq(keccak256(abi.encode(upgraded)), keccak256(abi.encode(cts)));
        assertEq(cts.proxyAdmin.owner(), proxyAdminOwner);
        assertEq(upgrader.superchainProxyAdmin().owner(), superchainProxyAdminOwner);
        assertEq(IDisputeGameFactory(address(cts.disputeGameFactory)).owner(), factoryOwner);
        assertEq(cts.systemConfig.lastUsedOPCM(), address(implementationsOutput.opcmV2));
        assertTrue(upgrader.finished());
    }

    /// @notice The chain the pre-9.0.2 splitter deployed: the sequence check takes the legacy
    ///         branch, the unused ETHLockbox proxy is adopted and the portal's ETH moves into it.
    function test_upgrade_legacyChainAdoptsLockbox_succeeds() public {
        _makeLegacyChain(3 ether);
        _handOver();

        upgrader.upgrade(_withLockboxOverride(_input(), address(cts.ethLockbox)));

        assertEq(address(cts.optimismPortal.ethLockbox()), address(cts.ethLockbox));
        assertTrue(cts.systemConfig.isFeatureEnabled(Features.ETH_LOCKBOX));
        assertTrue(cts.ethLockbox.authorizedPortals(cts.optimismPortal));
        assertEq(address(cts.ethLockbox).balance, 3 ether);
        assertEq(address(cts.optimismPortal).balance, 0);
        assertEq(cts.systemConfig.lastUsedOPCM(), address(implementationsOutput.opcmV2));
        assertEq(cts.systemConfig.lastUsedOPCMVersion(), "9.0.2");
        assertEq(cts.proxyAdmin.owner(), proxyAdminOwner);
    }

    /// @notice Upstream's way for the same chain: the v9 deployment permission makes a new
    ///         lockbox proxy, and the old one stays behind empty.
    function test_upgrade_legacyChainDeploysLockbox_succeeds() public {
        _makeLegacyChain(3 ether);
        _handOver();

        upgrader.upgrade(
            _withInstruction(_input(), Constants.PERMITTED_PROXY_DEPLOYMENT_KEY, bytes("ETHLockbox"))
        );

        IETHLockbox lockbox = cts.optimismPortal.ethLockbox();
        assertTrue(address(lockbox) != address(0));
        assertTrue(address(lockbox) != address(cts.ethLockbox));
        assertEq(cts.proxyAdmin.getProxyAdmin(payable(address(lockbox))), address(cts.proxyAdmin));
        assertEq(address(lockbox).balance, 3 ether);
        assertEq(address(cts.ethLockbox).balance, 0);
        assertEq(address(cts.optimismPortal).balance, 0);
    }

    function test_upgrade_legacyChainWithoutLockboxInstruction_reverts() public {
        _makeLegacyChain(1 ether);
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                IOPContractsManagerUtils.OPContractsManagerUtils_ProxyMustLoad.selector, "ETHLockbox"
            )
        );
        upgrader.upgrade(_input());
    }

    function test_upgrade_lockboxOverrideWithDeployPermission_reverts() public {
        _makeLegacyChain(1 ether);
        _handOver();
        RSKOPCMSplitterUpgrade.UpgradeInput memory inp = _withLockboxOverride(_input(), address(cts.ethLockbox));
        inp = _withInstruction(inp, Constants.PERMITTED_PROXY_DEPLOYMENT_KEY, bytes("ETHLockbox"));

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidEthLockboxOverride.selector,
                address(cts.ethLockbox)
            )
        );
        upgrader.upgrade(inp);
    }

    /// @notice The override is for a portal without a lockbox only: it never replaces the one
    ///         the portal uses.
    function test_upgrade_lockboxOverridePortalHasLockbox_reverts() public {
        vm.mockCall(address(cts.ethLockbox), abi.encodeWithSignature("systemConfig()"), abi.encode(cts.systemConfig));
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidEthLockboxOverride.selector,
                address(cts.ethLockbox)
            )
        );
        upgrader.upgrade(_withLockboxOverride(_input(), address(cts.ethLockbox)));
    }

    /// @notice A proxy another ProxyAdmin administers, or an account without code, is not this
    ///         chain's lockbox.
    function test_upgrade_lockboxOverrideNotChainProxy_reverts() public {
        _makeLegacyChain(1 ether);
        _handOver();
        address[2] memory candidates = [address(superchainConfig), makeAddr("eoa")];
        for (uint256 i = 0; i < candidates.length; i++) {
            vm.mockCall(candidates[i], abi.encodeWithSignature("systemConfig()"), abi.encode(cts.systemConfig));
            vm.expectRevert(
                abi.encodeWithSelector(
                    RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidEthLockboxOverride.selector, candidates[i]
                )
            );
            upgrader.upgrade(_withLockboxOverride(_input(), candidates[i]));
        }
    }

    function test_upgrade_lockboxOverrideOtherSystemConfig_reverts() public {
        _makeLegacyChain(1 ether);
        vm.mockCall(address(cts.ethLockbox), abi.encodeWithSignature("systemConfig()"), abi.encode(makeAddr("other")));
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidEthLockboxOverride.selector,
                address(cts.ethLockbox)
            )
        );
        upgrader.upgrade(_withLockboxOverride(_input(), address(cts.ethLockbox)));
    }

    /// @notice A `lastUsedOPCM` without `version()` is only the pre-9.0.2 splitter while the
    ///         SystemConfig still runs the version that splitter deployed.
    function test_upgrade_legacySequenceOtherSystemConfigVersion_reverts() public {
        _makeLegacyChain(0);
        vm.mockCall(address(cts.systemConfig), abi.encodeCall(ISystemConfig.version, ()), abi.encode("4.2.0"));
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidUpgradeSequence.selector, "", "9.0.2"
            )
        );
        upgrader.upgrade(_withLockboxOverride(_input(), address(cts.ethLockbox)));
    }

    /// @notice With a versioned `lastUsedOPCM`, upstream's rule decides.
    function test_upgrade_sequenceNotPermitted_reverts() public {
        vm.mockCall(
            address(implementationsOutput.opcmUtils),
            abi.encodeCall(
                IOPContractsManagerUtils.isPermittedUpgradeSequence,
                (cts.systemConfig, address(implementationsOutput.opcmV2))
            ),
            abi.encode(false)
        );
        vm.mockCall(
            address(cts.systemConfig), abi.encodeCall(ISystemConfig.lastUsedOPCMVersion, ()), abi.encode("7.0.0")
        );
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidUpgradeSequence.selector, "7.0.0", "9.0.2"
            )
        );
        upgrader.upgrade(_input());
    }

    function test_upgrade_proofMaturityDelayChanged_reverts() public {
        _assertDelayGuard(
            address(cts.optimismPortal),
            abi.encodeCall(IOptimismPortal2.proofMaturityDelaySeconds, ()),
            "proofMaturityDelaySeconds",
            400
        );
    }

    function test_upgrade_disputeGameFinalityDelayChanged_reverts() public {
        _assertDelayGuard(
            address(cts.anchorStateRegistry),
            abi.encodeCall(IAnchorStateRegistry.disputeGameFinalityDelaySeconds, ()),
            "disputeGameFinalityDelaySeconds",
            500
        );
    }

    function test_upgrade_withdrawalDelayChanged_reverts() public {
        _assertDelayGuard(address(cts.delayedWETH), abi.encodeCall(IDelayedWETH.delay, ()), "delay", 100);
    }

    /// @dev The fixture's implementations carry `_implValue`. A chain whose proxy answers
    ///      another delay must stop the upgrade before it touches anything. The proxy is mocked
    ///      rather than the implementation: a mock on the implementation would also answer the
    ///      proxy's delegatecall.
    function _assertDelayGuard(address _proxy, bytes memory _getter, string memory _name, uint256 _implValue)
        internal
    {
        vm.mockCall(_proxy, _getter, abi.encode(_implValue + 1));
        _handOver();
        address systemConfigImpl = cts.proxyAdmin.getProxyImplementation(payable(address(cts.systemConfig)));

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_ImmutableChanged.selector,
                _name,
                _implValue + 1,
                _implValue
            )
        );
        upgrader.upgrade(_input());
        assertEq(cts.proxyAdmin.getProxyImplementation(payable(address(cts.systemConfig))), systemConfigImpl);
    }

    /// @notice The game loop installs the release's game implementation, whose depths and
    ///         clocks are immutables too: a chain running other values keeps the old game.
    function test_upgrade_gameClockChanged_reverts() public {
        IDisputeGameFactory dgf = IDisputeGameFactory(address(cts.disputeGameFactory));
        address live = address(dgf.gameImpls(GameTypes.PERMISSIONED_CANNON));
        address copy = makeAddr("liveGameImplementation");
        vm.etch(copy, live.code);
        bytes memory args = dgf.gameArgs(GameTypes.PERMISSIONED_CANNON);
        vm.prank(proxyAdminOwner);
        dgf.setImplementation(GameTypes.PERMISSIONED_CANNON, IDisputeGame(copy), args);
        uint64 releaseClock = IFaultDisputeGame(live).maxClockDuration().raw();
        vm.mockCall(
            copy, abi.encodeCall(IFaultDisputeGame.maxClockDuration, ()), abi.encode(Duration.wrap(1 hours))
        );
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_ImmutableChanged.selector,
                "maxClockDuration",
                uint256(1 hours),
                uint256(releaseClock)
            )
        );
        upgrader.upgrade(_input());
        assertEq(address(dgf.gameImpls(GameTypes.PERMISSIONED_CANNON)), copy);
    }

    /// @notice A game the chain does not run yet has nothing to compare against.
    function test_upgrade_gameNotRunningYet_succeeds() public {
        IDisputeGameFactory dgf = IDisputeGameFactory(address(cts.disputeGameFactory));
        vm.prank(proxyAdminOwner);
        dgf.setImplementation(GameTypes.PERMISSIONED_CANNON, IDisputeGame(address(0)), hex"");
        _handOver();

        upgrader.upgrade(_input());

        assertEq(
            address(dgf.gameImpls(GameTypes.PERMISSIONED_CANNON)),
            address(implementationsOutput.permissionedDisputeGameImpl)
        );
    }

    /// @notice A SuperchainConfig older than the release is upgraded in the same transaction,
    ///         once its ProxyAdmin is handed over too, and the ProxyAdmin goes back.
    function test_upgrade_superchainBehind_succeeds() public {
        bytes[] memory versions = new bytes[](3);
        // Read by the upgrader, then by OPContractsManagerUtils' downgrade check; the third
        // answer is what the upgraded proxy reports to the `_apply` prelude.
        versions[0] = abi.encode("2.4.2");
        versions[1] = abi.encode("2.4.2");
        versions[2] = abi.encode(ISuperchainConfig(implementationsOutput.superchainConfigImpl).version());
        vm.mockCalls(address(superchainConfig), abi.encodeCall(ISuperchainConfig.version, ()), versions);
        address guardian = superchainConfig.guardian();
        _handOver();
        _handOverSuperchain();

        vm.expectEmit(true, true, true, true, address(superchainConfig));
        emit Upgraded(address(implementationsOutput.superchainConfigImpl));
        upgrader.upgrade(_input());

        assertEq(superchainConfig.guardian(), guardian);
        assertEq(upgrader.superchainProxyAdmin().owner(), superchainProxyAdminOwner);
        assertEq(cts.proxyAdmin.owner(), proxyAdminOwner);
    }

    event Upgraded(address indexed implementation);

    function test_upgrade_superchainBehindNotHandedOver_reverts() public {
        vm.mockCall(address(superchainConfig), abi.encodeCall(ISuperchainConfig.version, ()), abi.encode("2.4.2"));
        _handOver();

        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_NotProxyAdminOwner.selector,
                upgrader.superchainProxyAdmin()
            )
        );
        upgrader.upgrade(_input());
    }

    /// @notice An up-to-date SuperchainConfig is left alone, so its ProxyAdmin stays with its
    ///         owner throughout.
    function test_upgrade_superchainCurrentNotHandedOver_succeeds() public {
        _handOver();
        upgrader.upgrade(_input());
        assertEq(upgrader.superchainProxyAdmin().owner(), superchainProxyAdminOwner);
    }

    /// @notice RSK divergence kept from the deploy splitter (PAYROLLUP-191): an upgrade may keep
    ///         PERMISSIONED_CANNON at a zero bond, which a stock OPCMv2 refuses.
    function test_upgrade_zeroPermissionedBond_succeeds() public {
        RSKOPCMSplitterUpgrade.UpgradeInput memory inp = _input();
        inp.disputeGameConfigs[1].initBond = 0;

        IOPContractsManagerV2.UpgradeInput memory stockInput;
        stockInput.systemConfig = cts.systemConfig;
        stockInput.disputeGameConfigs = inp.disputeGameConfigs;
        vm.etch(proxyAdminOwner, hex"00");
        vm.prank(proxyAdminOwner, true);
        (bool ok, bytes memory reason) = address(implementationsOutput.opcmV2).delegatecall(
            abi.encodeCall(IOPContractsManagerV2.upgrade, (stockInput))
        );
        assertFalse(ok);
        assertEq(bytes4(reason), IOPContractsManagerV2.OPContractsManagerV2_InvalidGameConfigs.selector);

        _handOver();
        upgrader.upgrade(inp);
        assertEq(cts.disputeGameFactory.initBonds(GameTypes.PERMISSIONED_CANNON), 0);
    }

    /// @notice The game loop rebuilds every game's args from the input, so the regenerated
    ///         args carry the input's proposer and challenger.
    function test_upgrade_regeneratesGameArgs_succeeds() public {
        address newProposer = makeAddr("newProposer");
        RSKOPCMSplitterUpgrade.UpgradeInput memory inp = _input();
        inp.disputeGameConfigs[1].gameArgs = abi.encode(
            IOPContractsManagerUtils.PermissionedDisputeGameConfig({
                absolutePrestate: absolutePrestate,
                proposer: newProposer,
                challenger: challenger
            })
        );
        _handOver();

        upgrader.upgrade(inp);

        bytes memory args = cts.disputeGameFactory.gameArgs(GameTypes.PERMISSIONED_CANNON);
        assertEq(args.length, 164);
        address argProposer;
        address argChallenger;
        assembly {
            argProposer := shr(96, mload(add(args, add(32, 124))))
            argChallenger := shr(96, mload(add(args, add(32, 144))))
        }
        assertEq(argProposer, newProposer);
        assertEq(argChallenger, challenger);
    }

    function test_upgrade_notDeployer_reverts() public {
        _handOver();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_NotDeployer.selector);
        upgrader.upgrade(_input());
    }

    function test_upgrade_twice_reverts() public {
        _handOver();
        upgrader.upgrade(_input());
        vm.expectRevert(RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_AlreadyFinished.selector);
        upgrader.upgrade(_input());
    }

    function test_upgrade_otherSystemConfig_reverts() public {
        _handOver();
        RSKOPCMSplitterUpgrade.UpgradeInput memory inp = _input();
        inp.systemConfig = ISystemConfig(makeAddr("otherSystemConfig"));
        vm.expectRevert(RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_WrongSystemConfig.selector);
        upgrader.upgrade(inp);
    }

    function test_upgrade_notHandedOver_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_NotProxyAdminOwner.selector, cts.proxyAdmin
            )
        );
        upgrader.upgrade(_input());
    }

    function test_upgrade_unknownInstruction_reverts() public {
        _handOver();
        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_InvalidUpgradeInstruction.selector,
                "overrides.cfg.systemConfigOwner"
            )
        );
        upgrader.upgrade(_withInstruction(_input(), "overrides.cfg.systemConfigOwner", abi.encode(address(1))));
    }

    function test_upgrade_duplicateInstruction_reverts() public {
        _handOver();
        RSKOPCMSplitterUpgrade.UpgradeInput memory inp = _withLockboxOverride(_input(), address(cts.ethLockbox));
        inp = _withLockboxOverride(inp, address(cts.ethLockbox));
        vm.expectRevert(
            abi.encodeWithSelector(
                RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_DuplicateUpgradeInstruction.selector,
                "overrides.cts.ethLockbox"
            )
        );
        upgrader.upgrade(inp);
    }

    function test_upgrade_invalidGameConfigs_reverts() public {
        RSKOPCMSplitterUpgrade.UpgradeInput memory inp = _input();
        inp.disputeGameConfigs[0].initBond = 1; // disabled game with a bond
        _handOver();
        vm.expectRevert(RSKOPCMSplitterBase.RSKOPCMSplitter_InvalidGameConfigs.selector);
        upgrader.upgrade(inp);
    }

    function test_abort_handsProxyAdminsBack_succeeds() public {
        _handOver();
        _handOverSuperchain();

        upgrader.abort();

        assertEq(cts.proxyAdmin.owner(), proxyAdminOwner);
        assertEq(upgrader.superchainProxyAdmin().owner(), superchainProxyAdminOwner);
        assertTrue(upgrader.finished());
        vm.expectRevert(RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_AlreadyFinished.selector);
        upgrader.upgrade(_input());
    }

    /// @notice Aborting before anything was handed over moves nothing.
    function test_abort_nothingHandedOver_succeeds() public {
        upgrader.abort();
        assertEq(cts.proxyAdmin.owner(), proxyAdminOwner);
        assertEq(upgrader.superchainProxyAdmin().owner(), superchainProxyAdminOwner);
    }

    function test_abort_notDeployer_reverts() public {
        _handOver();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(RSKOPCMSplitterUpgrade.RSKOPCMSplitterUpgrade_NotDeployer.selector);
        upgrader.abort();
    }
}
