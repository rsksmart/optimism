// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";

import {DeployImplementations} from "scripts/deploy/DeployImplementations.s.sol";

import {Claim, GameType, GameTypes, Hash} from "src/dispute/lib/Types.sol";
import {Constants} from "src/libraries/Constants.sol";

import {ISemver} from "interfaces/universal/ISemver.sol";
import {IProxyAdmin} from "interfaces/universal/IProxyAdmin.sol";
import {ISystemConfig} from "interfaces/L1/ISystemConfig.sol";
import {ISuperchainConfig} from "interfaces/L1/ISuperchainConfig.sol";
import {IOptimismPortal2} from "interfaces/L1/IOptimismPortal2.sol";
import {IResourceMetering} from "interfaces/L1/IResourceMetering.sol";
import {IOPContractsManagerContainer} from "interfaces/L1/opcm/IOPContractsManagerContainer.sol";
import {IOPContractsManagerUtils} from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import {IOPContractsManagerV2} from "interfaces/L1/opcm/IOPContractsManagerV2.sol";
import {IAnchorStateRegistry} from "interfaces/dispute/IAnchorStateRegistry.sol";
import {IDelayedWETH} from "interfaces/dispute/IDelayedWETH.sol";
import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {IFaultDisputeGame} from "interfaces/dispute/IFaultDisputeGame.sol";
import {IMIPS64} from "interfaces/cannon/IMIPS64.sol";
import {ISP1Verifier} from "interfaces/vendor/ISP1Verifier.sol";

import {RSKOPCMSplitterUpgrade} from "../contracts/RSKOPCMSplitterUpgrade.sol";
// LOAD-BEARING: RSKOPCTestBase.sol imports every source DeployImplementations loads by artifact
// name. Without it `_deployRelease` fails with "no matching artifact found".
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

/// @notice Runs RSKOPCMSplitterUpgrade against a live chain in a fork of its L1: a dry run before
///         upgrading the real one. Skipped unless RSK_UPGRADE_FORK_URL is set.
///
///         RSK_UPGRADE_FORK_URL       L1 RPC to fork.
///         RSK_UPGRADE_FORK_BLOCK     block to fork at (default: latest).
///         RSK_UPGRADE_SYSTEM_CONFIG  the chain's SystemConfig proxy.
///         RSK_UPGRADE_OPCM_V2        an OPCMv2 9.0.2 already on that L1. Without it the test
///                                    deploys the 9.0.2 implementations in the fork with the
///                                    chain's delays and game parameters.
///         RSK_UPGRADE_ETH_LOCKBOX    an unused ETHLockbox proxy to adopt
///                                    (`overrides.cts.ethLockbox`). Without it a portal with no
///                                    lockbox gets a new one, as upstream does.
///
///         The input is rebuilt from the chain: the games the factory runs, with their bonds and
///         the prestate, proposer and challenger in their args. Only PERMISSIONED_CANNON args
///         are rebuilt; another enabled game fails the test.
contract RSKOPCMSplitterUpgradeFork_Test is Test {
    /// @notice RSKj's per-transaction gas cap (RSKIP144 sublist limit).
    uint256 internal constant RSK_TX_GAS_CAP = 6_800_000;

    struct ForkChain {
        ISystemConfig systemConfig;
        IProxyAdmin proxyAdmin;
        IProxyAdmin superchainProxyAdmin;
        ISuperchainConfig superchainConfig;
        IOptimismPortal2 portal;
        IAnchorStateRegistry anchorStateRegistry;
        IDelayedWETH delayedWETH;
        IDisputeGameFactory disputeGameFactory;
    }

    struct Live {
        address proxyAdminOwner;
        address superchainProxyAdminOwner;
        address disputeGameFactoryOwner;
        address guardian;
        uint256[3] delays;
        uint256 custody;
        GameType respectedGameType;
        Hash anchorRoot;
        uint256 anchorSequenceNumber;
        bytes32 systemConfigFields;
        IOPContractsManagerUtils.DisputeGameConfig[] games;
    }

    ForkChain internal chain;
    Live internal live;

    function test_upgrade_liveChain_succeeds() public {
        string memory url = vm.envOr("RSK_UPGRADE_FORK_URL", string(""));
        vm.skip(bytes(url).length == 0);
        uint256 forkBlock = vm.envOr("RSK_UPGRADE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, forkBlock);

        _loadChain(ISystemConfig(vm.envAddress("RSK_UPGRADE_SYSTEM_CONFIG")));
        _readLive();

        IOPContractsManagerV2 opcm = IOPContractsManagerV2(vm.envOr("RSK_UPGRADE_OPCM_V2", address(0)));
        if (address(opcm) == address(0)) opcm = _deployRelease();

        RSKOPCMSplitterUpgrade upgrader = new RSKOPCMSplitterUpgrade(opcm, chain.systemConfig);
        vm.prank(live.proxyAdminOwner);
        chain.proxyAdmin.transferOwnership(address(upgrader));
        if (chain.superchainProxyAdmin != chain.proxyAdmin) {
            vm.prank(live.superchainProxyAdminOwner);
            chain.superchainProxyAdmin.transferOwnership(address(upgrader));
        }

        upgrader.upgrade(_input());
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("upgrade gas (Ethereum schedule, not RSKj's)", gasUsed);
        assertLt(gasUsed, RSK_TX_GAS_CAP);

        _assertUpgraded(opcm);
    }

    function _loadChain(ISystemConfig _systemConfig) internal {
        chain.systemConfig = _systemConfig;
        chain.proxyAdmin = _systemConfig.proxyAdmin();
        chain.superchainConfig = _systemConfig.superchainConfig();
        chain.superchainProxyAdmin = chain.superchainConfig.proxyAdmin();
        chain.portal = IOptimismPortal2(payable(_systemConfig.optimismPortal()));
        chain.anchorStateRegistry = chain.portal.anchorStateRegistry();
        chain.delayedWETH = IDelayedWETH(payable(_systemConfig.delayedWETH()));
        chain.disputeGameFactory = IDisputeGameFactory(_systemConfig.disputeGameFactory());
    }

    function _readLive() internal {
        live.proxyAdminOwner = chain.proxyAdmin.owner();
        live.superchainProxyAdminOwner = chain.superchainProxyAdmin.owner();
        live.disputeGameFactoryOwner = chain.disputeGameFactory.owner();
        live.guardian = chain.superchainConfig.guardian();
        live.delays = _delays();
        address lockbox = address(chain.portal.ethLockbox());
        live.custody = address(chain.portal).balance + (lockbox == address(0) ? 0 : lockbox.balance);
        live.respectedGameType = chain.anchorStateRegistry.respectedGameType();
        (live.anchorRoot, live.anchorSequenceNumber) = chain.anchorStateRegistry.getAnchorRoot();
        live.systemConfigFields = _systemConfigFields();

        GameType[6] memory gameTypes = [
            GameTypes.CANNON,
            GameTypes.PERMISSIONED_CANNON,
            GameTypes.CANNON_KONA,
            GameTypes.SUPER_PERMISSIONED,
            GameTypes.SUPER_CANNON_KONA,
            GameTypes.ZK_DISPUTE_GAME
        ];
        delete live.games;
        for (uint256 i = 0; i < gameTypes.length; i++) {
            live.games.push();
            live.games[i].gameType = gameTypes[i];
            if (address(chain.disputeGameFactory.gameImpls(gameTypes[i])) == address(0)) continue;
            assertEq(gameTypes[i].raw(), GameTypes.PERMISSIONED_CANNON.raw(), "only PERMISSIONED_CANNON is rebuilt");
            (bytes32 prestate,, address proposer, address challenger) = _permissionedArgs();
            live.games[i].enabled = true;
            live.games[i].initBond = chain.disputeGameFactory.initBonds(gameTypes[i]);
            live.games[i].gameArgs = abi.encode(
                IOPContractsManagerUtils.PermissionedDisputeGameConfig({
                    absolutePrestate: Claim.wrap(prestate),
                    proposer: proposer,
                    challenger: challenger
                })
            );
        }
    }

    function _input() internal view returns (RSKOPCMSplitterUpgrade.UpgradeInput memory inp_) {
        inp_.systemConfig = chain.systemConfig;
        inp_.disputeGameConfigs = live.games;
        address lockbox = vm.envOr("RSK_UPGRADE_ETH_LOCKBOX", address(0));
        inp_.extraInstructions = new IOPContractsManagerUtils.ExtraInstruction[](1);
        if (lockbox != address(0)) {
            inp_.extraInstructions[0] =
                IOPContractsManagerUtils.ExtraInstruction({key: "overrides.cts.ethLockbox", data: abi.encode(lockbox)});
        } else if (address(chain.portal.ethLockbox()) == address(0)) {
            inp_.extraInstructions[0] = IOPContractsManagerUtils.ExtraInstruction({
                key: Constants.PERMITTED_PROXY_DEPLOYMENT_KEY,
                data: bytes("ETHLockbox")
            });
        } else {
            inp_.extraInstructions = new IOPContractsManagerUtils.ExtraInstruction[](0);
        }
    }

    /// @dev The release the deployer would put on the L1: 9.0.2 implementations built with the
    ///      chain's delays, the live game's depths and clocks and its preimage oracle settings.
    function _deployRelease() internal returns (IOPContractsManagerV2) {
        IFaultDisputeGame game =
            IFaultDisputeGame(address(chain.disputeGameFactory.gameImpls(GameTypes.PERMISSIONED_CANNON)));
        (, address mips,, address challenger) = _permissionedArgs();
        DeployImplementations.Output memory out = new DeployImplementations().run(
            DeployImplementations.Input({
                withdrawalDelaySeconds: live.delays[2],
                minProposalSizeBytes: IMIPS64(mips).oracle().minProposalSize(),
                challengePeriodSeconds: IMIPS64(mips).oracle().challengePeriod(),
                proofMaturityDelaySeconds: live.delays[0],
                disputeGameFinalityDelaySeconds: live.delays[1],
                mipsVersion: IMIPS64(mips).stateVersion(),
                devFeatureBitmap: bytes32(0),
                faultGameV2MaxGameDepth: game.maxGameDepth(),
                faultGameV2SplitDepth: game.splitDepth(),
                faultGameV2ClockExtension: game.clockExtension().raw(),
                faultGameV2MaxClockDuration: game.maxClockDuration().raw(),
                superchainConfigProxy: chain.superchainConfig,
                superchainProxyAdmin: chain.superchainProxyAdmin,
                l1ProxyAdminOwner: live.proxyAdminOwner,
                challenger: challenger,
                sp1Verifier: ISP1Verifier(address(0))
            })
        );
        return out.opcmV2;
    }

    function _assertUpgraded(IOPContractsManagerV2 _opcm) internal view {
        IOPContractsManagerContainer.Implementations memory impls = _opcm.contractsContainer().implementations();
        _assertVersion(address(chain.systemConfig), impls.systemConfigImpl);
        _assertVersion(address(chain.portal), impls.optimismPortalImpl);
        _assertVersion(address(chain.portal.ethLockbox()), impls.ethLockboxImpl);
        _assertVersion(chain.systemConfig.l1CrossDomainMessenger(), impls.l1CrossDomainMessengerImpl);
        _assertVersion(chain.systemConfig.l1StandardBridge(), impls.l1StandardBridgeImpl);
        _assertVersion(chain.systemConfig.l1ERC721Bridge(), impls.l1ERC721BridgeImpl);
        _assertVersion(chain.systemConfig.optimismMintableERC20Factory(), impls.optimismMintableERC20FactoryImpl);
        _assertVersion(address(chain.disputeGameFactory), impls.disputeGameFactoryImpl);
        _assertVersion(address(chain.anchorStateRegistry), impls.anchorStateRegistryImpl);
        _assertVersion(address(chain.delayedWETH), impls.delayedWETHImpl);
        _assertVersion(address(chain.superchainConfig), impls.superchainConfigImpl);
        assertEq(chain.systemConfig.lastUsedOPCM(), address(_opcm), "lastUsedOPCM");
        assertEq(chain.systemConfig.lastUsedOPCMVersion(), "9.0.2", "lastUsedOPCMVersion");

        // Roles and configuration are the chain's, not the upgrader's.
        assertEq(chain.proxyAdmin.owner(), live.proxyAdminOwner, "ProxyAdmin owner");
        assertEq(chain.superchainProxyAdmin.owner(), live.superchainProxyAdminOwner, "superchain ProxyAdmin owner");
        assertEq(chain.disputeGameFactory.owner(), live.disputeGameFactoryOwner, "DisputeGameFactory owner");
        assertEq(chain.superchainConfig.guardian(), live.guardian, "guardian");
        assertEq(_systemConfigFields(), live.systemConfigFields, "SystemConfig fields");
        uint256[3] memory delays = _delays();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(delays[i], live.delays[i], "delay");
        }

        // Custody moved to the lockbox, which the portal and the DelayedWETH now use.
        address lockbox = address(chain.portal.ethLockbox());
        address adopted = vm.envOr("RSK_UPGRADE_ETH_LOCKBOX", address(0));
        if (adopted != address(0)) assertEq(lockbox, adopted, "adopted lockbox");
        assertEq(address(chain.portal).balance, 0, "portal balance");
        assertEq(lockbox.balance, live.custody, "lockbox balance");
        assertTrue(chain.portal.ethLockbox().authorizedPortals(chain.portal), "portal authorized");

        // Anchor and games carry over.
        assertEq(chain.anchorStateRegistry.respectedGameType().raw(), live.respectedGameType.raw(), "respected game");
        (Hash root, uint256 sequenceNumber) = chain.anchorStateRegistry.getAnchorRoot();
        assertEq(root.raw(), live.anchorRoot.raw(), "anchor root");
        assertEq(sequenceNumber, live.anchorSequenceNumber, "anchor sequence number");
        for (uint256 i = 0; i < live.games.length; i++) {
            GameType gameType = live.games[i].gameType;
            assertEq(chain.disputeGameFactory.initBonds(gameType), live.games[i].initBond, "init bond");
            assertEq(
                address(chain.disputeGameFactory.gameImpls(gameType)) != address(0), live.games[i].enabled, "game"
            );
        }
        if (live.games[1].enabled) {
            (bytes32 prestate,, address proposer, address challenger) = _permissionedArgs();
            assertEq(
                keccak256(live.games[1].gameArgs),
                keccak256(
                    abi.encode(
                        IOPContractsManagerUtils.PermissionedDisputeGameConfig({
                            absolutePrestate: Claim.wrap(prestate),
                            proposer: proposer,
                            challenger: challenger
                        })
                    )
                ),
                "permissioned game args"
            );
        }
    }

    function _assertVersion(address _proxy, address _impl) internal view {
        assertEq(ISemver(_proxy).version(), ISemver(_impl).version(), vm.toString(_proxy));
    }

    function _delays() internal view returns (uint256[3] memory) {
        return [
            chain.portal.proofMaturityDelaySeconds(),
            chain.anchorStateRegistry.disputeGameFinalityDelaySeconds(),
            chain.delayedWETH.delay()
        ];
    }

    function _systemConfigFields() internal view returns (bytes32) {
        ISystemConfig sc = chain.systemConfig;
        IResourceMetering.ResourceConfig memory resourceConfig = sc.resourceConfig();
        return keccak256(
            abi.encode(
                sc.owner(),
                sc.batcherHash(),
                sc.gasLimit(),
                sc.basefeeScalar(),
                sc.blobbasefeeScalar(),
                sc.unsafeBlockSigner(),
                sc.l2ChainId(),
                address(sc.superchainConfig()),
                resourceConfig
            )
        );
    }

    /// @dev The live PERMISSIONED_CANNON args: prestate | vm | asr | weth | chain id | proposer |
    ///      challenger, packed (OPContractsManagerUtils.makeGameArgs).
    function _permissionedArgs()
        internal
        view
        returns (bytes32 prestate_, address vm_, address proposer_, address challenger_)
    {
        bytes memory args = chain.disputeGameFactory.gameArgs(GameTypes.PERMISSIONED_CANNON);
        require(args.length == 164, "unexpected PERMISSIONED_CANNON args length");
        assembly {
            prestate_ := mload(add(args, 32))
            vm_ := shr(96, mload(add(args, 64)))
            proposer_ := shr(96, mload(add(args, 156)))
            challenger_ := shr(96, mload(add(args, 176)))
        }
    }
}
