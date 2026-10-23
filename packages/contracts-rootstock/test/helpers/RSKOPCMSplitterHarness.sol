// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IOPContractsManagerV2} from "interfaces/L1/opcm/IOPContractsManagerV2.sol";

import {RSKOPCMSplitter} from "../../contracts/RSKOPCMSplitter.sol";

/// @notice Exposes `_assertValidFullConfig`. Both RSK divergences revert with the same error as
///         the rules around them, and only upgrade mode (`_isInitialDeployment = false`) can
///         reach the bond rule without the initial-deploy game rule.
contract RSKOPCMSplitter_Harness is RSKOPCMSplitter {
    constructor(IOPContractsManagerV2 _opcmV2) RSKOPCMSplitter(_opcmV2) {}

    function assertValidFullConfig(FullConfig memory _cfg, bool _isInitialDeployment) external view {
        _assertValidFullConfig(_cfg, _isInitialDeployment);
    }
}
