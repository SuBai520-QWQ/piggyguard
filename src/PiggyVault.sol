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
    event StopLossSkipped(string reason, uint256 price);
    event TakeProfitSkipped(string reason, uint256 price);
    event DcaExecuted(uint256 price, uint256 spent, uint256 bought);
    event DcaSkipped(string reason, uint256 safeBalance);
    event ActionIgnored(uint256 actionId, uint256 lastActionId);
    event ExecutorUpdated(address indexed executor);
    event DcaAmountUpdated(uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotOwner(address sender);
    error NotExecutor(address sender);
    error PausedVault();
    error InsufficientBalance(uint256 requested, uint256 available);
    error ZeroPrice();
    error ZeroAddress();
    error ZeroAmount();

    address public immutable owner;
    MockPriceFeed public immutable priceFeed;

    /// @notice Address allowed to call the three execute functions
    ///         (the PiggyGuardCallback contract; set after deployment).
    address public executor;

    uint256 public riskBalance;
    uint256 public safeBalance;
    /// @notice Safe-asset amount spent on every DCA tick (8 decimals, USD).
    uint256 public dcaAmount;
    /// @notice Highest action id executed so far; callbacks with an id at or
    ///         below this are replays / out-of-order deliveries and are ignored.
    uint256 public lastActionId;
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
        // Fail at deployment, not at demo time: a zero feed address would make
        // every DCA revert, and a zero DCA amount would silently disable DCA.
        if (priceFeed_ == address(0)) revert ZeroAddress();
        if (dcaAmount_ == 0) revert ZeroAmount();
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
        // Zero is rejected: it would silently disable every automated action.
        // To pause execution instead, use pause().
        if (executor_ == address(0)) revert ZeroAddress();
        executor = executor_;
        emit ExecutorUpdated(executor_);
    }

    function setDcaAmount(uint256 dcaAmount_) external onlyOwner {
        if (dcaAmount_ == 0) revert ZeroAmount();
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
    /// @param actionId_ Monotonic id assigned by the reactive contract. A
    ///        duplicate or out-of-order id is ignored (event only, no revert)
    ///        so a replayed callback can never execute twice.
    function executeStopLoss(uint256 price_, uint256 actionId_)
        external
        onlyExecutor
        whenNotPaused
    {
        if (_consumeAction(actionId_)) return;
        uint256 sold = riskBalance;
        if (sold == 0) {
            // Nothing to sell: a zero-quantity "success" event would pollute
            // the evidence trail, so report the skip explicitly instead.
            emit StopLossSkipped("no risk balance", price_);
            return;
        }
        uint256 received = (sold * price_) / PRICE_SCALE;
        riskBalance = 0;
        safeBalance += received;
        emit StopLossExecuted(price_, sold, received);
    }

    /// @notice Sell TAKE_PROFIT_BPS of the risk position at `price_`.
    function executeTakeProfit(uint256 price_, uint256 actionId_)
        external
        onlyExecutor
        whenNotPaused
    {
        if (_consumeAction(actionId_)) return;
        uint256 sold = (riskBalance * TAKE_PROFIT_BPS) / 10000;
        if (sold == 0) {
            // Dust position: 50% rounds down to zero; skip, don't fake a sale.
            emit TakeProfitSkipped("position too small to sell 50%", price_);
            return;
        }
        uint256 received = (sold * price_) / PRICE_SCALE;
        riskBalance -= sold;
        safeBalance += received;
        emit TakeProfitExecuted(price_, sold, received);
    }

    /// @notice Spend `dcaAmount` of the safe asset to buy the risk asset at the
    ///         feed's latest price. Skips gracefully (no revert) when the safe
    ///         balance is too low, so a routine shortfall never fails a callback.
    function executeDCA(uint256 actionId_) external onlyExecutor whenNotPaused {
        if (_consumeAction(actionId_)) return;
        if (safeBalance < dcaAmount) {
            emit DcaSkipped("insufficient safe balance", safeBalance);
            return;
        }
        uint256 price = priceFeed.latestPrice();
        // Defence in depth: the feed rejects pushPrice(0), but a feed deployed
        // with a zero initial price would still divide by zero here.
        if (price == 0) revert ZeroPrice();
        uint256 bought = (dcaAmount * PRICE_SCALE) / price;
        if (bought == 0) {
            // Extreme price: the fixed amount buys nothing after rounding.
            // Skip without charging — never spend the full amount for zero.
            emit DcaSkipped("price too high: buys zero", safeBalance);
            return;
        }
        safeBalance -= dcaAmount;
        riskBalance += bought;
        emit DcaExecuted(price, dcaAmount, bought);
    }

    /// @dev Marks `actionId_` as consumed and returns false when it is new.
    ///      Returns true (and emits ActionIgnored) when it is a replay or an
    ///      out-of-order delivery, in which case the caller must do nothing.
    function _consumeAction(uint256 actionId_) internal returns (bool) {
        uint256 last = lastActionId;
        if (actionId_ <= last) {
            emit ActionIgnored(actionId_, last);
            return true;
        }
        lastActionId = actionId_;
        return false;
    }
}
