// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlightDelayInsurance} from "../src/FlightDelayInsurance.sol";
import {FunctionsFlightOracle} from "../src/FunctionsFlightOracle.sol";

/// @notice Deploys the pool behind a UUPS (ERC1967) proxy and, optionally, the oracle adapter.
/// @dev Env:
///   PRIVATE_KEY      deployer key (required)
///   ASSET            stablecoin address (required)
///   ADMIN            final admin, ideally a multisig (default: deployer)
///   REPORT_WINDOW    seconds the oracle has after departure (default 2 days)
///   FUNCTIONS_ROUTER if set, deploy FunctionsFlightOracle with this router and grant it ORACLE_ROLE
contract Deploy is Script {
    function run() external returns (FlightDelayInsurance pool, FunctionsFlightOracle adapter) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN", deployer);
        address router = vm.envOr("FUNCTIONS_ROUTER", address(0));
        uint64 window = uint64(vm.envOr("REPORT_WINDOW", uint256(2 days)));

        vm.startBroadcast(pk);
        FlightDelayInsurance impl = new FlightDelayInsurance();
        bytes memory init =
            abi.encodeCall(FlightDelayInsurance.initialize, (IERC20(vm.envAddress("ASSET")), deployer, window));
        pool = FlightDelayInsurance(address(new ERC1967Proxy(address(impl), init)));

        if (router != address(0)) {
            adapter = new FunctionsFlightOracle(pool, router, admin);
            pool.grantRole(pool.ORACLE_ROLE(), address(adapter));
        }
        // hand over to the final admin last, so the deployer keeps no privileges
        if (admin != deployer) {
            pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), admin);
            pool.grantRole(pool.PAUSER_ROLE(), admin);
            pool.renounceRole(pool.PAUSER_ROLE(), deployer);
            pool.renounceRole(pool.DEFAULT_ADMIN_ROLE(), deployer);
        }
        vm.stopBroadcast();

        console2.log("implementation:", address(impl));
        console2.log("proxy:", address(pool));
        console2.log("oracle adapter:", address(adapter));
    }
}
