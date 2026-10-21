// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";

import {DeployOPChain} from "scripts/deploy/DeployOPChain.s.sol";
import {IOPContractsManagerUtils} from "interfaces/L1/opcm/IOPContractsManagerUtils.sol";
import {IResourceMetering} from "interfaces/L1/IResourceMetering.sol";
import {GameType} from "src/dispute/lib/Types.sol";
import {Constants} from "src/libraries/Constants.sol";

import {RSKDeployOPChain} from "../script/RSKDeployOPChain.s.sol";

contract DeployOPChain_Harness is DeployOPChain {
    function resourceConfigForGasLimit(uint64 _gasLimit)
        external
        pure
        returns (IResourceMetering.ResourceConfig memory)
    {
        return _resourceConfigForGasLimit(_gasLimit);
    }

    function createGameConfig(bool _enabled, uint256 _initBond, GameType _gameType, bytes memory _enabledArgs)
        external
        pure
        returns (IOPContractsManagerUtils.DisputeGameConfig memory)
    {
        return _createGameConfig(_enabled, _initBond, _gameType, _enabledArgs);
    }
}

contract RSKDeployOPChain_Harness is RSKDeployOPChain {
    function resourceConfigForGasLimit(uint64 _gasLimit)
        external
        pure
        returns (IResourceMetering.ResourceConfig memory)
    {
        return _resourceConfigForGasLimit(_gasLimit);
    }

    function createGameConfig(bool _enabled, uint256 _initBond, GameType _gameType, bytes memory _enabledArgs)
        external
        pure
        returns (IOPContractsManagerUtils.DisputeGameConfig memory)
    {
        return _createGameConfig(_enabled, _initBond, _gameType, _enabledArgs);
    }
}

/// @notice RSKDeployOPChain cannot inherit upstream's DeployOPChain: upstream's
///         `runWithBytes`, `checkInput` and `checkOutput` are public, non-virtual and share
///         our signatures. These tests pin the pieces RSKDeployOPChain ports verbatim to
///         upstream's, so an upstream change that the next sync does not port fails here.
contract RSKDeployOPChainParity_Test is Test {
    DeployOPChain_Harness internal upstream;
    RSKDeployOPChain_Harness internal rsk;

    function setUp() public {
        upstream = new DeployOPChain_Harness();
        rsk = new RSKDeployOPChain_Harness();
    }

    /// @notice Same config for every gas limit, or both revert. The bound covers both branches
    ///         and the threshold between them.
    function testFuzz_resourceConfigForGasLimit_matchesUpstream_succeeds(uint64 _gasLimit) public view {
        IResourceMetering.ResourceConfig memory defaults = Constants.DEFAULT_RESOURCE_CONFIG();
        uint64 reserved = uint64(defaults.maxResourceLimit) + uint64(defaults.systemTxMaxGas);
        _gasLimit = uint64(bound(_gasLimit, 0, 2 * reserved));

        _assertSameResult(
            abi.encodeCall(DeployOPChain_Harness.resourceConfigForGasLimit, (_gasLimit)),
            abi.encodeCall(RSKDeployOPChain_Harness.resourceConfigForGasLimit, (_gasLimit))
        );
    }

    function testFuzz_createGameConfig_matchesUpstream_succeeds(
        bool _enabled,
        uint256 _initBond,
        uint32 _gameType,
        bytes memory _enabledArgs
    )
        public
        view
    {
        GameType gameType = GameType.wrap(_gameType);
        _assertSameResult(
            abi.encodeCall(DeployOPChain_Harness.createGameConfig, (_enabled, _initBond, gameType, _enabledArgs)),
            abi.encodeCall(RSKDeployOPChain_Harness.createGameConfig, (_enabled, _initBond, gameType, _enabledArgs))
        );
    }

    function test_defaultInitBond_matchesUpstream_succeeds() public view {
        assertEq(rsk.DEFAULT_INIT_BOND(), upstream.DEFAULT_INIT_BOND());
    }

    /// @notice The Go side decodes RSKDeployOPChain's output as upstream's `Output`, so every
    ///         field must sit at the same position. Each field gets a distinct address and is
    ///         compared by name; an added field makes the decode revert.
    function test_output_decodesAsUpstreamOutput_succeeds() public pure {
        uint256[15] memory addrs;
        for (uint256 i = 0; i < addrs.length; i++) {
            addrs[i] = i + 1;
        }
        bytes memory encoded = abi.encode(addrs);

        RSKDeployOPChain.Output memory r = abi.decode(encoded, (RSKDeployOPChain.Output));
        DeployOPChain.Output memory u = abi.decode(encoded, (DeployOPChain.Output));

        assertEq(address(r.opChainProxyAdmin), address(u.opChainProxyAdmin));
        assertEq(address(r.addressManager), address(u.addressManager));
        assertEq(address(r.l1ERC721BridgeProxy), address(u.l1ERC721BridgeProxy));
        assertEq(address(r.systemConfigProxy), address(u.systemConfigProxy));
        assertEq(address(r.optimismMintableERC20FactoryProxy), address(u.optimismMintableERC20FactoryProxy));
        assertEq(address(r.l1StandardBridgeProxy), address(u.l1StandardBridgeProxy));
        assertEq(address(r.l1CrossDomainMessengerProxy), address(u.l1CrossDomainMessengerProxy));
        assertEq(address(r.optimismPortalProxy), address(u.optimismPortalProxy));
        assertEq(address(r.ethLockboxProxy), address(u.ethLockboxProxy));
        assertEq(address(r.disputeGameFactoryProxy), address(u.disputeGameFactoryProxy));
        assertEq(address(r.anchorStateRegistryProxy), address(u.anchorStateRegistryProxy));
        assertEq(address(r.faultDisputeGame), address(u.faultDisputeGame));
        assertEq(address(r.permissionedDisputeGame), address(u.permissionedDisputeGame));
        assertEq(address(r.delayedWETHPermissionedGameProxy), address(u.delayedWETHPermissionedGameProxy));
        assertEq(address(r.delayedWETHPermissionlessGameProxy), address(u.delayedWETHPermissionlessGameProxy));
        assertEq(abi.encode(u), encoded);
    }

    function _assertSameResult(bytes memory _upstreamCall, bytes memory _rskCall) internal view {
        (bool upstreamOk, bytes memory upstreamRet) = address(upstream).staticcall(_upstreamCall);
        (bool rskOk, bytes memory rskRet) = address(rsk).staticcall(_rskCall);

        assertEq(rskOk, upstreamOk, "same success");
        if (upstreamOk) {
            assertEq(rskRet, upstreamRet, "same result");
        }
    }
}
