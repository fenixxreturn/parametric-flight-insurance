// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFlightOracle} from "./IFlightOracle.sol";

/// @title FlightDelayInsurance
/// @notice Parametric flight-delay cover paid in a stablecoin. LPs fund a shared pool; travellers
///         buy fixed-size policies on a flight; an oracle reports the outcome once and policies pay
///         out by a predefined tier table with no claims assessment.
/// @dev Accounting (all in `asset` units, tracked internally so donations cannot move prices):
///      - `totalLiquidity`   LP-owned assets: deposits + premiums - withdrawals - resolved liabilities.
///      - `reservedExposure` max payout of every policy on an unresolved flight (subset of totalLiquidity).
///      - `owedClaims`       payouts/refunds fixed at resolution but not yet claimed.
///      Invariants: `asset.balanceOf(this) >= totalLiquidity + owedClaims` and
///                  `totalLiquidity >= reservedExposure`. LPs can only withdraw the difference.
///      Assumes a standard ERC-20 asset (no fee-on-transfer, rebasing or transfer hooks).
contract FlightDelayInsurance is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IFlightOracle
{
    using SafeERC20 for IERC20;

    // ───────────────────────── Constants ─────────────────────────
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_TIERS = 4;
    /// @dev Virtual shares/assets (OZ ERC4626 "decimals offset" technique): makes a first-depositor
    ///      donation/inflation attack cost the attacker ~1e6x what it can steal.
    uint256 private constant VIRTUAL_SHARES = 1e6;

    // ───────────────────────── Types ─────────────────────────
    enum State {
        None,
        Scheduled,
        Settled,
        Expired
    }

    /// @notice Admin input for a new flight product.
    struct FlightParams {
        uint64 departure; // scheduled departure (unix seconds)
        uint64 saleCutoff; // last second policies can be bought (<= departure)
        uint128 premium; // paid per policy
        uint128 coverage; // max payout per policy (100% tier)
        uint128 maxExposure; // cap on sold policies * coverage for this flight
        uint32[] delayThresholds; // minutes, strictly ascending
        uint16[] delayBps; // payout share of coverage per threshold, non-decreasing
        uint16 cancelBps; // payout share of coverage on cancellation
    }

    struct Flight {
        FlightParams params;
        State state;
        FlightStatus outcome;
        uint32 delayMinutes;
        uint64 sold; // number of policies
        uint128 payoutPerPolicy; // fixed at resolution
    }

    struct Policy {
        address holder;
        bool claimed;
        bytes32 flightKey;
    }

    /// @custom:storage-location erc7201:parametric.storage.FlightDelayInsurance
    struct InsuranceStorage {
        IERC20 asset;
        uint64 reportWindow; // seconds after departure the oracle has to report before expiry
        uint256 totalLiquidity;
        uint256 reservedExposure;
        uint256 owedClaims;
        uint256 totalShares;
        uint256 nextPolicyId;
        mapping(address => uint256) shares;
        mapping(bytes32 => Flight) flights;
        mapping(uint256 => Policy) policies;
    }

    // keccak256(abi.encode(uint256(keccak256("parametric.storage.FlightDelayInsurance")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0xe734da3ca8a5c291444147e40228e0de1ec1198113be540a25a680a00645a400;

    // ───────────────────────── Events ─────────────────────────
    event LiquidityDeposited(address indexed lp, uint256 assets, uint256 shares);
    event LiquidityWithdrawn(address indexed lp, uint256 shares, uint256 assets);
    event FlightCreated(bytes32 indexed flightKey, FlightParams params);
    event PolicyPurchased(uint256 indexed policyId, bytes32 indexed flightKey, address indexed holder, uint256 premium);
    event FlightSettled(bytes32 indexed flightKey, FlightStatus status, uint32 delayMinutes, uint256 payoutPerPolicy);
    event FlightExpired(bytes32 indexed flightKey, uint256 refundPerPolicy);
    event PolicyClaimed(uint256 indexed policyId, address indexed holder, uint256 amount);

    // ───────────────────────── Errors ─────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();
    error InsufficientFreeLiquidity(uint256 requested, uint256 available);
    error InvalidParams();
    error FlightExists();
    error FlightNotScheduled();
    error SalesClosed();
    error FlightCapacityExceeded();
    error ReportTooEarly();
    error ReportWindowClosed();
    error ReportWindowOpen();
    error NotResolved();
    error AlreadyClaimed();
    error NoPayout();
    error UnknownPolicy();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the proxy.
    /// @param asset_        Stablecoin used for liquidity, premiums and payouts.
    /// @param admin         Receives DEFAULT_ADMIN_ROLE (products, roles, upgrades) and PAUSER_ROLE.
    /// @param reportWindow_ Seconds after departure during which the oracle may report; after it,
    ///                      unreported flights can be expired and premiums refunded.
    function initialize(IERC20 asset_, address admin, uint64 reportWindow_) external initializer {
        if (address(asset_) == address(0) || admin == address(0)) revert ZeroAddress();
        if (reportWindow_ == 0) revert InvalidParams();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        InsuranceStorage storage $ = _s();
        $.asset = asset_;
        $.reportWindow = reportWindow_;
    }

    // ───────────────────────── Liquidity ─────────────────────────

    /// @notice Deposit `assets` into the pool and receive LP shares.
    /// @return shares Minted shares (reverts if it would round to zero).
    function deposit(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        InsuranceStorage storage $ = _s();
        $.shares[msg.sender] += shares;
        $.totalShares += shares;
        $.totalLiquidity += assets;
        $.asset.safeTransferFrom(msg.sender, address(this), assets);
        emit LiquidityDeposited(msg.sender, assets, shares);
    }

    /// @notice Burn `shares` for their share of pool assets. Only unreserved liquidity can leave.
    /// @return assets Amount transferred to the caller (rounded down).
    function withdraw(uint256 shares) external nonReentrant whenNotPaused returns (uint256 assets) {
        InsuranceStorage storage $ = _s();
        if (shares == 0) revert ZeroAmount();
        if (shares > $.shares[msg.sender]) revert InsufficientShares();
        assets = previewWithdraw(shares);
        if (assets == 0) revert ZeroAmount();
        uint256 free = freeLiquidity();
        if (assets > free) revert InsufficientFreeLiquidity(assets, free);
        $.shares[msg.sender] -= shares;
        $.totalShares -= shares;
        $.totalLiquidity -= assets;
        $.asset.safeTransfer(msg.sender, assets);
        emit LiquidityWithdrawn(msg.sender, shares, assets);
    }

    // ───────────────────────── Products ─────────────────────────

    /// @notice Create a flight product. Parameters are immutable once created.
    /// @dev The highest delay tier must be reachable inside the report window, otherwise such a
    ///      delay could never be reported and the flight would always expire into refunds.
    function createFlight(bytes32 key, FlightParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        InsuranceStorage storage $ = _s();
        Flight storage f = $.flights[key];
        if (f.state != State.None) revert FlightExists();
        uint256 n = p.delayThresholds.length;
        if (
            p.premium == 0 || p.premium >= p.coverage || p.coverage > p.maxExposure || p.saleCutoff <= block.timestamp
                || p.saleCutoff > p.departure || n == 0 || n > MAX_TIERS || n != p.delayBps.length || p.cancelBps > BPS
                || uint256(p.delayThresholds[n - 1]) * 60 >= $.reportWindow
        ) revert InvalidParams();
        for (uint256 i; i < n; ++i) {
            if (p.delayBps[i] > BPS || p.delayThresholds[i] == 0) revert InvalidParams();
            if (i > 0 && (p.delayThresholds[i] <= p.delayThresholds[i - 1] || p.delayBps[i] < p.delayBps[i - 1])) {
                revert InvalidParams();
            }
        }
        f.params = p;
        f.state = State.Scheduled;
        emit FlightCreated(key, p);
    }

    /// @notice Buy one policy on `key`, paying its premium. Reserves `coverage` of pool liquidity.
    /// @return policyId Id of the new policy, owned by the caller.
    function buyPolicy(bytes32 key) external nonReentrant whenNotPaused returns (uint256 policyId) {
        InsuranceStorage storage $ = _s();
        Flight storage f = $.flights[key];
        if (f.state != State.Scheduled) revert FlightNotScheduled();
        if (block.timestamp > f.params.saleCutoff) revert SalesClosed();
        uint256 coverage = f.params.coverage;
        uint256 premium = f.params.premium;
        if ((uint256(f.sold) + 1) * coverage > f.params.maxExposure) revert FlightCapacityExceeded();
        // premium joins the pool first, so LP risk per policy is coverage - premium
        uint256 free = $.totalLiquidity + premium - $.reservedExposure;
        if (coverage > free) revert InsufficientFreeLiquidity(coverage, free);

        f.sold += 1;
        $.totalLiquidity += premium;
        $.reservedExposure += coverage;
        policyId = ++$.nextPolicyId;
        $.policies[policyId] = Policy({holder: msg.sender, claimed: false, flightKey: key});
        $.asset.safeTransferFrom(msg.sender, address(this), premium);
        emit PolicyPurchased(policyId, key, msg.sender, premium);
    }

    // ───────────────────────── Settlement ─────────────────────────

    /// @inheritdoc IFlightOracle
    /// @dev Timestamp sanity: OnTime needs departure to have passed; Delayed needs the reported delay
    ///      to have actually elapsed; Cancelled may come any time. Nothing is accepted after the
    ///      report window, when the flight belongs to the expiry/refund path.
    function reportFlight(bytes32 key, FlightStatus status, uint32 delayMinutes)
        external
        onlyRole(ORACLE_ROLE)
        whenNotPaused
    {
        InsuranceStorage storage $ = _s();
        Flight storage f = $.flights[key];
        if (f.state != State.Scheduled) revert FlightNotScheduled();
        uint256 departure = f.params.departure;
        if (block.timestamp >= departure + $.reportWindow) revert ReportWindowClosed();
        if (status == FlightStatus.Delayed && delayMinutes == 0) revert InvalidParams();
        if (status != FlightStatus.Delayed) delayMinutes = 0;
        if (status != FlightStatus.Cancelled && block.timestamp < departure + uint256(delayMinutes) * 60) {
            revert ReportTooEarly();
        }

        uint256 payout = f.params.coverage * payoutBps(f.params, status, delayMinutes) / BPS;
        f.outcome = status;
        f.delayMinutes = delayMinutes;
        _resolve($, f, State.Settled, payout);
        emit FlightSettled(key, status, delayMinutes, payout);
    }

    /// @notice Close a flight the oracle never reported; every policy becomes refundable at its premium.
    /// @dev Permissionless so funds can never be stuck behind a dead oracle.
    function expireFlight(bytes32 key) external {
        InsuranceStorage storage $ = _s();
        Flight storage f = $.flights[key];
        if (f.state != State.Scheduled) revert FlightNotScheduled();
        if (block.timestamp < uint256(f.params.departure) + $.reportWindow) revert ReportWindowOpen();
        uint256 refund = f.params.premium;
        _resolve($, f, State.Expired, refund);
        emit FlightExpired(key, refund);
    }

    /// @notice Pay a resolved policy's payout (or refund) to its holder. Callable by anyone.
    function claim(uint256 policyId) external nonReentrant {
        InsuranceStorage storage $ = _s();
        Policy storage p = $.policies[policyId];
        if (p.holder == address(0)) revert UnknownPolicy();
        if (p.claimed) revert AlreadyClaimed();
        Flight storage f = $.flights[p.flightKey];
        if (f.state != State.Settled && f.state != State.Expired) revert NotResolved();
        uint256 amount = f.payoutPerPolicy;
        if (amount == 0) revert NoPayout();
        p.claimed = true;
        $.owedClaims -= amount;
        $.asset.safeTransfer(p.holder, amount);
        emit PolicyClaimed(policyId, p.holder, amount);
    }

    /// @dev Converts a flight's reserved exposure into a fixed liability; the rest returns to LPs.
    function _resolve(InsuranceStorage storage $, Flight storage f, State state, uint256 perPolicy) private {
        uint256 owed = uint256(f.sold) * perPolicy;
        f.state = state;
        // casting to 'uint128' is safe because perPolicy <= coverage, which is a uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        f.payoutPerPolicy = uint128(perPolicy);
        $.reservedExposure -= uint256(f.sold) * f.params.coverage;
        $.totalLiquidity -= owed;
        $.owedClaims += owed;
    }

    // ───────────────────────── Admin ─────────────────────────

    /// @notice Pause deposits, withdrawals, sales and oracle reports. Claims and expiry stay open.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume normal operation.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ───────────────────────── Views ─────────────────────────

    /// @notice Canonical product key for a flight number on a given date (e.g. "LH400", 20261016).
    function flightKey(string calldata flightNumber, uint256 yyyymmdd) external pure returns (bytes32) {
        return keccak256(abi.encode(flightNumber, yyyymmdd));
    }

    /// @notice Payout share of coverage (in bps) for an outcome under `p`'s tier table.
    function payoutBps(FlightParams memory p, FlightStatus status, uint32 delayMinutes) public pure returns (uint256) {
        if (status == FlightStatus.Cancelled) return p.cancelBps;
        if (status == FlightStatus.OnTime) return 0;
        uint256 bps;
        for (uint256 i; i < p.delayThresholds.length && delayMinutes >= p.delayThresholds[i]; ++i) {
            bps = p.delayBps[i];
        }
        return bps;
    }

    /// @notice Shares minted for depositing `assets` now (rounded down).
    function previewDeposit(uint256 assets) public view returns (uint256) {
        InsuranceStorage storage $ = _s();
        return Math.mulDiv(assets, $.totalShares + VIRTUAL_SHARES, $.totalLiquidity + 1);
    }

    /// @notice Assets paid for burning `shares` now (rounded down), ignoring the free-liquidity cap.
    function previewWithdraw(uint256 shares) public view returns (uint256) {
        InsuranceStorage storage $ = _s();
        return Math.mulDiv(shares, $.totalLiquidity + 1, $.totalShares + VIRTUAL_SHARES);
    }

    /// @notice Liquidity not reserved against open policies; the most LPs can withdraw now.
    function freeLiquidity() public view returns (uint256) {
        InsuranceStorage storage $ = _s();
        return $.totalLiquidity - $.reservedExposure;
    }

    function asset() external view returns (IERC20) {
        return _s().asset;
    }

    function reportWindow() external view returns (uint64) {
        return _s().reportWindow;
    }

    function totalLiquidity() external view returns (uint256) {
        return _s().totalLiquidity;
    }

    function reservedExposure() external view returns (uint256) {
        return _s().reservedExposure;
    }

    function owedClaims() external view returns (uint256) {
        return _s().owedClaims;
    }

    function totalShares() external view returns (uint256) {
        return _s().totalShares;
    }

    function sharesOf(address lp) external view returns (uint256) {
        return _s().shares[lp];
    }

    function getFlight(bytes32 key) external view returns (Flight memory) {
        return _s().flights[key];
    }

    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        return _s().policies[policyId];
    }

    function _s() private pure returns (InsuranceStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
