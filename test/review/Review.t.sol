// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "../Base.sol";
import {FlightDelayInsurance} from "../../src/FlightDelayInsurance.sol";
import {FunctionsFlightOracle} from "../../src/FunctionsFlightOracle.sol";
import {IFlightOracle} from "../../src/IFlightOracle.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @notice Regression / limitation tests from the pre-publication review.
contract ReviewTest is Base {
    bytes32 internal key = keccak256("LH400");
    FlightDelayInsurance.FlightParams internal p;

    function setUp() public override {
        super.setUp();
        p = _params();
        _create(key, p);
    }

    function _adapter() internal returns (FunctionsFlightOracle a, address router) {
        router = makeAddr("router");
        a = new FunctionsFlightOracle(pool, router, admin);
        bytes32 role = pool.ORACLE_ROLE();
        vm.prank(admin);
        pool.grantRole(role, address(a));
    }

    // ── Adapter: an answer the pool rejects must be consumed with StatusFailed, not revert ──
    // (a real Functions router does not retry a reverted callback, so a revert leaves the
    //  request half-open, emits nothing, and lets a stale answer be replayed later)

    function test_Adapter_PoolRejectionConsumesRequest() public {
        (FunctionsFlightOracle a, address router) = _adapter();
        _deposit(lp, 1_000 * USDC);
        _buy(alice, key);
        vm.prank(admin);
        bytes32 req = a.requestStatus(key);

        // DON answers "Delayed 180" one hour after departure: the pool says ReportTooEarly
        vm.warp(p.departure + 1 hours);
        vm.expectEmit(true, true, false, false, address(a));
        emit FunctionsFlightOracle.StatusFailed(req, key, "");
        vm.prank(router);
        a.handleOracleFulfillment(req, abi.encode(uint8(1), uint32(180)), "");
        assertEq(a.pending(req), bytes32(0), "request consumed");

        // the stale answer cannot be replayed once it would be accepted
        vm.warp(p.departure + 3 hours);
        vm.expectRevert(FunctionsFlightOracle.UnknownRequest.selector);
        vm.prank(router);
        a.handleOracleFulfillment(req, abi.encode(uint8(1), uint32(180)), "");
        assertEq(uint8(pool.getFlight(key).state), uint8(FlightDelayInsurance.State.Scheduled));
    }

    function test_Adapter_MalformedResponseConsumesRequest() public {
        (FunctionsFlightOracle a, address router) = _adapter();
        vm.startPrank(admin);
        bytes32 r1 = a.requestStatus(key);
        bytes32 r2 = a.requestStatus(key);
        vm.stopPrank();
        vm.startPrank(router);
        a.handleOracleFulfillment(r1, abi.encode(uint8(7), uint32(0)), ""); // enum out of range
        a.handleOracleFulfillment(r2, hex"01", ""); // wrong length
        vm.stopPrank();
        assertEq(a.pending(r1), bytes32(0));
        assertEq(a.pending(r2), bytes32(0));
    }

    // ── Deploy: ADMIN=0x0 must not hand the pool to nobody ──

    function test_Deploy_RevertZeroAdmin() public {
        vm.setEnv("PRIVATE_KEY", "0xa11ce");
        vm.setEnv("ASSET", vm.toString(address(usdc)));
        vm.setEnv("ADMIN", vm.toString(address(0)));
        Deploy d = new Deploy();
        vm.expectRevert();
        d.run();
    }

    // ── Known limitation (documented, not fixed): LP can exit before a publicly known loss ──

    function test_Limitation_LPExitsBeforeKnownLoss() public {
        uint256 lpShares = _deposit(lp, 1_000 * USDC);
        uint256 bobShares = _deposit(bob, 1_000 * USDC);
        for (uint256 i; i < 10; ++i) {
            _buy(alice, key); // 10 x 100 cover, 100 premium
        }
        // flight is visibly 3h late; oracle has not reported yet
        vm.warp(p.departure + 3 hours);
        vm.prank(lp);
        uint256 out = pool.withdraw(lpShares);
        assertGt(out, 1_000 * USDC, "lp exits with profit");

        vm.prank(oracle);
        pool.reportFlight(key, IFlightOracle.FlightStatus.Delayed, 180);
        // bob absorbs the whole 1000 payout
        assertLt(pool.previewWithdraw(bobShares), 100 * USDC);
    }

    // ── Info: repeated total wipe-outs overflow share maths and brick deposits ──

    function test_Limitation_TotalWipeoutsOverflowShares() public {
        uint256 deposit = 900 * USDC; // exactly 10 policies of (cover 100 - premium 10)
        bool bricked;
        for (uint256 cycle; cycle < 10 && !bricked; ++cycle) {
            usdc.mint(lp, deposit);
            vm.startPrank(lp);
            usdc.approve(address(pool), deposit);
            try pool.deposit(deposit) {}
            catch {
                bricked = true;
            }
            vm.stopPrank();
            if (bricked) break;
            bytes32 k = keccak256(abi.encode("wipe", cycle));
            _create(k, _params());
            for (uint256 i; i < 10; ++i) {
                _buy(alice, k);
            }
            vm.prank(oracle);
            pool.reportFlight(k, IFlightOracle.FlightStatus.Cancelled, 0);
            assertEq(pool.totalLiquidity(), 0);
        }
        assertTrue(bricked, "deposit overflowed after repeated wipe-outs");
    }
}
