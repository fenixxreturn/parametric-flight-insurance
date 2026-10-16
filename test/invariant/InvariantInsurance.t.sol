// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Base} from "../Base.sol";
import {FlightDelayInsurance} from "../../src/FlightDelayInsurance.sol";
import {IFlightOracle} from "../../src/IFlightOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Drives the pool through random LP flows, sales, reports, expiries, claims and time.
contract Handler is Test {
    FlightDelayInsurance public pool;
    MockUSDC public usdc;
    address public admin;
    address public oracle;
    address[] public actors;
    bytes32[] public keys;
    uint256 public policies;

    // ghost accounting: every unit that entered / left the pool through its API
    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public totalClaimed;

    constructor(FlightDelayInsurance pool_, MockUSDC usdc_, address admin_, address oracle_) {
        pool = pool_;
        usdc = usdc_;
        admin = admin_;
        oracle = oracle_;
        for (uint256 i; i < 4; ++i) {
            actors.push(address(uint160(0xA11CE + i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _key(uint256 s) internal view returns (bytes32) {
        return keys.length == 0 ? bytes32(0) : keys[s % keys.length];
    }

    function deposit(uint256 s, uint256 amt) external {
        amt = bound(amt, 1, 100_000e6);
        address a = _actor(s);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(pool), amt);
        try pool.deposit(amt) {
            totalIn += amt;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 s, uint256 shares) external {
        address a = _actor(s);
        uint256 bal = pool.sharesOf(a);
        if (bal == 0) return;
        vm.prank(a);
        try pool.withdraw(bound(shares, 1, bal)) returns (uint256 out) {
            totalOut += out;
        } catch {}
    }

    function createFlight(uint256 premium, uint256 coverage, uint256 dep, uint16 cancelBps) external {
        coverage = bound(coverage, 2, 10_000e6);
        FlightDelayInsurance.FlightParams memory p;
        p.departure = uint64(block.timestamp + bound(dep, 2 hours, 10 days));
        p.saleCutoff = p.departure - 1 hours;
        p.coverage = uint128(coverage);
        p.premium = uint128(bound(premium, 1, coverage - 1));
        p.maxExposure = uint128(coverage * 20);
        p.delayThresholds = new uint32[](2);
        p.delayThresholds[0] = 60;
        p.delayThresholds[1] = 180;
        p.delayBps = new uint16[](2);
        p.delayBps[0] = 2_500;
        p.delayBps[1] = 10_000;
        p.cancelBps = uint16(bound(cancelBps, 0, 10_000));
        bytes32 k = keccak256(abi.encode(keys.length));
        vm.prank(admin);
        pool.createFlight(k, p);
        keys.push(k);
    }

    /// @dev Buys 1-5 policies; opens a fresh flight if the picked one is no longer on sale, and tops
    ///      up liquidity when needed, so most runs actually reach settlement and claims.
    function buy(uint256 s, uint256 ks, uint256 n) external {
        bytes32 k = _key(ks);
        FlightDelayInsurance.Flight memory f = pool.getFlight(k);
        if (f.state != FlightDelayInsurance.State.Scheduled || block.timestamp > f.params.saleCutoff) {
            this.createFlight(s, ks, n, uint16(s));
            k = keys[keys.length - 1];
            f = pool.getFlight(k);
        }
        n = bound(n, 1, 5);
        for (uint256 i; i < n; ++i) {
            address a = _actor(s % 4 + i);
            if (pool.freeLiquidity() + f.params.premium < f.params.coverage) this.deposit(s, f.params.coverage);
            uint256 premium = f.params.premium;
            usdc.mint(a, premium);
            vm.startPrank(a);
            usdc.approve(address(pool), premium);
            try pool.buyPolicy(k) {
                totalIn += premium;
                ++policies;
            } catch {}
            vm.stopPrank();
        }
    }

    function report(uint256 ks, uint8 status, uint32 delay) external {
        // pick the first still-open flight that has policies, scanning from a random start
        bytes32 k;
        FlightDelayInsurance.Flight memory f;
        for (uint256 i; i < keys.length; ++i) {
            k = keys[(ks % keys.length + i) % keys.length];
            f = pool.getFlight(k);
            if (f.state == FlightDelayInsurance.State.Scheduled && f.sold > 0) break;
        }
        if (f.state != FlightDelayInsurance.State.Scheduled) return;
        IFlightOracle.FlightStatus st = IFlightOracle.FlightStatus(status % 3);
        delay = uint32(bound(delay, 1, 1_000));
        // jump to when the outcome is knowable so reports mostly land (may push other flights into expiry)
        uint256 t = st == IFlightOracle.FlightStatus.Cancelled ? 0 : f.params.departure + uint256(delay) * 60;
        if (block.timestamp < t) vm.warp(t);
        vm.prank(oracle);
        try pool.reportFlight(k, st, delay) {} catch {}
    }

    function expire(uint256 ks) external {
        bytes32 k = _key(ks);
        if (k == bytes32(0)) return;
        try pool.expireFlight(k) {} catch {}
    }

    function claim(uint256 id) external {
        if (policies == 0) return;
        // scan from a random start and claim the first payable policy
        for (uint256 i; i < policies; ++i) {
            uint256 pid = (id % policies + i) % policies + 1;
            address holder = pool.getPolicy(pid).holder;
            uint256 before = usdc.balanceOf(holder);
            try pool.claim(pid) {
                uint256 paid = usdc.balanceOf(holder) - before;
                totalOut += paid;
                totalClaimed += paid;
                return;
            } catch {}
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 minutes, 1 days));
    }
}

contract InvariantInsuranceTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(pool, usdc, admin, oracle);
        targetContract(address(handler));
    }

    /// @dev Solvency: every LP claim and every fixed policy liability is backed by real tokens.
    function invariant_Solvent() public view {
        assertGe(usdc.balanceOf(address(pool)), pool.totalLiquidity() + pool.owedClaims());
    }

    /// @dev Reserved exposure is always covered by LP liquidity (worst case still payable).
    function invariant_ExposureCovered() public view {
        assertGe(pool.totalLiquidity(), pool.reservedExposure());
    }

    /// @dev Exact conservation: tokens only move through the API, and payouts + withdrawals
    ///      never exceed deposits + premiums.
    function invariant_Conservation() public view {
        assertLe(handler.totalOut(), handler.totalIn());
        assertEq(usdc.balanceOf(address(pool)), handler.totalIn() - handler.totalOut());
        assertEq(usdc.balanceOf(address(pool)), pool.totalLiquidity() + pool.owedClaims());
    }

    /// @dev Share ledger is consistent.
    function invariant_SharesSum() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += pool.sharesOf(handler.actors(i));
        }
        assertEq(sum, pool.totalShares());
    }
}
