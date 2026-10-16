# Parametric Flight-Delay Insurance

A small, upgradeable Solidity protocol for **parametric flight-delay cover**. Liquidity providers fund a
stablecoin pool, travellers buy a policy on a specific flight, an oracle reports what happened, and the
policy pays out automatically from a fixed table. There is no claims form and no assessor: the payout is a
pure function of the reported delay.

Built with Foundry, OpenZeppelin 5 (upgradeable), Solidity 0.8.24.

## How it works

1. **LPs deposit** the stablecoin (e.g. USDC, 6 decimals) and receive internal pool shares.
2. **Admin creates a flight product**: departure time, sale cutoff, premium, coverage per policy,
   a per-flight exposure cap and a payout table, e.g. `>= 60 min -> 25%`, `>= 180 min -> 100%`,
   `cancelled -> 100%`.
3. **A traveller buys a policy**: pays the premium and gets a `policyId`. The pool reserves the full
   coverage, so it can always pay the worst case. Sales stop at the cutoff, at the flight cap, when the
   pool has no free capital, or while paused.
4. **The oracle reports once** (`OnTime`, `Delayed(minutes)` or `Cancelled`). At that moment the flight's
   reserved exposure is released and the exact amount owed to its policyholders is set aside.
5. **Anyone can call `claim(policyId)`**; funds always go to the policyholder (pull pattern, so a
   keeper or the traveller can trigger it).
6. **If the oracle never reports** within `reportWindow` after departure, anyone can `expireFlight`, and
   every policy on that flight becomes refundable at its premium. Funds can't get stuck behind a dead oracle.

```
src/
  FlightDelayInsurance.sol   pool, products, policies, settlement (UUPS proxy implementation)
  IFlightOracle.sol          the one call an oracle makes: reportFlight(key, status, delayMinutes)
  FunctionsFlightOracle.sol  Chainlink-Functions-shaped adapter that forwards a DON answer to the pool
script/Deploy.s.sol          proxy deployment (+ optional adapter, role handover to a multisig)
test/                        unit, fuzz, invariant and upgrade tests
```

## Design decisions

- **Accounting is internal, not `balanceOf`.** Three numbers describe the pool:
  `totalLiquidity` (what LPs own), `reservedExposure` (worst-case payout of open policies) and
  `owedClaims` (payouts fixed but not yet claimed). LPs can only withdraw
  `totalLiquidity - reservedExposure`. Tokens sent to the contract directly are ignored, so donations
  can't move the share price.
- **Plain share accounting instead of a full ERC-4626 vault.** LP shares are non-transferable balances.
  This keeps the surface small. Share math uses OpenZeppelin's virtual-shares offset (`1e6`) on top of
  internal accounting, rounds in the pool's favour, and rejects zero-share deposits and zero-asset
  withdrawals.
- **One fixed-size policy per purchase.** Every policy on a flight has the same premium and coverage,
  so the liability set aside at settlement (`sold * payoutPerPolicy`) is exact, with no rounding dust.
- **Settlement is per flight, claims are per policy.** The oracle reports one outcome per flight, so
  the cost is constant however many policies were sold. Claims are O(1).
- **Timestamp sanity on reports.** `OnTime` is only accepted after departure. `Delayed(n)` is only
  accepted once `n` minutes after departure have actually passed. `Cancelled` is accepted any time.
  Nothing is accepted after the report window. A product can't have a delay tier that would only be
  reportable after the window closes.
- **Roles:** `DEFAULT_ADMIN_ROLE` (products, roles, upgrades), `ORACLE_ROLE` (reports), `PAUSER_ROLE`.
  Pausing stops deposits, withdrawals, sales and reports. **Claims and expiry keep working while
  paused**, so policyholders can always be paid.
- **Upgrade safety:** UUPS with `_authorizeUpgrade` restricted to the admin, `_disableInitializers()` in
  the constructor, and all state in one ERC-7201 namespaced struct
  (`parametric.storage.FlightDelayInsurance`), so later versions can append fields without slot
  collisions.
- **Oracle decoupling:** the pool exposes `IFlightOracle.reportFlight`. Any feed (Chainlink Functions,
  a multisig, another provider) can be plugged in by giving it `ORACLE_ROLE`. `FunctionsFlightOracle` shows
  the Chainlink Functions shape: router-only fulfilment and request-id matching. The callback never
  reverts on a known request: a DON error, a malformed answer or a report the pool rejects (e.g. too
  early) consumes the request and emits `StatusFailed`, leaving the flight open for a fresh request.
  A stale answer can't be replayed later.

## Running

```bash
forge build
forge test                 # 53 tests: unit, fuzz (256 runs), invariant (64 runs x 32 depth)
forge test --gas-report
forge snapshot             # writes .gas-snapshot
```

Deploying (dry run without `--broadcast`):

```bash
PRIVATE_KEY=... ASSET=<usdc> ADMIN=<multisig> FUNCTIONS_ROUTER=<router> \
  forge script script/Deploy.s.sol --rpc-url $RPC_URL
```

## Tests

- **Unit tests** cover every external function and every custom error except `ZeroShares` (a defensive
  check that the virtual-shares maths makes unreachable in practice): init and re-init, LP
  deposit/withdraw and locked capital, product validation (13 bad-parameter cases), buying (cutoff,
  flight cap, pool cap, pause), each outcome and payout tier, claim by a third party, double claims,
  expiry refunds, the oracle adapter, and pause/role checks.
- **Fuzz tests:** payout is monotonic in delay and capped at 100%. A deposit followed by a withdrawal
  never returns more than was deposited. A full end-to-end run with random premium, coverage, policy
  count and outcome checks that every claim is paid exactly and the pool ends at
  `deposits + premiums - payouts`.
- **Invariant tests** (random LP flows, product creation, sales, reports, expiries, claims, time jumps;
  the handler never reverts):
  - `balance >= totalLiquidity + owedClaims` (solvent)
  - `totalLiquidity >= reservedExposure` (worst case always covered)
  - `balance == deposits + premiums - withdrawals - payouts`, and outflows never exceed inflows
  - the per-LP share balances add up to `totalShares`
- **Upgrade test:** deploy the proxy, take positions, upgrade to a V2 mock, confirm all state and roles
  are preserved and that the upgraded pool still settles and pays. A non-admin upgrade reverts.
- **Review tests** (`test/review/`): adapter failure handling, the deploy script's zero-admin guard,
  and two tests that demonstrate the known limitations below (LP exit before a known loss, share maths
  after repeated total wipe-outs).
- **Mutation check:** we removed each key guard one at a time (pool cap, flight cap, withdrawal lock,
  sale cutoff, exposure release, liability booking, the claimed flag, report time check, expiry window,
  virtual shares, upgrade authorisation, tier ordering). Every removal made at least one test fail.

## Security notes and known limitations

This is a demo and has **not been audited**.

- **Trusted oracle.** One address (or adapter) with `ORACLE_ROLE` decides every outcome. Within the
  time checks it can report any delay. Production use needs multiple sources or quorum, a dispute or
  challenge window, and a monitored key.
- **Powerful admin.** The admin can upgrade the implementation and grant roles. Use a multisig behind
  a timelock. Flight parameters can't be changed once created, but the admin chooses premiums, so
  pricing is only as good as the admin's.
- **LP liquidity can be locked.** Capital reserved against open flights can't be withdrawn until those
  flights settle or expire. There is no withdrawal queue: free liquidity goes to whoever withdraws first.
- **LPs can exit ahead of a known loss.** Shares are priced on `totalLiquidity`, which only drops when
  the oracle reports. A delay is public before the report, so an LP can withdraw free liquidity at the
  pre-loss price and leave the loss to the remaining LPs (and a new depositor can walk into it). A
  production pool needs a withdrawal cooldown or epoch-based redemptions.
- **Sales can be adversely selected.** Cancellations (and long delays) are often public before the sale
  cutoff, and buyers can act on them before the oracle reports. Set `saleCutoff` well before departure
  and have the oracle report `Cancelled` as soon as it is known.
- **Total wipe-outs degrade share maths.** If a payout takes `totalLiquidity` to zero while shares are
  outstanding, old shares become worthless and the next deposit mints a huge number of shares. After a
  handful of such wipe-outs the share maths overflows and deposits revert; redeploy the pool instead.
- **Correlated risk.** Coverage is fully reserved per policy, so the pool can't become insolvent. But a
  storm that delays many flights can wipe out a large part of LP capital. Per-flight caps limit this;
  there are no portfolio-level caps and no reinsurance.
- **Expiry refunds return premiums**, so LPs earn nothing on flights the oracle never reported.
- **Pausing during a report window** can push flights into expiry, which means refunds instead of payouts.
  "Claims keep working while paused" means policyholders get at least their premium back, not a payout.
- **Report time checks are coarse.** `Delayed(n)` is checked against scheduled *departure*, not arrival,
  and `OnTime` is accepted from departure. They stop obviously premature reports only; the oracle is trusted.
- **Standard ERC-20 only:** no fee-on-transfer or rebasing tokens. With USDC, a blacklisted holder's
  claim reverts and their payout stays owed in the pool. There is no redirect.
- **Policies are not transferable** (a plain mapping, not an ERC-721).
- **Stray tokens stay stuck.** Tokens sent directly to the contract are not counted and can't be swept.
- **The oracle adapter is shaped like Chainlink Functions but not wired to it.** A real deployment
  would inherit `FunctionsClient`, send the JS source and subscription, and validate the API response
  off-chain.
- **Double-claim protection is covered by unit tests only.** The invariants check pool-level
  conservation, not each holder's balance.
