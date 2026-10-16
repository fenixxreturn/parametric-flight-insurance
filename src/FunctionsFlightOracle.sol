// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IFlightOracle} from "./IFlightOracle.sol";

/// @title FunctionsFlightOracle
/// @notice Minimal Chainlink-Functions-style adapter: the owner requests a flight's status, an
///         off-chain DON fetches it from a flight-data API, and the router delivers the answer via
///         `handleOracleFulfillment`, which forwards it to the insurance pool. This contract must
///         hold ORACLE_ROLE on the pool.
/// @dev Shape mirrors Chainlink's `FunctionsClient` (router-only fulfilment, request-id matching).
///      A production version would inherit `FunctionsClient` and call `_sendRequest` with the JS
///      source, subscription id and DON id; here the request is just an event so the demo stays
///      dependency-free. The response is ABI-encoded `(uint8 status, uint32 delayMinutes)`;
///      decoding into the enum reverts on out-of-range values.
contract FunctionsFlightOracle is Ownable2Step {
    IFlightOracle public immutable insurance;
    address public immutable router;

    uint256 private _nonce;
    mapping(bytes32 requestId => bytes32 flightKey) public pending;

    event StatusRequested(bytes32 indexed requestId, bytes32 indexed flightKey);
    event StatusFulfilled(bytes32 indexed requestId, bytes32 indexed flightKey);
    event StatusFailed(bytes32 indexed requestId, bytes32 indexed flightKey, bytes err);

    error ZeroAddress();
    error OnlyRouter();
    error UnknownRequest();

    constructor(IFlightOracle insurance_, address router_, address owner_) Ownable(owner_) {
        if (address(insurance_) == address(0) || router_ == address(0)) revert ZeroAddress();
        insurance = insurance_;
        router = router_;
    }

    /// @notice Ask the DON for `flightKey`'s final status.
    function requestStatus(bytes32 flightKey) external onlyOwner returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(block.chainid, address(this), ++_nonce));
        pending[requestId] = flightKey;
        emit StatusRequested(requestId, flightKey);
    }

    /// @notice Router callback carrying the DON's answer (or error) for `requestId`.
    /// @dev A failed or rejected answer clears the request; the owner can simply request again.
    function handleOracleFulfillment(bytes32 requestId, bytes calldata response, bytes calldata err) external {
        if (msg.sender != router) revert OnlyRouter();
        bytes32 key = pending[requestId];
        if (key == bytes32(0)) revert UnknownRequest();
        delete pending[requestId];
        if (err.length != 0) {
            emit StatusFailed(requestId, key, err);
            return;
        }
        (IFlightOracle.FlightStatus status, uint32 delayMinutes) =
            abi.decode(response, (IFlightOracle.FlightStatus, uint32));
        insurance.reportFlight(key, status, delayMinutes);
        emit StatusFulfilled(requestId, key);
    }
}
