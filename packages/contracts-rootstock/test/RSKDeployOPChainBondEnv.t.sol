// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {GameTypes} from "src/dispute/lib/Types.sol";

import {RSKDeployOPChain} from "../script/RSKDeployOPChain.s.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

/// @notice Fixes the bond to a constructor-supplied value instead of reading
///         the env, so full runSplit deploys can be tested without touching
///         process-global state. The virtual dispatch also proves
///         _toFullConfig sources the bond from initBond() rather than from
///         DEFAULT_INIT_BOND directly.
contract RSKDeployOPChainBondHarness is RSKDeployOPChain {
    uint256 internal immutable BOND_OVERRIDE;

    constructor(uint256 _bond) {
        BOND_OVERRIDE = _bond;
    }

    function initBond() public view override returns (uint256) {
        return BOND_OVERRIDE;
    }
}

/// @notice Deploy-wiring tests for the init-bond override that
///         rskdeployer.DeployOPChainSplit drives via
///         RSK_DISPUTE_GAME_INIT_BOND_WEI.
/// @dev Nothing here calls `vm.setEnv`: forge runs test functions in parallel
///      over one process environment, so env mutation belongs in its own
///      invocation (see test/isolated/). The harness above covers the same
///      code path deterministically; the env parsing itself is asserted in
///      test/isolated/RSKDeployOPChainBondEnvParsing.t.sol.
contract RSKDeployOPChainBondEnv_Test is RSKOPCTestBase {
    function test_runSplit_bondZero_deploysZeroBond() public {
        RSKDeployOPChain script = new RSKDeployOPChainBondHarness(0);
        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), 0);
        assertEq(dgf.initBonds(GameTypes.SUPER_PERMISSIONED_CANNON), 0);
    }

    function test_runSplit_bondCustom_deploysCustomBond() public {
        RSKDeployOPChain script = new RSKDeployOPChainBondHarness(12345);
        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), 12345);
        // Disabled game types keep a zero bond regardless of the override.
        assertEq(dgf.initBonds(GameTypes.SUPER_PERMISSIONED_CANNON), 0);
    }

    /// @notice The unset case: an unmodified script must deploy the upstream
    ///         default, which is what an absent dispute_game_init_bond_wei
    ///         has to preserve.
    function test_runSplit_noOverride_deploysUpstreamDefault() public {
        RSKDeployOPChain script = new RSKDeployOPChain();
        RSKDeployOPChain.Output memory output_ = script.runSplit(deployInput);

        IDisputeGameFactory dgf = IDisputeGameFactory(address(output_.disputeGameFactoryProxy));
        assertEq(dgf.initBonds(GameTypes.PERMISSIONED_CANNON), DEFAULT_INIT_BOND);
    }
}
