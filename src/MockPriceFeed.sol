// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockPriceFeed — self-controlled price event source (Base Sepolia).
/// @notice The price source PiggyGuardReactive subscribes to. The owner pushes
///         prices by hand / script, so every demo trigger is reproducible and
///         never depends on a public testnet pool's liquidity.
/// @dev Price uses 8 decimals, Chainlink style: 100_00000000 == $100.00.
///      The event is designed for Reactive subscription matching:
///      topic0 = keccak256("PriceUpdated(uint256,uint256)"),
///      topic1 = price (indexed, read by the reactive contract as log_.topic1),
///      data   = timestamp (non-indexed).
contract MockPriceFeed {
    /// @notice Emitted on every price push. `price` is indexed so the reactive
    ///         contract can read it straight from the log record (topic1).
    event PriceUpdated(uint256 indexed price, uint256 timestamp);

    error NotOwner(address sender);
    error ZeroPrice();

    address public immutable owner;
    uint256 public latestPrice;
    uint256 public latestTimestamp;

    constructor(uint256 initialPrice_) {
        owner = msg.sender;
        latestPrice = initialPrice_;
        latestTimestamp = block.timestamp;
    }

    /// @notice Push a new price and emit the event the reactive contract watches.
    /// @dev Rejects 0: a zero price would make every DCA divide by zero and
    ///      would let a stop-loss sell the whole position for nothing.
    function pushPrice(uint256 price_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (price_ == 0) revert ZeroPrice();
        latestPrice = price_;
        latestTimestamp = block.timestamp;
        emit PriceUpdated(price_, block.timestamp);
    }
}
