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
///      Execution is a virtual swap at the feed's current price, so the
///      demo never depends on a testnet DEX pool. The on-chain proof this project offers
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
///      reported as Skipped events instead.
///
///      Execution price (fix-04, Perch round-3 C1/C2): stop-loss and
///      take-profit trade at the feed's CURRENT price
///      (`priceFeed.latestPrice()`), never at the payload's trigger price.
///      The trigger price is one cross-chain hop old by the time the
///      callback lands, so trading on it — or refusing to trade because it
///      moved — are both wrong: a crash must still stop out (at the worse
///      current price), and a recovery must not stop out at all. The
///      payload therefore also carries the threshold the reactive contract
///      used, and the vault re-checks the condition against the execution
///      price: a stop-loss executes only while `execPrice <= stopLoss`,
///      a take-profit only while `execPrice >= takeProfit`. The trigger
///      price itself is kept for logs and Skipped events only.
contract PiggyVault {
    uint256 public constant PRICE_SCALE = 1e8;
    /// @notice Take-profit sells this share of the risk position per trigger.
    uint256 public constant TAKE_PROFIT_BPS = 5000; // 50%
    /// @notice Band used by the DCA circuit breaker (20%): a tick whose
    ///         feed price deviates from the reference price by more than
    ///         this is treated as a possible level shift and must be
    ///         confirmed (see DCA_CONFIRMATION_TICKS) before trading
    ///         resumes at the new level.
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 2000; // 20%
    /// @notice Consecutive ticks that must cluster near a candidate price
    ///         before the DCA circuit breaker adopts it as the new
    ///         reference level (fix-04, Perch round-3 H3).
    uint256 public constant DCA_CONFIRMATION_TICKS = 3;

    event Funded(string asset, uint256 amount);
    event Withdrawn(string asset, uint256 amount);
    event StopLossExecuted(uint256 actionId, uint256 price, uint256 sold, uint256 received);
    event TakeProfitExecuted(uint256 actionId, uint256 price, uint256 sold, uint256 received);
    event StopLossSkipped(string reason, uint256 actionId, uint256 price);
    event TakeProfitSkipped(string reason, uint256 actionId, uint256 price);
    event DcaExecuted(uint256 actionId, uint256 price, uint256 spent, uint256 bought);
    event DcaSkipped(string reason, uint256 actionId, uint256 safeBalance);
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
    /// @notice Reference price for the DCA circuit breaker: the feed price
    ///         of the last executed DCA tick (0 before the first one). A
    ///         tick whose feed price deviates from it by more than
    ///         MAX_PRICE_DEVIATION_BPS does NOT trade and does NOT move the
    ///         reference; instead the tick's price becomes (or confirms) a
    ///         candidate new level — see dcaCandidatePrice (fix-04, H3).
    uint256 public dcaReferencePrice;
    /// @notice Candidate new level for the DCA circuit breaker: the first
    ///         price seen far away from dcaReferencePrice. While a candidate
    ///         is pending, ticks near the reference clear it (the jump was
    ///         a spike) and ticks near the candidate confirm it.
    uint256 public dcaCandidatePrice;
    /// @notice How many consecutive ticks have clustered within
    ///         MAX_PRICE_DEVIATION_BPS of dcaCandidatePrice. When the count
    ///         reaches DCA_CONFIRMATION_TICKS the candidate is adopted as
    ///         the new dcaReferencePrice and that tick trades; before that
    ///         the ticks are skipped, so a single wild print can never
    ///         re-baseline the breaker on its own (fix-04, H3).
    uint256 public dcaCandidateCount;
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
        // A zero fund would emit a meaningless Funded event (Perch round-3
        // L1); reject it like every other zero amount in this contract.
        if (amount_ == 0) revert ZeroAmount();
        riskBalance += amount_;
        emit Funded("risk", amount_);
    }

    function fundSafe(uint256 amount_) external onlyOwner {
        // Same zero guard as fundRisk: a zero fund emits a meaningless
        // Funded event and hides a mistyped amount (batch A, item 5).
        if (amount_ == 0) revert ZeroAmount();
        safeBalance += amount_;
        emit Funded("safe", amount_);
    }

    function withdrawRisk(uint256 amount_) external onlyOwner {
        if (amount_ == 0) revert ZeroAmount(); // Perch round-3 L1
        if (amount_ > riskBalance) revert InsufficientBalance(amount_, riskBalance);
        riskBalance -= amount_;
        emit Withdrawn("risk", amount_);
    }

    function withdrawSafe(uint256 amount_) external onlyOwner {
        // Same zero guard as withdrawRisk (batch A, item 5).
        if (amount_ == 0) revert ZeroAmount();
        if (amount_ > safeBalance) revert InsufficientBalance(amount_, safeBalance);
        safeBalance -= amount_;
        emit Withdrawn("safe", amount_);
    }

    function setExecutor(address executor_) external onlyOwner {
        // Zero is rejected: it would silently disable every automated action.
        // To pause execution instead, use pause().
        if (executor_ == address(0)) revert ZeroAddress();
        // Re-setting the SAME executor (a misclick, or an attempt to
        // "re-arm" the vault) must change nothing: resetting the watermarks
        // here would make every already-executed id valid again, so a
        // re-delivered take-profit would really sell a second time
        // (fix-04, Perch round-3 H4).
        if (executor_ == executor) {
            emit ExecutorUpdated(executor_);
            return;
        }
        executor = executor_;
        // A fresh executor (e.g. a redeployed reactive + callback pair)
        // numbers its actions from 1 again. Resetting the watermarks keeps
        // those first actions from being misread as replays of the old
        // executor's deliveries (Perch P4). The DCA breaker state belongs
        // to the old executor's tick history too: a stale reference price
        // (and a half-confirmed candidate) must not greet the new
        // executor's first tick (fix-04, Perch round-3 H4).
        lastStopLossId = 0;
        lastTakeProfitId = 0;
        lastDcaId = 0;
        dcaReferencePrice = 0;
        dcaCandidatePrice = 0;
        dcaCandidateCount = 0;
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

    /// @notice Sell the entire risk position into the safe asset.
    /// @param triggerPrice_ The price the reactive contract saw when it
    ///        ordered this stop-loss. Used for logs / Skipped events only:
    ///        the trade itself executes at the feed's current price, and
    ///        only if the stop-loss condition still holds at that price
    ///        (fix-04, Perch round-3 C1/C2).
    /// @param stopLossThreshold_ The stop-loss line from the reactive
    ///        contract's band, carried in the payload so the vault can
    ///        re-check the condition at execution time.
    /// @param actionId_ Id assigned by the reactive contract (one counter
    ///        shared by all action types). Replay protection is per type:
    ///        only a stop-loss delivery at or below `lastStopLossId` is
    ///        ignored; other action types never block a stop-loss.
    function executeStopLoss(uint256 triggerPrice_, uint256 stopLossThreshold_, uint256 actionId_)
        external
        onlyExecutor
    {
        if (actionId_ <= lastStopLossId) {
            emit ActionIgnored(actionId_, lastStopLossId);
            return;
        }
        // Defence in depth (batch A, item 6): a zero threshold in the payload
        // is a malformed request. With stopLoss == 0 the re-check below can
        // never pass for a real price, so the action would be silently
        // meaningless — name the reason instead of letting it read as
        // "condition no longer holds".
        if (stopLossThreshold_ == 0) {
            emit StopLossSkipped("zero stop-loss threshold", actionId_, triggerPrice_);
            return;
        }
        if (paused) {
            emit StopLossSkipped("vault paused", actionId_, triggerPrice_);
            return;
        }
        uint256 execPrice = priceFeed.latestPrice();
        // The feed itself can never hold zero (constructor and pushPrice
        // reject it), but the vault still refuses to trade on a zero
        // execution price — as a skip, not a revert (Perch P3).
        if (execPrice == 0) {
            emit StopLossSkipped("zero feed price", actionId_, triggerPrice_);
            return;
        }
        // Condition re-check at the execution price (fix-04, C2): if the
        // price has recovered above the stop-loss line while the callback
        // was in flight, the stop-loss no longer applies — selling here
        // would exit a position the strategy wants to keep. Conversely a
        // price that kept crashing still executes below, at execPrice:
        // the stop-loss must work hardest exactly when the market moves
        // most (fix-04, C1).
        if (execPrice > stopLossThreshold_) {
            emit StopLossSkipped("stop-loss condition no longer holds", actionId_, triggerPrice_);
            return;
        }
        uint256 sold = riskBalance;
        if (sold == 0) {
            // Nothing to sell: a zero-quantity "success" event would pollute
            // the evidence trail, so report the skip explicitly instead.
            emit StopLossSkipped("no risk balance", actionId_, triggerPrice_);
            return;
        }
        uint256 received = (sold * execPrice) / PRICE_SCALE;
        // A sale that yields nothing must not clear the position: at a very
        // low execution price the whole position can round to zero proceeds,
        // and zeroing it for zero income would burn it (mirror of the
        // take-profit M6 guard, batch A item 4). Skip; the id stays usable.
        if (received == 0) {
            emit StopLossSkipped("proceeds would be zero", actionId_, triggerPrice_);
            return;
        }
        lastStopLossId = actionId_;
        riskBalance = 0;
        safeBalance += received;
        emit StopLossExecuted(actionId_, execPrice, sold, received);
    }

    /// @notice Sell TAKE_PROFIT_BPS of the risk position. Like the
    ///         stop-loss, the trade executes at the feed's current price
    ///         and only if the take-profit condition still holds there
    ///         (fix-04, Perch round-3 C1/C2).
    /// @param triggerPrice_ Trigger observation, for logs only.
    /// @param takeProfitThreshold_ The take-profit line from the reactive
    ///        contract's band, carried in the payload for the re-check.
    function executeTakeProfit(
        uint256 triggerPrice_,
        uint256 takeProfitThreshold_,
        uint256 actionId_
    ) external onlyExecutor {
        if (actionId_ <= lastTakeProfitId) {
            emit ActionIgnored(actionId_, lastTakeProfitId);
            return;
        }
        // Defence in depth (batch A, item 6): a zero take-profit threshold
        // can never be reached by a real price, so the re-check below would
        // always skip with a misleading reason. Name it.
        if (takeProfitThreshold_ == 0) {
            emit TakeProfitSkipped("zero take-profit threshold", actionId_, triggerPrice_);
            return;
        }
        if (paused) {
            emit TakeProfitSkipped("vault paused", actionId_, triggerPrice_);
            return;
        }
        uint256 execPrice = priceFeed.latestPrice();
        if (execPrice == 0) {
            emit TakeProfitSkipped("zero feed price", actionId_, triggerPrice_);
            return;
        }
        // Condition re-check (fix-04, C2): a price that fell back below
        // the take-profit line while the callback was in flight must not
        // be sold as a "take-profit".
        if (execPrice < takeProfitThreshold_) {
            emit TakeProfitSkipped(
                "take-profit condition no longer holds", actionId_, triggerPrice_
            );
            return;
        }
        uint256 sold = (riskBalance * TAKE_PROFIT_BPS) / 10000;
        if (sold == 0) {
            if (riskBalance == 0) {
                emit TakeProfitSkipped("no risk balance", actionId_, triggerPrice_);
                return;
            }
            // Dust position: 50% rounds down to zero. Sell the remainder
            // instead of skipping forever and locking the dust (Perch P18).
            sold = riskBalance;
        }
        uint256 received = (sold * execPrice) / PRICE_SCALE;
        // A sale that yields nothing must not clear the position: at a
        // very low execution price the dust remainder rounds to zero
        // proceeds, and zeroing the position for zero income would burn
        // it (fix-04, Perch round-3 M6). Skip; the id stays usable.
        if (received == 0) {
            emit TakeProfitSkipped("proceeds would be zero", actionId_, triggerPrice_);
            return;
        }
        lastTakeProfitId = actionId_;
        riskBalance -= sold;
        safeBalance += received;
        emit TakeProfitExecuted(actionId_, execPrice, sold, received);
    }

    /// @notice Spend `dcaAmount` of the safe asset to buy the risk asset at
    ///         the feed's latest price. Skips gracefully (no revert) when the
    ///         safe balance is too low, the vault is paused, or the feed
    ///         price jumped far from the reference level and the jump has
    ///         not been confirmed yet, so a routine shortfall never fails
    ///         a callback.
    function executeDCA(uint256 actionId_) external onlyExecutor {
        if (actionId_ <= lastDcaId) {
            emit ActionIgnored(actionId_, lastDcaId);
            return;
        }
        if (paused) {
            emit DcaSkipped("vault paused", actionId_, safeBalance);
            return;
        }
        if (safeBalance < dcaAmount) {
            emit DcaSkipped("insufficient safe balance", actionId_, safeBalance);
            return;
        }
        uint256 price = priceFeed.latestPrice();
        // Defence in depth: the feed rejects zero prices (constructor and
        // pushPrice), but the vault still refuses to divide by zero — as a
        // skip, not a revert, so the callback itself never fails (Perch P3).
        if (price == 0) {
            emit DcaSkipped("zero price", actionId_, safeBalance);
            return;
        }
        // Circuit breaker (review PG-N3, redesigned in fix-04 per Perch
        // round-3 H3): a tick far away from the reference level does NOT
        // trade and does NOT move the reference — the old design
        // re-baselined after a single skipped tick, which made the
        // "breaker" a one-tick delay, not a protection. Now the far-away
        // price becomes a candidate level: only when
        // DCA_CONFIRMATION_TICKS consecutive ticks cluster within the
        // deviation band of the candidate is the candidate adopted as the
        // new reference, and the confirming tick itself trades at the new
        // level. A tick back near the reference clears the candidate, so
        // the confirming ticks must be consecutive.
        if (_deviatesTooFar(price, dcaReferencePrice)) {
            if (dcaCandidatePrice != 0 && !_deviatesTooFar(price, dcaCandidatePrice)) {
                dcaCandidateCount += 1;
            } else {
                // First far tick, or a tick far from the candidate too:
                // (re)start the confirmation at this price.
                dcaCandidatePrice = price;
                dcaCandidateCount = 1;
            }
            if (dcaCandidateCount < DCA_CONFIRMATION_TICKS) {
                emit DcaSkipped("price moved too far since last DCA", actionId_, safeBalance);
                return;
            }
            // Confirmed level shift: adopt the candidate and fall through
            // so this tick trades at the new level.
            dcaReferencePrice = dcaCandidatePrice;
            dcaCandidatePrice = 0;
            dcaCandidateCount = 0;
        } else {
            // Back near the reference: any pending candidate was a spike.
            dcaCandidatePrice = 0;
            dcaCandidateCount = 0;
        }
        uint256 bought = (dcaAmount * PRICE_SCALE) / price;
        if (bought == 0) {
            // Extreme price: the fixed amount buys nothing after rounding.
            // Skip without charging — never spend the full amount for zero.
            emit DcaSkipped("price too high: buys zero", actionId_, safeBalance);
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
