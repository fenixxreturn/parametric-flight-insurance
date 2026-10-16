// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Base} from "./Base.sol";
import {FlightDelayInsurance} from "../src/FlightDelayInsurance.sol";
import {IFlightOracle} from "../src/IFlightOracle.sol";
import {FunctionsFlightOracle} from "../src/FunctionsFlightOracle.sol";
import {FlightDelayInsuranceV2} from "./mocks/FlightDelayInsuranceV2.sol";

contract FlightDelayInsuranceTest is Base {
    bytes32 internal key;
    FlightDelayInsurance.FlightParams internal p;

    function setUp() public override {
        super.setUp();
        key = pool.flightKey("LH400", 20231117);
        p = _params();
        _create(key, p);
        _deposit(lp, 1_000 * USDC);
    }

    // ───────────────────────── Init / upgrade ─────────────────────────

    function test_Init_State() public view {
        assertEq(address(pool.asset()), address(usdc));
        assertEq(pool.reportWindow(), REPORT_WINDOW);
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(pool.hasRole(pool.PAUSER_ROLE(), admin));
    }

    function test_Init_RevertTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(IERC20(address(usdc)), admin, REPORT_WINDOW);
    }

    function test_Init_ImplementationLocked() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(IERC20(address(usdc)), admin, REPORT_WINDOW);
    }

    function test_Init_RevertBadArgs() public {
        FlightDelayInsurance i = new FlightDelayInsurance();
        vm.expectRevert(FlightDelayInsurance.ZeroAddress.selector);
        new ERC1967Proxy(address(i), abi.encodeCall(i.initialize, (IERC20(address(0)), admin, REPORT_WINDOW)));
        vm.expectRevert(FlightDelayInsurance.ZeroAddress.selector);
        new ERC1967Proxy(address(i), abi.encodeCall(i.initialize, (IERC20(address(usdc)), address(0), REPORT_WINDOW)));
        vm.expectRevert(FlightDelayInsurance.InvalidParams.selector);
        new ERC1967Proxy(address(i), abi.encodeCall(i.initialize, (IERC20(address(usdc)), admin, 0)));
    }

    function test_Upgrade_PreservesState() public {
        uint256 id = _buy(alice, key);
        uint256 shares = pool.sharesOf(lp);
        FlightDelayInsuranceV2 v2 = new FlightDelayInsuranceV2();
        vm.prank(admin);
        pool.upgradeToAndCall(address(v2), "");

        assertEq(FlightDelayInsuranceV2(address(pool)).version(), 2);
        assertEq(pool.sharesOf(lp), shares);
        assertEq(pool.totalLiquidity(), 1_010 * USDC);
        assertEq(pool.reservedExposure(), 100 * USDC);
        assertEq(pool.getPolicy(id).holder, alice);
        assertTrue(pool.hasRole(pool.ORACLE_ROLE(), oracle));

        // still fully functional after upgrade
        vm.warp(p.departure + 200 minutes);
        vm.prank(oracle);
        pool.reportFlight(key, IFlightOracle.FlightStatus.Delayed, 200);
        pool.claim(id);
        assertEq(usdc.balanceOf(alice), 100 * USDC);
    }

    function test_Upgrade_RevertNonAdmin() public {
        FlightDelayInsuranceV2 v2 = new FlightDelayInsuranceV2();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        pool.upgradeToAndCall(address(v2), "");
    }

    // ───────────────────────── Liquidity ─────────────────────────

    function test_Deposit_MintsShares() public {
        uint256 shares = _deposit(bob, 500 * USDC);
        assertEq(shares, pool.sharesOf(bob));
        assertEq(pool.totalLiquidity(), 1_500 * USDC);
        assertEq(usdc.balanceOf(address(pool)), 1_500 * USDC);
        assertApproxEqAbs(pool.previewWithdraw(shares), 500 * USDC, 1);
    }

    function test_Deposit_RevertZero() public {
        vm.expectRevert(FlightDelayInsurance.ZeroAmount.selector);
        pool.deposit(0);
    }

    function test_Withdraw_Full() public {
        uint256 shares = pool.sharesOf(lp);
        vm.prank(lp);
        uint256 out = pool.withdraw(shares);
        assertApproxEqAbs(out, 1_000 * USDC, 1); // rounds down in the pool's favour
        assertEq(usdc.balanceOf(lp), out);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.totalLiquidity(), 1_000 * USDC - out);
    }

    function test_Withdraw_RevertMoreThanOwned() public {
        uint256 shares = pool.sharesOf(lp);
        vm.expectRevert(FlightDelayInsurance.InsufficientShares.selector);
        vm.prank(lp);
        pool.withdraw(shares + 1);
    }

    function test_Withdraw_RevertZero() public {
        vm.expectRevert(FlightDelayInsurance.ZeroAmount.selector);
        vm.prank(lp);
        pool.withdraw(0);
        // 1 share is worth < 1 base unit -> rounds to zero assets
        vm.expectRevert(FlightDelayInsurance.ZeroAmount.selector);
        vm.prank(lp);
        pool.withdraw(1);
    }

    function test_Withdraw_RevertLockedExposure() public {
        _buy(alice, key); // reserves 100, pool liquidity 1010
        uint256 shares = pool.sharesOf(lp);
        vm.expectPartialRevert(FlightDelayInsurance.InsufficientFreeLiquidity.selector);
        vm.prank(lp);
        pool.withdraw(shares);
        // the unreserved part can leave
        vm.prank(lp);
        pool.withdraw(shares / 2);
        assertGe(pool.totalLiquidity(), pool.reservedExposure());
    }

    function test_InflationAttack_Neutralised() public {
        // fresh pool, attacker front-runs the first real deposit with 1 unit + a huge donation
        FlightDelayInsurance fresh = FlightDelayInsurance(
            address(
                new ERC1967Proxy(address(impl), abi.encodeCall(impl.initialize, (IERC20(address(usdc)), admin, 1 days)))
            )
        );
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1 + 10_000 * USDC);
        vm.startPrank(attacker);
        usdc.approve(address(fresh), 1);
        fresh.deposit(1);
        usdc.transfer(address(fresh), 10_000 * USDC); // donation: not counted in totalLiquidity
        vm.stopPrank();

        usdc.mint(bob, 1_000 * USDC);
        vm.startPrank(bob);
        usdc.approve(address(fresh), 1_000 * USDC);
        uint256 shares = fresh.deposit(1_000 * USDC);
        assertGt(shares, 0);
        assertApproxEqAbs(fresh.withdraw(shares), 1_000 * USDC, 2);
        vm.stopPrank();
    }

    function test_LP_EarnsPremiumsOnTimeFlight() public {
        _buy(alice, key);
        _buy(bob, key);
        vm.warp(p.departure + 10 minutes);
        vm.prank(oracle);
        pool.reportFlight(key, IFlightOracle.FlightStatus.OnTime, 0);
        assertEq(pool.reservedExposure(), 0);
        uint256 shares = pool.sharesOf(lp);
        vm.prank(lp);
        assertApproxEqAbs(pool.withdraw(shares), 1_020 * USDC, 1);
    }

    // ───────────────────────── Products ─────────────────────────

    function test_CreateFlight_Stored() public view {
        FlightDelayInsurance.Flight memory f = pool.getFlight(key);
        assertEq(uint8(f.state), uint8(FlightDelayInsurance.State.Scheduled));
        assertEq(f.params.premium, p.premium);
        assertEq(f.params.delayThresholds.length, 2);
        assertEq(f.params.delayBps[1], 10_000);
    }

    function test_CreateFlight_RevertNonAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        pool.createFlight(bytes32("x"), p);
    }

    function test_CreateFlight_RevertExists() public {
        vm.expectRevert(FlightDelayInsurance.FlightExists.selector);
        vm.prank(admin);
        pool.createFlight(key, p);
    }

    function test_CreateFlight_RevertInvalid() public {
        FlightDelayInsurance.FlightParams memory q;
        for (uint256 i; i < 13; ++i) {
            q = _params();
            if (i == 0) q.premium = 0;
            if (i == 1) q.premium = q.coverage;
            if (i == 2) q.maxExposure = q.coverage - 1;
            if (i == 3) q.saleCutoff = uint64(block.timestamp);
            if (i == 4) q.saleCutoff = q.departure + 1;
            if (i == 5) q.delayThresholds = new uint32[](0);
            if (i == 6) q.delayBps = new uint16[](1);
            if (i == 7) q.delayThresholds[1] = 60; // not strictly ascending
            if (i == 8) q.delayBps[1] = 2_000; // decreasing payout
            if (i == 9) q.delayBps[1] = 10_001;
            if (i == 10) q.cancelBps = 10_001;
            if (i == 11) q.delayThresholds[1] = uint32(REPORT_WINDOW / 60); // unreportable tier
            if (i == 12) q.delayThresholds[0] = 0;
            vm.expectRevert(FlightDelayInsurance.InvalidParams.selector);
            vm.prank(admin);
            pool.createFlight(bytes32(i + 100), q);
        }
        q = _params();
        q.delayThresholds = new uint32[](5);
        q.delayBps = new uint16[](5);
        vm.expectRevert(FlightDelayInsurance.InvalidParams.selector);
        vm.prank(admin);
        pool.createFlight(bytes32("too-many"), q);
    }

    // ───────────────────────── Buying ─────────────────────────

    function test_Buy_ReservesExposure() public {
        usdc.mint(alice, 10 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(pool), 10 * USDC);
        vm.expectEmit(address(pool));
        emit FlightDelayInsurance.PolicyPurchased(1, key, alice, 10 * USDC);
        uint256 id = pool.buyPolicy(key);
        vm.stopPrank();
        assertEq(id, 1);
        assertEq(pool.reservedExposure(), 100 * USDC);
        assertEq(pool.totalLiquidity(), 1_010 * USDC);
        assertEq(pool.freeLiquidity(), 910 * USDC);
        assertEq(pool.getFlight(key).sold, 1);
        FlightDelayInsurance.Policy memory pol = pool.getPolicy(id);
        assertEq(pol.holder, alice);
        assertEq(pol.flightKey, key);
    }

    function test_Buy_RevertAfterCutoff() public {
        vm.warp(p.saleCutoff + 1);
        usdc.mint(alice, 10 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(pool), 10 * USDC);
        vm.expectRevert(FlightDelayInsurance.SalesClosed.selector);
        pool.buyPolicy(key);
        vm.stopPrank();
    }

    function test_Buy_RevertUnknownFlight() public {
        vm.expectRevert(FlightDelayInsurance.FlightNotScheduled.selector);
        pool.buyPolicy(bytes32("nope"));
    }

    function test_Buy_RevertFlightCapacity() public {
        FlightDelayInsurance.FlightParams memory q = _params();
        q.maxExposure = 2 * q.coverage;
        _create(bytes32("small"), q);
        _buy(alice, bytes32("small"));
        _buy(alice, bytes32("small"));
        vm.expectRevert(FlightDelayInsurance.FlightCapacityExceeded.selector);
        vm.prank(alice);
        pool.buyPolicy(bytes32("small"));
    }

    function test_Buy_RevertPoolCapacity() public {
        // 1000 liquidity; each policy nets 90 of risk -> the 12th no longer fits (11*10 + 1000 - 11*100 = 10 < 100-10)
        for (uint256 i; i < 11; ++i) {
            _buy(alice, key);
        }
        usdc.mint(alice, 10 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(pool), 10 * USDC);
        vm.expectRevert(
            abi.encodeWithSelector(FlightDelayInsurance.InsufficientFreeLiquidity.selector, 100 * USDC, 20 * USDC)
        );
        pool.buyPolicy(key);
        vm.stopPrank();
    }

    function test_Pause_BlocksRiskTaking() public {
        vm.prank(admin);
        pool.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.buyPolicy(key);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        pool.deposit(1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(lp);
        pool.withdraw(1);
        vm.warp(p.departure);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(oracle);
        pool.reportFlight(key, IFlightOracle.FlightStatus.OnTime, 0);
        vm.prank(admin);
        pool.unpause();
        vm.prank(oracle);
        pool.reportFlight(key, IFlightOracle.FlightStatus.OnTime, 0);
    }

    function test_Pause_RevertNonPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pool.PAUSER_ROLE())
        );
        vm.prank(alice);
        pool.pause();
    }

    // ───────────────────────── Settlement ─────────────────────────

    function _settle(IFlightOracle.FlightStatus s, uint32 delay) internal {
        vm.prank(oracle);
        pool.reportFlight(key, s, delay);
    }

    function test_Settle_PayoutTiers() public view {
        uint32[5] memory delays = [uint32(30), 59, 60, 179, 180];
        uint256[5] memory expected = [uint256(0), 0, 25, 25, 100];
        for (uint256 i; i < 5; ++i) {
            assertEq(pool.payoutBps(p, IFlightOracle.FlightStatus.Delayed, delays[i]), expected[i] * 100);
        }
        assertEq(pool.payoutBps(p, IFlightOracle.FlightStatus.OnTime, 500), 0);
        assertEq(pool.payoutBps(p, IFlightOracle.FlightStatus.Cancelled, 0), 10_000);
    }

    function test_Settle_DelayedPartialPayout() public {
        uint256 id = _buy(alice, key);
        _buy(bob, key);
        vm.warp(p.departure + 90 minutes);
        _settle(IFlightOracle.FlightStatus.Delayed, 90);

        assertEq(pool.reservedExposure(), 0);
        assertEq(pool.owedClaims(), 50 * USDC);
        assertEq(pool.totalLiquidity(), 1_020 * USDC - 50 * USDC);

        vm.expectEmit(address(pool));
        emit FlightDelayInsurance.PolicyClaimed(id, alice, 25 * USDC);
        vm.prank(bob); // anyone can trigger; funds go to the holder
        pool.claim(id);
        assertEq(usdc.balanceOf(alice), 25 * USDC);
        assertEq(pool.owedClaims(), 25 * USDC);
    }

    function test_Settle_CancelledFullPayoutBeforeDeparture() public {
        uint256 id = _buy(alice, key);
        _settle(IFlightOracle.FlightStatus.Cancelled, 999); // delay ignored for cancellations
        assertEq(pool.getFlight(key).delayMinutes, 0);
        pool.claim(id);
        assertEq(usdc.balanceOf(alice), 100 * USDC);
        assertEq(pool.owedClaims(), 0);
    }

    function test_Settle_OnTimeNoPayout() public {
        uint256 id = _buy(alice, key);
        vm.warp(p.departure);
        _settle(IFlightOracle.FlightStatus.OnTime, 0);
        vm.expectRevert(FlightDelayInsurance.NoPayout.selector);
        pool.claim(id);
    }

    function test_Settle_RevertNonOracle() public {
        vm.warp(p.departure);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, pool.ORACLE_ROLE())
        );
        vm.prank(alice);
        pool.reportFlight(key, IFlightOracle.FlightStatus.OnTime, 0);
    }

    function test_Settle_RevertTooEarly() public {
        vm.warp(p.departure - 1);
        vm.expectRevert(FlightDelayInsurance.ReportTooEarly.selector);
        _settle(IFlightOracle.FlightStatus.OnTime, 0);
        vm.warp(p.departure + 179 minutes); // a 180-min delay can't be known yet
        vm.expectRevert(FlightDelayInsurance.ReportTooEarly.selector);
        _settle(IFlightOracle.FlightStatus.Delayed, 180);
    }

    function test_Settle_RevertDelayedZero() public {
        vm.warp(p.departure);
        vm.expectRevert(FlightDelayInsurance.InvalidParams.selector);
        _settle(IFlightOracle.FlightStatus.Delayed, 0);
    }

    function test_Settle_RevertTwice() public {
        vm.warp(p.departure);
        _settle(IFlightOracle.FlightStatus.OnTime, 0);
        vm.expectRevert(FlightDelayInsurance.FlightNotScheduled.selector);
        _settle(IFlightOracle.FlightStatus.Cancelled, 0);
    }

    function test_Settle_RevertAfterWindow() public {
        vm.warp(p.departure + REPORT_WINDOW);
        vm.expectRevert(FlightDelayInsurance.ReportWindowClosed.selector);
        _settle(IFlightOracle.FlightStatus.OnTime, 0);
    }

    function test_Claim_Reverts() public {
        vm.expectRevert(FlightDelayInsurance.UnknownPolicy.selector);
        pool.claim(42);
        uint256 id = _buy(alice, key);
        vm.expectRevert(FlightDelayInsurance.NotResolved.selector);
        pool.claim(id);
        _settle(IFlightOracle.FlightStatus.Cancelled, 0);
        pool.claim(id);
        vm.expectRevert(FlightDelayInsurance.AlreadyClaimed.selector);
        pool.claim(id);
    }

    function test_Claim_WorksWhilePaused() public {
        uint256 id = _buy(alice, key);
        _settle(IFlightOracle.FlightStatus.Cancelled, 0);
        vm.prank(admin);
        pool.pause();
        pool.claim(id);
        assertEq(usdc.balanceOf(alice), 100 * USDC);
    }

    // ───────────────────────── Expiry ─────────────────────────

    function test_Expire_RefundsPremium() public {
        uint256 id = _buy(alice, key);
        vm.warp(p.departure + REPORT_WINDOW - 1);
        vm.expectRevert(FlightDelayInsurance.ReportWindowOpen.selector);
        pool.expireFlight(key);

        vm.warp(p.departure + REPORT_WINDOW);
        pool.expireFlight(key);
        assertEq(pool.reservedExposure(), 0);
        assertEq(pool.owedClaims(), 10 * USDC);
        assertEq(pool.totalLiquidity(), 1_000 * USDC);
        pool.claim(id);
        assertEq(usdc.balanceOf(alice), 10 * USDC);

        vm.expectRevert(FlightDelayInsurance.FlightNotScheduled.selector);
        pool.expireFlight(key);
        vm.expectRevert(FlightDelayInsurance.FlightNotScheduled.selector);
        _settle(IFlightOracle.FlightStatus.Cancelled, 0);
    }

    function test_Expire_RevertUnknownOrSettled() public {
        vm.expectRevert(FlightDelayInsurance.FlightNotScheduled.selector);
        pool.expireFlight(bytes32("nope"));
        _settle(IFlightOracle.FlightStatus.Cancelled, 0);
        vm.warp(p.departure + REPORT_WINDOW);
        vm.expectRevert(FlightDelayInsurance.FlightNotScheduled.selector);
        pool.expireFlight(key);
    }

    // ───────────────────────── Oracle adapter ─────────────────────────

    function _adapter() internal returns (FunctionsFlightOracle a, address router) {
        router = makeAddr("router");
        a = new FunctionsFlightOracle(pool, router, admin);
        bytes32 role = pool.ORACLE_ROLE();
        vm.prank(admin);
        pool.grantRole(role, address(a));
    }

    function test_Adapter_FulfilSettles() public {
        (FunctionsFlightOracle a, address router) = _adapter();
        uint256 id = _buy(alice, key);
        vm.prank(admin);
        bytes32 req = a.requestStatus(key);
        assertEq(a.pending(req), key);

        vm.warp(p.departure + 3 hours);
        vm.prank(router);
        a.handleOracleFulfillment(req, abi.encode(uint8(1), uint32(180)), "");
        assertEq(a.pending(req), bytes32(0));
        assertEq(uint8(pool.getFlight(key).state), uint8(FlightDelayInsurance.State.Settled));
        pool.claim(id);
        assertEq(usdc.balanceOf(alice), 100 * USDC);
    }

    function test_Adapter_Reverts() public {
        (FunctionsFlightOracle a, address router) = _adapter();
        vm.expectRevert(FunctionsFlightOracle.ZeroAddress.selector);
        new FunctionsFlightOracle(pool, address(0), admin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        a.requestStatus(key);

        vm.prank(admin);
        bytes32 req = a.requestStatus(key);
        vm.expectRevert(FunctionsFlightOracle.OnlyRouter.selector);
        a.handleOracleFulfillment(req, "", "");
        vm.expectRevert(FunctionsFlightOracle.UnknownRequest.selector);
        vm.prank(router);
        a.handleOracleFulfillment(bytes32("bad"), "", "");
        vm.expectRevert(); // out-of-range enum fails abi.decode
        vm.prank(router);
        a.handleOracleFulfillment(req, abi.encode(uint8(7), uint32(0)), "");
    }

    function test_Adapter_ErrorLeavesFlightOpen() public {
        (FunctionsFlightOracle a, address router) = _adapter();
        vm.prank(admin);
        bytes32 req = a.requestStatus(key);
        vm.prank(router);
        a.handleOracleFulfillment(req, "", "api down");
        assertEq(a.pending(req), bytes32(0));
        assertEq(uint8(pool.getFlight(key).state), uint8(FlightDelayInsurance.State.Scheduled));
    }

    // ───────────────────────── Fuzz ─────────────────────────

    /// @dev Payout is monotone in delay and never exceeds coverage.
    function testFuzz_PayoutBpsMonotone(uint32 d1, uint32 d2) public view {
        (d1, d2) = d1 <= d2 ? (d1, d2) : (d2, d1);
        uint256 b1 = pool.payoutBps(p, IFlightOracle.FlightStatus.Delayed, d1);
        uint256 b2 = pool.payoutBps(p, IFlightOracle.FlightStatus.Delayed, d2);
        assertLe(b1, b2);
        assertLe(b2, pool.BPS());
    }

    /// @dev Deposit then withdraw never returns more than was put in (no free value from rounding).
    function testFuzz_DepositWithdrawNoProfit(uint256 seed, uint256 amount) public {
        _deposit(bob, bound(seed, 1, 1e15)); // vary the share price base
        amount = bound(amount, 1, 1e15);
        uint256 shares = _deposit(alice, amount);
        vm.prank(alice);
        try pool.withdraw(shares) returns (uint256 out) {
            assertLe(out, amount);
        } catch {}
    }

    /// @dev End-to-end: random sizes, policy count and outcome; every claim is paid in full and the
    ///      pool ends with exactly deposits + premiums - payouts.
    function testFuzz_SettlementMath(uint128 premium, uint128 coverage, uint8 n, uint8 outcome, uint32 delay) public {
        coverage = uint128(bound(coverage, 2, 1e12));
        premium = uint128(bound(premium, 1, coverage - 1));
        n = uint8(bound(n, 1, 20));
        FlightDelayInsurance.FlightParams memory q = _params();
        q.premium = premium;
        q.coverage = coverage;
        q.maxExposure = uint128(uint256(coverage) * n);
        bytes32 k = bytes32("fuzz");
        _create(k, q);
        _deposit(lp, uint256(coverage) * n);

        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _buy(address(uint160(1000 + i)), k);
        }
        IFlightOracle.FlightStatus s = IFlightOracle.FlightStatus(bound(outcome, 0, 2));
        delay = s == IFlightOracle.FlightStatus.Delayed ? uint32(bound(delay, 1, 2000)) : 0;
        vm.warp(q.departure + uint256(delay) * 60);
        vm.prank(oracle);
        pool.reportFlight(k, s, delay);

        uint256 each = uint256(coverage) * pool.payoutBps(q, s, delay) / 10_000;
        for (uint256 i; i < n && each > 0; ++i) {
            pool.claim(ids[i]);
            assertEq(usdc.balanceOf(address(uint160(1000 + i))), each);
        }
        assertEq(pool.owedClaims(), 0);
        assertEq(pool.reservedExposure(), 0);
        assertEq(usdc.balanceOf(address(pool)), pool.totalLiquidity());
        assertEq(pool.totalLiquidity(), 1_000 * USDC + uint256(coverage) * n + uint256(premium) * n - each * n);
    }
}
