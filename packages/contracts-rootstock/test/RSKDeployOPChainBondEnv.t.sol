// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IDisputeGameFactory} from "interfaces/dispute/IDisputeGameFactory.sol";
import {GameTypes} from "src/dispute/lib/Types.sol";

import {RSKDeployOPChain} from "../script/RSKDeployOPChain.s.sol";
import {RSKOPCTestBase} from "./helpers/RSKOPCTestBase.sol";

/// @notice Fixes the bond to a constructor-supplied value instead of reading
///         the env, so full runSplit deploys can be tested without vm.setEnv.
///         The virtual dispatch also proves _toFullConfig sources the bond
///         from initBond() rather than from the constant directly.
contract RSKDeployOPChainBondHarness is RSKDeployOPChain {
    uint256 internal immutable BOND_OVERRIDE;

    constructor(uint256 _bond) {
        BOND_OVERRIDE = _bond;
    }

    function initBond() public view override returns (uint256) {
        return BOND_OVERRIDE;
    }
}

/// @notice Tests for the RSK_DISPUTE_GAME_INIT_BOND_WEI override injected by
///         rskdeployer.DeployOPChainSplit.
/// @dev vm.setEnv mutates the process-global environment and forge runs test
///      functions in parallel (there is no vm.unsetEnv, and foundry.toml's
///      `threads` key does not serialize the test runner), so wrapping a full
///      runSplit deploy in setEnv races against every other suite whose
///      deploy reads the same variable — that failed deterministically in
///      practice. Instead, env parsing is covered by the quick getter test
///      below (microsecond exposure, and it always leaves the var back at the
///      decimal encoding of DEFAULT_INIT_BOND, which RSKOPCTestBase.setUp
///      also pins), and the deploy wiring is covered via the harness above,
///      which bypasses the env entirely.
contract RSKDeployOPChainBondEnv_Test is RSKOPCTestBase {
    string internal constant BOND_ENV = "RSK_DISPUTE_GAME_INIT_BOND_WEI";
    string internal constant DEFAULT_BOND_DECIMAL = "80000000000000000"; // 0.08 ether

    function test_initBond_readsEnvOverride() public {
        RSKDeployOPChain script = new RSKDeployOPChain();

        vm.setEnv(BOND_ENV, "0");
        assertEq(script.initBond(), 0);

        vm.setEnv(BOND_ENV, "12345");
        assertEq(script.initBond(), 12345);

        vm.setEnv(BOND_ENV, DEFAULT_BOND_DECIMAL);
        assertEq(script.initBond(), script.DEFAULT_INIT_BOND());
    }

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
}
