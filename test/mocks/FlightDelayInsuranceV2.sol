// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FlightDelayInsurance} from "../../src/FlightDelayInsurance.sol";

/// @notice Upgrade target used to prove state survives a UUPS upgrade.
contract FlightDelayInsuranceV2 is FlightDelayInsurance {
    function version() external pure returns (uint256) {
        return 2;
    }
}
