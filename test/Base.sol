// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FlightDelayInsurance} from "../src/FlightDelayInsurance.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Shared deployment: proxy + 6-decimal stablecoin + roles.
abstract contract Base is Test {
    uint64 internal constant REPORT_WINDOW = 2 days;
    uint256 internal constant USDC = 1e6;

    FlightDelayInsurance internal pool;
    FlightDelayInsurance internal impl;
    MockUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal oracle = makeAddr("oracle");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        impl = new FlightDelayInsurance();
        bytes memory init =
            abi.encodeCall(FlightDelayInsurance.initialize, (IERC20(address(usdc)), admin, REPORT_WINDOW));
        pool = FlightDelayInsurance(address(new ERC1967Proxy(address(impl), init)));
        bytes32 oracleRole = pool.ORACLE_ROLE();
        vm.prank(admin);
        pool.grantRole(oracleRole, oracle);
    }

    /// @dev Departure in 3 days, sales close 1h before; premium 10, cover 100;
    ///      >=60min 25%, >=180min 100%, cancelled 100%; up to 50 policies.
    function _params() internal view returns (FlightDelayInsurance.FlightParams memory p) {
        p.departure = uint64(block.timestamp + 3 days);
        p.saleCutoff = p.departure - 1 hours;
        p.premium = uint128(10 * USDC);
        p.coverage = uint128(100 * USDC);
        p.maxExposure = uint128(5_000 * USDC);
        p.delayThresholds = new uint32[](2);
        p.delayThresholds[0] = 60;
        p.delayThresholds[1] = 180;
        p.delayBps = new uint16[](2);
        p.delayBps[0] = 2_500;
        p.delayBps[1] = 10_000;
        p.cancelBps = 10_000;
    }

    function _create(bytes32 key, FlightDelayInsurance.FlightParams memory p) internal {
        vm.prank(admin);
        pool.createFlight(key, p);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        shares = pool.deposit(amount);
        vm.stopPrank();
    }

    function _buy(address who, bytes32 key) internal returns (uint256 id) {
        uint256 premium = pool.getFlight(key).params.premium;
        usdc.mint(who, premium);
        vm.startPrank(who);
        usdc.approve(address(pool), premium);
        id = pool.buyPolicy(key);
        vm.stopPrank();
    }
}
