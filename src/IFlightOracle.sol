// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFlightOracle
/// @notice The oracle-facing surface of the insurance pool: the single call a data feed makes to
///         settle a flight. Oracle adapters depend only on this interface, so the feed (Chainlink
///         Functions, a multisig, an API3 dAPI, ...) can be swapped without touching the pool.
interface IFlightOracle {
    enum FlightStatus {
        OnTime,
        Delayed,
        Cancelled
    }

    /// @notice Report the final status of a flight. Callable once per flight by an authorised oracle.
    /// @param flightKey    Product key, see `FlightDelayInsurance.flightKey`.
    /// @param status       Final outcome.
    /// @param delayMinutes Arrival delay in minutes; only meaningful for `Delayed`.
    function reportFlight(bytes32 flightKey, FlightStatus status, uint32 delayMinutes) external;
}
