// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {GameTypes} from "src/dispute/lib/Types.sol";

import {RSKDeployOPChain} from "../script/RSKDeployOPChain.s.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

/// @notice Tests for the configurable dispute-game init bond that
///         rskdeployer.DeployOPChainSplit supplies from
///         `[deployer].dispute_game_init_bond_wei`.
/// @dev The bond is an ordinary argument, so these are ordinary tests: no
///      process-global state, no harness, no quarantined invocation. The Go
///      side resolves the effective value (config or default) and passes it,
///      which is why the script itself has no notion of "unset".
contract RSKDeployOPChainInitBond_Test is RSKOPCTestBase {
    function test_runSplitWithBond_zero_deploysZeroBond() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        RSKDeployOPChain.Output memory output_ = script.runSplitWithBond(deployInput, 0);

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), 0);
        assertEq(dgf.initBonds(GameTypes.SUPER_PERMISSIONED_CANNON), 0);
    }

    function test_runSplitWithBond_custom_deploysCustomBond() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        RSKDeployOPChain.Output memory output_ = script.runSplitWithBond(deployInput, 12345);

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), 12345);
        // Disabled game types keep a zero bond regardless of the argument.
        assertEq(dgf.initBonds(GameTypes.SUPER_PERMISSIONED_CANNON), 0);
    }

    /// @notice `runSplit` is the upstream-parity path: no bond argument, so it
    ///         must apply the upstream default. This is what an absent
    ///         dispute_game_init_bond_wei has to preserve.
    function test_runSplit_appliesUpstreamDefaultBond() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), DEFAULT_INIT_BOND);
    }

    /// @notice The RSK entry point carries (input, bond) in one ABI blob;
    ///         rskdeployer packs exactly this shape. A mismatch here is the
    ///         failure mode that would break a real deploy at decode time.
    function test_runSplitWithBytes_decodesInputAndBond() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        bytes memory encoded = script.runSplitWithBytes(abi.encode(deployInput, uint256(777)));
        RSKDeployOPChain.Output memory output_ = abi.decode(encoded, (RSKDeployOPChain.Output));

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), 777);
        // Output must round-trip through the same 15-field shape as runWithBytes.
        assertEq(address(output_.disputeGameFactoryProxy), address(dgf));
        assertGt(address(output_.systemConfigProxy).code.length, 0);
    }

    function test_runSplitWithBytes_emptyInput_reverts() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        vm.expectRevert("RSKDeployOPChain: input cannot be empty");
        script.runSplitWithBytes(bytes(""));
    }

    /// @notice Guards the Go-side default against an upstream bump: rskdeployer
    ///         hard-codes 0.08 ether as DefaultDisputeGameInitBondWei, so if
    ///         upstream ever changes this constant the two must be reconciled
    ///         deliberately rather than drifting apart on a merge.
    function test_defaultInitBond_matchesGoSideConstant() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        assertEq(script.DEFAULT_INIT_BOND(), 80_000_000_000_000_000);
    }
}
