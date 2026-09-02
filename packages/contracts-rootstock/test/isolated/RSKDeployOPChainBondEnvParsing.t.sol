// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";

import {RSKDeployOPChain} from "../../script/RSKDeployOPChain.s.sol";

/// @notice Checks that RSKDeployOPChain.initBond() parses
///         RSK_DISPUTE_GAME_INIT_BOND_WEI, the override
///         rskdeployer.DeployOPChainSplit injects.
/// @dev MUST run in its own forge invocation — see test/isolated/README.md.
///      `vm.setEnv` writes the process-global environment and forge executes
///      test functions in parallel, so a `setEnv` here would otherwise both
///      be clobbered by a concurrent suite and leak its value into one,
///      making unrelated tests flake. Nothing here touches the OPCM fixture,
///      so this file needs no setUp fixture and is cheap to run separately.
///
///      The unset-means-default half of the contract is NOT asserted here:
///      forge has no vm.unsetEnv, and any in-process attempt passes
///      vacuously once another test has written the variable. It is covered
///      where it actually lives — rskdeployer's setInitBondEnv(nil) unsets
///      the variable (TestSetInitBondEnv) and the parallel-suite tests deploy
///      with the compiled-in default.
contract RSKDeployOPChainBondEnvParsing_Test is Test {
    string internal constant BOND_ENV = "RSK_DISPUTE_GAME_INIT_BOND_WEI";

    RSKDeployOPChain internal script;

    function setUp() public {
        script = new RSKDeployOPChain();
    }

    function test_initBond_parsesEnvOverride() public {
        vm.setEnv(BOND_ENV, "0");
        assertEq(script.initBond(), 0);

        vm.setEnv(BOND_ENV, "12345");
        assertEq(script.initBond(), 12345);

        // 0.08 ether: the decimal encoding rskdeployer emits when the
        // configured bond happens to equal the script default.
        vm.setEnv(BOND_ENV, "80000000000000000");
        assertEq(script.initBond(), script.DEFAULT_INIT_BOND());
    }
}
