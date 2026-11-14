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
///
///      Replay protection (fix-03, review PG-N1 / Perch P1): the reactive
///      contract numbers actions with one shared counter, but this vault
///      keeps a SEPARATE watermark per action type. A late take-profit can
///      therefore never swallow an in-flight stop-loss (the old single
///      watermark did exactly that), while a genuine replay of the same
///      action type is still ignored. Only an action that actually executes
///      advances its watermark: a skipped action (paused, zero or deviating
///      price, nothing to sell, insufficient balance) leaves the id usable,
///      so the same delivery can still succeed when it is re-driven after
///      the blocking condition clears.
///
///      Guard failures never revert (fix-03, Perch P3/P16): a reverting
///      callback is a permanently lost action, so "not now" conditions are
///      reported as Skipped events instead. Prices are sanity-checked
///      against the feed (Perch P5/P17): a trigger price that deviates from
///      `priceFeed.latestPrice()` by more than MAX_PRICE_DEVIATION_BPS is
///      skipped, never traded on.
contract PiggyVault {
    uint256 public constant PRICE_SCALE = 1e8;
    /// @notice Take-profit sells this share of the risk position per trigger.
    uint256 public constant TAKE_PROFIT_BPS = 5000; // 50%
    /// @notice Maximum allowed deviation between a callback's trigger price
    ///         and the feed's latest price (20%). Beyond it the action is
    ///         skipped: the price the reactive contract saw is too far from
    ///         the price the vault can verify, so trading on it is unsafe.
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 2000; // 20%

    event Funded(string asset, uint256 amount);
    event Withdrawn(string asset, uint256 amount);
    event StopLossExecuted(uint256 actionId, uint256 price, uint256 sold, uint256 received);
    event TakeProfitExecuted(uint256 actionId, uint256 price, uint256 sold, uint256 received);
    event StopLossSkipped(string reason, uint256 price);
    event TakeProfitSkipped(string reason, uint256 price);
    event DcaExecuted(uint256 actionId, uint256 price, uint256 spent, uint256 bought);
    event DcaSkipped(string reason, uint256 safeBalance);
    event ActionIgnored(uint256 actionId, uint256 lastActionId);
    event ExecutorUpdated(address indexed executor);
    event DcaAmountUpdated(uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotOwner(address sender);
    error NotExecutor(address sender);
    error InsufficientBalance(uint256 requested, uint256 available);
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
    /// @notice Per-type replay watermarks: highest action id that actually
    ///         EXECUTED per action type. Deliveries at or below the watermark
    ///         of their own type are replays and are ignored; deliveries of
    ///         other types are unaffected (see the contract-level note).
    uint256 public lastStopLossId;
    uint256 public lastTakeProfitId;
    uint256 public lastDcaId;
    /// @notice Reference price for the DCA circuit breaker: the feed price of
    ///         the last evaluated DCA tick (0 before the first one). A tick
    ///         whose feed price deviates from it by more than
    ///         MAX_PRICE_DEVIATION_BPS is skipped once and re-baselines the
    ///         reference, so a genuine level shift delays DCA by one tick
    ///         instead of disabling it forever (review PG-N3 mitigation).
    uint256 public dcaReferencePrice;
    bool public paused;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor(msg.sender);
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
        // A fresh executor (e.g. a redeployed reactive + callback pair)
        // numbers its actions from 1 again. Resetting the watermarks keeps
        // those first actions from being misread as replays of the old
        // executor's deliveries (Perch P4).
        lastStopLossId = 0;
        lastTakeProfitId = 0;
        lastDcaId = 0;
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
    /// @param actionId_ Id assigned by the reactive contract (one counter
    ///        shared by all action types). Replay protection is per type:
    ///        only a stop-loss delivery at or below `lastStopLossId` is
    ///        ignored; other action types never block a stop-loss.
    function executeStopLoss(uint256 price_, uint256 actionId_) external onlyExecutor {
        if (actionId_ <= lastStopLossId) {
            emit ActionIgnored(actionId_, lastStopLossId);
            return;
        }
        if (paused) {
            emit StopLossSkipped("vault paused", price_);
            return;
        }
        // A zero trigger price would sell the whole position for nothing
        // (Perch P2 / review PG-N2). Skip, never trade.
        if (price_ == 0) {
            emit StopLossSkipped("zero price", price_);
            return;
        }
        if (_deviatesTooFar(price_, priceFeed.latestPrice())) {
            emit StopLossSkipped("price deviates from feed", price_);
            return;
        }
        uint256 sold = riskBalance;
        if (sold == 0) {
            // Nothing to sell: a zero-quantity "success" event would pollute
            // the evidence trail, so report the skip explicitly instead.
            emit StopLossSkipped("no risk balance", price_);
            return;
        }
        lastStopLossId = actionId_;
        uint256 received = (sold * price_) / PRICE_SCALE;
        riskBalance = 0;
        safeBalance += received;
        emit StopLossExecuted(actionId_, price_, sold, received);
    }

    /// @notice Sell TAKE_PROFIT_BPS of the risk position at `price_`.
    function executeTakeProfit(uint256 price_, uint256 actionId_) external onlyExecutor {
        if (actionId_ <= lastTakeProfitId) {
            emit ActionIgnored(actionId_, lastTakeProfitId);
            return;
        }
        if (paused) {
            emit TakeProfitSkipped("vault paused", price_);
            return;
        }
        if (price_ == 0) {
            emit TakeProfitSkipped("zero price", price_);
            return;
        }
        if (_deviatesTooFar(price_, priceFeed.latestPrice())) {
            emit TakeProfitSkipped("price deviates from feed", price_);
            return;
        }
        uint256 sold = (riskBalance * TAKE_PROFIT_BPS) / 10000;
        if (sold == 0) {
            if (riskBalance == 0) {
                emit TakeProfitSkipped("no risk balance", price_);
                return;
            }
            // Dust position: 50% rounds down to zero. Sell the remainder
            // instead of skipping forever and locking the dust (Perch P18).
            sold = riskBalance;
        }
        lastTakeProfitId = actionId_;
        uint256 received = (sold * price_) / PRICE_SCALE;
        riskBalance -= sold;
        safeBalance += received;
        emit TakeProfitExecuted(actionId_, price_, sold, received);
    }

    /// @notice Spend `dcaAmount` of the safe asset to buy the risk asset at
    ///         the feed's latest price. Skips gracefully (no revert) when the
    ///         safe balance is too low, the vault is paused, or the feed
    ///         price moved too far since the last tick, so a routine
    ///         shortfall never fails a callback.
    function executeDCA(uint256 actionId_) external onlyExecutor {
        if (actionId_ <= lastDcaId) {
            emit ActionIgnored(actionId_, lastDcaId);
            return;
        }
        if (paused) {
            emit DcaSkipped("vault paused", safeBalance);
            return;
        }
        if (safeBalance < dcaAmount) {
            emit DcaSkipped("insufficient safe balance", safeBalance);
            return;
        }
        uint256 price = priceFeed.latestPrice();
        // Defence in depth: the feed rejects zero prices (constructor and
        // pushPrice), but the vault still refuses to divide by zero — as a
        // skip, not a revert, so the callback itself never fails (Perch P3).
        if (price == 0) {
            emit DcaSkipped("zero price", safeBalance);
            return;
        }
        // Circuit breaker (review PG-N3): the tick was requested one cross-
        // chain hop ago; if the feed price has since jumped far away from
        // the last evaluated tick, do not buy at the new level blind. Skip
        // this tick and re-baseline, so trading resumes on the next tick.
        if (_deviatesTooFar(price, dcaReferencePrice)) {
            dcaReferencePrice = price;
            emit DcaSkipped("price moved too far since last DCA", safeBalance);
            return;
        }
        uint256 bought = (dcaAmount * PRICE_SCALE) / price;
        if (bought == 0) {
            // Extreme price: the fixed amount buys nothing after rounding.
            // Skip without charging — never spend the full amount for zero.
            emit DcaSkipped("price too high: buys zero", safeBalance);
            return;
        }
        lastDcaId = actionId_;
        dcaReferencePrice = price;
        safeBalance -= dcaAmount;
        riskBalance += bought;
        emit DcaExecuted(actionId_, price, dcaAmount, bought);
    }

    /// @dev True when `price_` differs from `reference_` by more than
    ///      MAX_PRICE_DEVIATION_BPS of the reference. A zero reference means
    ///      "nothing to compare against" and never deviates.
    function _deviatesTooFar(uint256 price_, uint256 reference_) internal pure returns (bool) {
        if (reference_ == 0) return false;
        uint256 diff = price_ > reference_ ? price_ - reference_ : reference_ - price_;
        return diff * 10000 > reference_ * MAX_PRICE_DEVIATION_BPS;
    }
}
