// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MockPriceFeed } from "./MockPriceFeed.sol";

/// @title PiggyVault — destination-chain vault (Base Sepolia).
/// @notice Holds the user's test position and executes the three automated
///         actions the reactive contract orders: stop-loss sell, take-profit
///         sell, and DCA buy. Only the PiggyGuardCallback contract may call
///         the execute functions; the owner funds / withdraws / pauses.
/// @dev TESTNET DEMO LEDGER: balances are mock ledger units, not real tokens.
///      - riskBalance: units of the risk asset, 8 decimals.
///      - safeBalance: units of the safe asset (USD-pegged), 8 decimals.
///      - price: USD per risk unit, 8 decimals (same convention as the feed).
///      Execution is a virtual swap at the trigger price, so the demo never
///      depends on a testnet DEX pool. The on-chain proof this project offers
///      is the reactive loop itself (origin event -> Lasna react() -> callback),
///      not a real trade. A mock-ERC20 venue can replace this ledger later
///      without touching the reactive contract or the callback contract.
contract PiggyVault {
    uint256 public constant PRICE_SCALE = 1e8;
    /// @notice Take-profit sells this share of the risk position per trigger.
    uint256 public constant TAKE_PROFIT_BPS = 5000; // 50%

    event Funded(string indexed asset, uint256 amount);
    event Withdrawn(string indexed asset, uint256 amount);
    event StopLossExecuted(uint256 price, uint256 sold, uint256 received);
    event TakeProfitExecuted(uint256 price, uint256 sold, uint256 received);
    event DcaExecuted(uint256 price, uint256 spent, uint256 bought);
    event DcaSkipped(string reason, uint256 safeBalance);
    event ExecutorUpdated(address indexed executor);
    event DcaAmountUpdated(uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotOwner(address sender);
    error NotExecutor(address sender);
    error PausedVault();
    error InsufficientBalance(uint256 requested, uint256 available);

    address public immutable owner;
    MockPriceFeed public immutable priceFeed;

    /// @notice Address allowed to call the three execute functions
    ///         (the PiggyGuardCallback contract; set after deployment).
    address public executor;

    uint256 public riskBalance;
    uint256 public safeBalance;
    /// @notice Safe-asset amount spent on every DCA tick (8 decimals, USD).
    uint256 public dcaAmount;
    bool public paused;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedVault();
        _;
    }

    constructor(address priceFeed_, uint256 dcaAmount_) {
        owner = msg.sender;
        priceFeed = MockPriceFeed(priceFeed_);
        dcaAmount = dcaAmount_;
    }

    // ---- owner: funding / config ----

    function fundRisk(uint256 amount_) external onlyOwner {
        riskBalance += amount_;
        emit Funded("risk", amount_);
    }

    function fundSafe(uint256 amount_) external onlyOwner {
        safeBalance += amount_;
        emit Funded("safe", amount_);
    }

    function withdrawRisk(uint256 amount_) external onlyOwner {
        if (amount_ > riskBalance) revert InsufficientBalance(amount_, riskBalance);
        riskBalance -= amount_;
        emit Withdrawn("risk", amount_);
    }

    function withdrawSafe(uint256 amount_) external onlyOwner {
        if (amount_ > safeBalance) revert InsufficientBalance(amount_, safeBalance);
        safeBalance -= amount_;
        emit Withdrawn("safe", amount_);
    }

    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function setDcaAmount(uint256 dcaAmount_) external onlyOwner {
        dcaAmount = dcaAmount_;
        emit DcaAmountUpdated(dcaAmount_);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ---- executor: the three automated actions ----

    /// @notice Sell the entire risk position into the safe asset at `price_`.
    function executeStopLoss(uint256 price_) external onlyExecutor whenNotPaused {
        uint256 sold = riskBalance;
        uint256 received = (sold * price_) / PRICE_SCALE;
        riskBalance = 0;
        safeBalance += received;
        emit StopLossExecuted(price_, sold, received);
    }

    /// @notice Sell TAKE_PROFIT_BPS of the risk position at `price_`.
    function executeTakeProfit(uint256 price_) external onlyExecutor whenNotPaused {
        uint256 sold = (riskBalance * TAKE_PROFIT_BPS) / 10000;
        uint256 received = (sold * price_) / PRICE_SCALE;
        riskBalance -= sold;
        safeBalance += received;
        emit TakeProfitExecuted(price_, sold, received);
    }

    /// @notice Spend `dcaAmount` of the safe asset to buy the risk asset at the
    ///         feed's latest price. Skips gracefully (no revert) when the safe
    ///         balance is too low, so a routine shortfall never fails a callback.
    function executeDCA() external onlyExecutor whenNotPaused {
        if (safeBalance < dcaAmount) {
            emit DcaSkipped("insufficient safe balance", safeBalance);
            return;
        }
        uint256 price = priceFeed.latestPrice();
        uint256 bought = (dcaAmount * PRICE_SCALE) / price;
        safeBalance -= dcaAmount;
        riskBalance += bought;
        emit DcaExecuted(price, dcaAmount, bought);
    }
}
