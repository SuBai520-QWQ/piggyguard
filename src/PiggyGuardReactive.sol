// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { PiggyGuardCallback } from "./PiggyGuardCallback.sol";

/// @title PiggyGuardReactive — Lasna reactive contract (Omni).
/// @notice Watches three event streams and orders the vault's three automated
///         actions, with no off-chain bot involved:
///         1. PriceUpdated from MockPriceFeed on Base Sepolia — price at or
///            below stopLoss orders a stop-loss sell; at or above takeProfit
///            orders a take-profit sell. Each crossing fires at most once
///            (latched until the price returns inside the band), so a price
///            that stays below the line does not spam callbacks.
///         2. Cron100 ticks on Lasna — each tick orders one DCA buy. While a
///            stop-loss or take-profit latch is set the position is in exit
///            mode, so DCA requests are suppressed until the price is back
///            inside the band. The tick also drives the latch timeout
///            re-arm described below.
///         3. The vault's own result events on Base Sepolia
///            (StopLossExecuted / StopLossSkipped / TakeProfitExecuted /
///            TakeProfitSkipped) — see "Latch lifecycle" below.
///         Non-matching logs are ignored silently; react() never reverts on
///         purpose, because the network bills reverted reactions anyway
///         (official docs) and a revert must never be used as a filter.
///         Every callback carries a monotonically increasing actionId from
///         one shared counter; the vault keeps a SEPARATE replay watermark
///         per action type, so an out-of-order delivery of one type can
///         never swallow an action of another type (fix-03, review PG-N1),
///         while a genuine same-type replay is still ignored on the
///         destination chain. A failed callback request is caught and
///         reported via CallbackRequestFailed instead of reverting react()
///         (Perch P3); the latch is NOT set in that case (fix-04, Perch
///         round-3 H1), so the next price event retries the crossing on
///         its own, and the owner can additionally re-run the judgement
///         at any time with forceCheck() or re-arm with resetLatches()
///         or setThresholds().
///
///         Latch lifecycle (fix-05, Perch round-4 C1). A latch used to be
///         set the moment the system contract accepted the request, but the
///         destination-chain delivery result was invisible from Lasna: when
///         the callback never landed (callback proxy reserve at zero, a
///         selector mismatch, a reverted callback) the vault emitted
///         nothing, the latch stayed set, and a quiet feed meant the action
///         was never ordered again. Two layers close that:
///
///           Layer 1 — result-event confirmation. The owner wires the vault
///           with setVault(), which subscribes to the four vault result
///           events on Base Sepolia. Any result event for the action type
///           whose actionId is at or above the pending one clears that
///           latch. Nothing is re-sent from the event handler: the next
///           PriceUpdated re-runs _onPrice() and decides on its own, so
///           there is no resend loop and no need to parse the Skipped
///           reason string. (Matching on actionId, not merely on the event
///           type, is what keeps a late result for an OLD request from
///           clearing a FRESH latch and letting a take-profit sell twice.)
///
///           Layer 2 — timeout re-arm. A latch also records the Lasna block
///           it was set at. Each Cron tick checks whether a latch has been
///           set for more than REARM_TIMEOUT_BLOCKS without a confirming
///           result event; if so it clears the latch and re-runs _onPrice()
///           at the last price seen from the feed. 300 blocks is roughly
///           three Cron periods (~2 min each at ~1s/block), i.e. far longer
///           than a normal cross-chain delivery, so the re-arm cannot race
///           a delivery that is merely slow. A re-arm that fails again is
///           retried by the same mechanism, at most once per 300 blocks.
///
///         Known limit: the timeout re-arm rides on the Cron subscription,
///         so with DCA disabled (setDcaEnabled(false) unsubscribes Cron)
///         only layer 1 and forceCheck() remain available.
/// @dev Omni migration notes (verified against the official basic demo loop,
///      stage2 §8.7 — Sepolia event -> Lasna react() -> Sepolia callback):
///      - SYSTEM = 0x8888888888888888888888888888888888888888, react() guarded
///        by onlySystem, callbacks via SYSTEM.requestCallbackV_1_0;
///      - every callback payload's FIRST argument is address(0) as a
///        placeholder — the network replaces its first 160 bits with this
///        contract's address so the callback contract can authenticate it.
///      Cron subscription target: per plan §2.1 the Cron events come from the
///      legacy system contract 0x0000...fffFfF; the constructor takes the cron
///      topic as a parameter and the subscription is re-verified live on Lasna
///      in stage 3 (if Cron ticks do not arrive, the subscribed contract
///      address is the first thing to re-check against current docs).
contract PiggyGuardReactive is AbstractReactive {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant LASNA_CHAIN_ID = 5318007;

    /// @notice Cron event emitter, per plan §2.1 (legacy system contract).
    address public constant CRON_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    /// @notice Cron100 topic: every 100 Lasna blocks (~2 min at ~1s/block).
    uint256 public constant CRON100_TOPIC =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    /// @notice keccak256("PriceUpdated(uint256,uint256)") — verified with cast.
    uint256 public constant PRICE_UPDATED_TOPIC =
        0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838;

    /// @notice Vault result events (fix-05, layer 1). Declared as bytes32
    ///         because they are computed from the vault's signatures rather
    ///         than pasted as hex, so they cannot drift from PiggyVault.
    ///         StopLossExecuted(uint256 actionId, uint256 price, uint256 sold,
    ///         uint256 received) — actionId is the FIRST data word.
    bytes32 public constant STOP_LOSS_EXECUTED_TOPIC =
        keccak256("StopLossExecuted(uint256,uint256,uint256,uint256)");
    /// @notice TakeProfitExecuted(uint256,uint256,uint256,uint256) — actionId
    ///         is the FIRST data word.
    bytes32 public constant TAKE_PROFIT_EXECUTED_TOPIC =
        keccak256("TakeProfitExecuted(uint256,uint256,uint256,uint256)");
    /// @notice StopLossSkipped(string reason, uint256 actionId, uint256 price)
    ///         — actionId is the SECOND data word (the string offset is the
    ///         first).
    bytes32 public constant STOP_LOSS_SKIPPED_TOPIC =
        keccak256("StopLossSkipped(string,uint256,uint256)");
    /// @notice TakeProfitSkipped(string reason, uint256 actionId, uint256
    ///         price) — actionId is the SECOND data word.
    bytes32 public constant TAKE_PROFIT_SKIPPED_TOPIC =
        keccak256("TakeProfitSkipped(string,uint256,uint256)");

    /// @notice Blocks a latch may stay unconfirmed before the Cron tick
    ///         re-arms it (fix-05, layer 2). 300 blocks ≈ 3 Cron periods
    ///         (~2 min each at ~1s/block), comfortably longer than a normal
    ///         origin -> Lasna -> destination round trip, so a slow but
    ///         healthy delivery is never re-armed underneath.
    uint256 public constant REARM_TIMEOUT_BLOCKS = 300;

    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    event ActionRequested(string action, uint256 actionId, uint256 price, uint256 timestamp);
    event CallbackRequestFailed(uint256 actionId, bytes reason);
    event CallbackUpdated(address indexed callback);
    event VaultUpdated(address indexed vault);
    event ThresholdsUpdated(uint256 stopLoss, uint256 takeProfit);
    event DcaToggled(bool enabled);
    event DcaUnsubscribeFailed(bytes reason);
    event LatchesReset();
    /// @notice A vault result event confirmed (or closed) a pending action
    ///         and released its latch (fix-05, layer 1).
    event LatchClearedByResult(string action, uint256 actionId);
    /// @notice A latch stayed unconfirmed past REARM_TIMEOUT_BLOCKS and was
    ///         released by the Cron tick, which then re-ran the judgement at
    ///         `price` (fix-05, layer 2).
    event LatchRearmedOnTimeout(string action, uint256 price);

    error NotOwner(address sender);
    error ZeroAddress();
    error ZeroTopic();
    error InvalidThresholds(uint256 stopLoss, uint256 takeProfit);

    address public immutable owner;
    address public immutable priceFeed;
    uint256 public immutable cronTopic;

    /// @notice Prices use 8 decimals, same as the feed ($100.00 == 100_00000000).
    uint256 public stopLoss;
    uint256 public takeProfit;
    /// @notice Destination-chain callback contract (set after it is deployed).
    address public callback;
    /// @notice Destination-chain vault whose result events confirm our
    ///         actions (set after it is deployed, via setVault). While zero,
    ///         result events are not subscribed and layer 1 is inactive.
    address public vault;
    bool public dcaEnabled = true;

    /// @notice Latches: one callback per crossing; cleared when the price
    ///         returns inside the (stopLoss, takeProfit) band, when the owner
    ///         changes the thresholds, via resetLatches(), when the vault
    ///         reports a result for the pending action (layer 1), or when
    ///         the Cron tick finds the latch unconfirmed past
    ///         REARM_TIMEOUT_BLOCKS (layer 2). A crossing of one side also
    ///         clears the opposite latch. A latch is set only when a callback
    ///         request was actually handed to the network: a crossing seen
    ///         before setCallback() wires the destination does not consume
    ///         the latch (fix-03, Perch P11).
    bool public stopLossLatched;
    bool public takeProfitLatched;

    /// @notice Lasna block each latch was set at, for the layer-2 timeout.
    uint256 public stopLossLatchedAtBlock;
    uint256 public takeProfitLatchedAtBlock;

    /// @notice actionId of the request each latch is waiting on. A result
    ///         event only clears the latch when its actionId is at or above
    ///         this, so a late result for an older request cannot release a
    ///         fresh latch (fix-05, layer 1).
    uint256 public pendingStopLossId;
    uint256 public pendingTakeProfitId;

    /// @notice Last non-zero price seen from the feed. The layer-2 re-arm has
    ///         no way to read the origin-chain feed from Lasna, so it re-runs
    ///         the judgement at the most recent price it was told about.
    uint256 public lastObservedPrice;

    /// @notice Id handed to the next callback. Shared by all three actions so
    ///         the vault can reject duplicates and out-of-order deliveries.
    uint256 public actionCounter;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor(address priceFeed_, uint256 stopLoss_, uint256 takeProfit_, uint256 cronTopic_)
        payable
    {
        if (priceFeed_ == address(0)) revert ZeroAddress();
        // Same band rule as setThresholds, enforced from deployment: an
        // inverted band would make the in-band branch unreachable, and a
        // zero stop-loss can never trigger (real prices are > 0), which
        // would silently disable the stop-loss (fix-03, Perch P8).
        if (stopLoss_ == 0 || stopLoss_ >= takeProfit_) {
            revert InvalidThresholds(stopLoss_, takeProfit_);
        }
        // A zero Cron topic can never match a real tick; DCA would be
        // silently dead while the subscription still bills every tick.
        if (cronTopic_ == 0) revert ZeroTopic();
        owner = msg.sender;
        priceFeed = priceFeed_;
        stopLoss = stopLoss_;
        takeProfit = takeProfit_;
        cronTopic = cronTopic_;

        // 1. Price events from the feed on Base Sepolia (price in topic1).
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            priceFeed_,
            PRICE_UPDATED_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        // 2. Periodic Cron ticks on Lasna for DCA.
        SYSTEM.subscribe(
            LASNA_CHAIN_ID, CRON_CONTRACT, cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Breaks the deploy-order cycle: deploy this contract first, then
    ///         the callback contract, then backfill its address here.
    function setCallback(address callback_) external onlyOwner {
        if (callback_ == address(0)) revert ZeroAddress();
        callback = callback_;
        emit CallbackUpdated(callback_);
    }

    /// @notice Wire the destination-chain vault and subscribe to its four
    ///         result events on Base Sepolia (fix-05, layer 1). Same
    ///         post-deploy backfill pattern as setCallback: the vault is
    ///         deployed before this contract, so the address is known by the
    ///         time WireUpReactive runs. Re-setting the same address is a
    ///         no-op so a retry cannot double-subscribe (and double-bill).
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        if (vault_ == vault) return;
        vault = vault_;
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            vault_,
            uint256(STOP_LOSS_EXECUTED_TOPIC),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            vault_,
            uint256(STOP_LOSS_SKIPPED_TOPIC),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            vault_,
            uint256(TAKE_PROFIT_EXECUTED_TOPIC),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID,
            vault_,
            uint256(TAKE_PROFIT_SKIPPED_TOPIC),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        emit VaultUpdated(vault_);
    }

    /// @notice Update the band. Rejects an inverted or degenerate band and
    ///         clears both latches: the old crossing no longer describes the
    ///         new band, so the next valid crossing must be able to fire.
    function setThresholds(uint256 stopLoss_, uint256 takeProfit_) external onlyOwner {
        // stopLoss_ == 0 is rejected for the same reason as in the
        // constructor: it would silently disable the stop-loss (Perch P8).
        if (stopLoss_ == 0 || stopLoss_ >= takeProfit_) {
            revert InvalidThresholds(stopLoss_, takeProfit_);
        }
        stopLoss = stopLoss_;
        takeProfit = takeProfit_;
        _clearStopLossLatch();
        _clearTakeProfitLatch();
        emit ThresholdsUpdated(stopLoss_, takeProfit_);
    }

    /// @notice Re-arm both crossings without touching the band: the recovery
    ///         path when a callback request failed (CallbackRequestFailed)
    ///         after its latch was set (review M5).
    function resetLatches() external onlyOwner {
        _clearStopLossLatch();
        _clearTakeProfitLatch();
        emit LatchesReset();
    }

    /// @notice Re-run the price judgement once for an owner-supplied price,
    ///         exactly as if a PriceUpdated log with that price had just
    ///         arrived (fix-04, Perch round-3 H2). resetLatches() alone
    ///         cannot recover a crossing when the feed then goes quiet —
    ///         no new event means no new judgement — so the owner passes
    ///         the last known price here to drive the judgement directly:
    ///         a price still outside the band re-fires the action, a price
    ///         back inside the band just clears the latches. The price is
    ///         owner-supplied because this contract cannot read the
    ///         origin-chain feed from Lasna.
    function forceCheck(uint256 price_) external onlyOwner {
        _onPrice(price_);
    }

    function setDcaEnabled(bool enabled_) external onlyOwner {
        if (enabled_ == dcaEnabled) return;
        dcaEnabled = enabled_;
        // Keep the Cron subscription in step with the flag (review M2): a
        // disabled DCA must stop the per-tick billing, not just the requests.
        if (enabled_) {
            SYSTEM.subscribe(
                LASNA_CHAIN_ID,
                CRON_CONTRACT,
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        } else {
            // Unsubscribing a subscription that is not active (e.g. the
            // constructor's subscribe never landed) may revert on the real
            // system contract; that must not brick the toggle, so the
            // failure is caught here (fix-04, Perch round-3 M3). The flag
            // above is the source of truth for whether DCA fires; a failed
            // unsubscribe only means the per-tick billing continues, which
            // must be observable rather than swallowed (batch A, item 7).
            try SYSTEM.unsubscribe(
                LASNA_CHAIN_ID,
                CRON_CONTRACT,
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            ) { } catch (bytes memory reason) {
                emit DcaUnsubscribeFailed(reason);
            }
        }
        emit DcaToggled(enabled_);
    }

    /// @inheritdoc IReactive
    function react(IReactive.LogRecord calldata log_) external override onlySystem {
        // Price event from our feed on Base Sepolia. The subscription tuple
        // already filters, but the handler re-checks chain + contract +
        // topic itself (fix-03, review L9 / Perch P10): a drifted or
        // lookalike log must never drive an action.
        if (
            log_.chainId == BASE_SEPOLIA_CHAIN_ID && log_.contractAddress == priceFeed
                && log_.topic0 == PRICE_UPDATED_TOPIC
        ) {
            _onPrice(log_.topic1);
            return;
        }
        // Vault result events on Base Sepolia (fix-05, layer 1). Same
        // re-check discipline: only the wired vault, only on the origin
        // chain, only the four result topics.
        if (
            vault != address(0) && log_.chainId == BASE_SEPOLIA_CHAIN_ID
                && log_.contractAddress == vault && _isVaultResultTopic(log_.topic0)
        ) {
            _onVaultResult(log_);
            return;
        }
        // Cron tick on Lasna: one DCA buy per tick. DCA is the lowest-priority
        // strategy: while either exit latch is set, buying back in would undo
        // the stop-loss / take-profit, so the tick is skipped until the price
        // returns inside the band and the latches clear. The tick also
        // carries the layer-2 timeout re-arm, because it is the only event
        // this contract is guaranteed to keep receiving while a latch is set.
        if (
            log_.chainId == LASNA_CHAIN_ID && log_.contractAddress == CRON_CONTRACT
                && log_.topic0 == cronTopic
        ) {
            _rearmStaleLatches();
            if (dcaEnabled && !stopLossLatched && !takeProfitLatched) {
                _requestDca();
            }
            return;
        }
        // Anything else: ignore silently, never revert.
    }

    /// @dev True for the four vault result topics this contract subscribes to.
    function _isVaultResultTopic(uint256 topic_) internal pure returns (bool) {
        bytes32 t = bytes32(topic_);
        return t == STOP_LOSS_EXECUTED_TOPIC || t == STOP_LOSS_SKIPPED_TOPIC
            || t == TAKE_PROFIT_EXECUTED_TOPIC || t == TAKE_PROFIT_SKIPPED_TOPIC;
    }

    /// @dev Layer 1: a vault result event releases the latch of its action
    ///      type. Deliberately does NOT re-send: the next PriceUpdated re-runs
    ///      _onPrice() and decides on its own, which is what keeps this free
    ///      of a resend loop.
    ///
    ///      The actionId is read straight out of the data words instead of
    ///      via abi.decode, so a malformed payload can never revert react().
    ///      Executed events put actionId in word 0; Skipped events put the
    ///      string offset in word 0 and actionId in word 1.
    function _onVaultResult(IReactive.LogRecord calldata log_) internal {
        bytes32 topic = bytes32(log_.topic0);

        if (topic == STOP_LOSS_EXECUTED_TOPIC || topic == STOP_LOSS_SKIPPED_TOPIC) {
            uint256 wordIndex = topic == STOP_LOSS_EXECUTED_TOPIC ? 0 : 1;
            (uint256 id, bool ok) = _dataWord(log_.data, wordIndex);
            if (!ok) return;
            if (!stopLossLatched) return;
            // A result for an older request must not release a fresh latch:
            // that would let the next price event re-fire an action the vault
            // already executed (a second take-profit sells another 50%).
            if (pendingStopLossId != 0 && id < pendingStopLossId) return;
            _clearStopLossLatch();
            emit LatchClearedByResult("stopLoss", id);
            return;
        }

        if (topic == TAKE_PROFIT_EXECUTED_TOPIC || topic == TAKE_PROFIT_SKIPPED_TOPIC) {
            uint256 wordIndex = topic == TAKE_PROFIT_EXECUTED_TOPIC ? 0 : 1;
            (uint256 id, bool ok) = _dataWord(log_.data, wordIndex);
            if (!ok) return;
            if (!takeProfitLatched) return;
            if (pendingTakeProfitId != 0 && id < pendingTakeProfitId) return;
            _clearTakeProfitLatch();
            emit LatchClearedByResult("takeProfit", id);
        }
    }

    /// @dev Layer 2: release a latch that has gone unconfirmed for longer than
    ///      REARM_TIMEOUT_BLOCKS and re-run the judgement at the last price
    ///      seen from the feed. At most one re-arm per Cron tick, so the
    ///      retry rate is bounded by the Cron period no matter how many
    ///      failures pile up.
    function _rearmStaleLatches() internal {
        if (stopLossLatched && block.number > stopLossLatchedAtBlock + REARM_TIMEOUT_BLOCKS) {
            _clearStopLossLatch();
            emit LatchRearmedOnTimeout("stopLoss", lastObservedPrice);
            if (lastObservedPrice != 0) _onPrice(lastObservedPrice);
            return;
        }
        if (takeProfitLatched && block.number > takeProfitLatchedAtBlock + REARM_TIMEOUT_BLOCKS) {
            _clearTakeProfitLatch();
            emit LatchRearmedOnTimeout("takeProfit", lastObservedPrice);
            if (lastObservedPrice != 0) _onPrice(lastObservedPrice);
        }
    }

    /// @dev Reads the `wordIndex_`-th 32-byte word of a calldata byte string.
    ///      Returns ok=false (and never reverts) when the payload is too short.
    function _dataWord(bytes calldata data_, uint256 wordIndex_)
        internal
        pure
        returns (uint256 word, bool ok)
    {
        if (data_.length < (wordIndex_ + 1) * 32) return (0, false);
        assembly {
            word := calldataload(add(data_.offset, mul(wordIndex_, 32)))
        }
        ok = true;
    }

    function _clearStopLossLatch() internal {
        stopLossLatched = false;
        stopLossLatchedAtBlock = 0;
        pendingStopLossId = 0;
    }

    function _clearTakeProfitLatch() internal {
        takeProfitLatched = false;
        takeProfitLatchedAtBlock = 0;
        pendingTakeProfitId = 0;
    }

    function _onPrice(uint256 price_) internal {
        // A zero price can only come from a malformed log (the feed rejects
        // zero pushes and zero initial prices); it must never be read as
        // "below the stop-loss" (fix-03, Perch P2).
        if (price_ == 0) return;
        // Remembered for the layer-2 re-arm, which cannot read the
        // origin-chain feed from Lasna (fix-05).
        lastObservedPrice = price_;
        if (price_ <= stopLoss) {
            if (!stopLossLatched) {
                // The latch is set only when a request was really handed
                // out: before setCallback() wires the destination, the
                // crossing stays armed (fix-03, Perch P11).
                if (_requestStopLoss(price_)) {
                    stopLossLatched = true;
                    stopLossLatchedAtBlock = block.number;
                    // _requestStopLoss consumed exactly one id, so the
                    // counter now holds the id this latch waits on.
                    pendingStopLossId = actionCounter;
                    _clearTakeProfitLatch();
                }
            }
        } else if (price_ >= takeProfit) {
            if (!takeProfitLatched) {
                if (_requestTakeProfit(price_)) {
                    takeProfitLatched = true;
                    takeProfitLatchedAtBlock = block.number;
                    pendingTakeProfitId = actionCounter;
                    _clearStopLossLatch();
                }
            }
        } else {
            // Back inside the band: re-arm both crossings (and, with them, DCA).
            _clearStopLossLatch();
            _clearTakeProfitLatch();
        }
    }

    /// @notice Request a stop-loss callback. The payload's first argument is
    ///         address(0) by design: the network injects this contract's
    ///         address there for the callback contract to verify. The
    ///         payload also carries the current stopLoss threshold so the
    ///         vault can re-check the condition at execution time and
    ///         trade at the feed's then-current price (fix-04, C1/C2).
    /// @return sent False when no callback destination is wired yet, or
    ///         when the system contract rejected the request: the caller
    ///         must NOT latch the crossing in either case (Perch P11,
    ///         round-3 H1).
    function _requestStopLoss(uint256 price_) internal returns (bool sent) {
        // M12: until setCallback wires the destination, requests are dropped
        // silently — a callback to address(0) can never succeed, but every
        // react() that asks for one is still billed against the reserves.
        if (callback == address(0)) return false;
        uint256 actionId = ++actionCounter;
        bytes memory payload = abi.encodeCall(
            PiggyGuardCallback.executeStopLoss, (address(0), price_, stopLoss, actionId)
        );
        sent = _sendCallback(actionId, payload);
        // ActionRequested is emitted only once the request has really been
        // handed to the network; on failure CallbackRequestFailed (inside
        // _sendCallback) is the only event, so the log never claims a
        // request that never left this contract (fix-04, round-3 L2).
        if (sent) {
            emit ActionRequested("stopLoss", actionId, price_, block.timestamp);
        }
        return sent;
    }

    /// @notice Request a take-profit callback (same address(0) placeholder,
    ///         carrying the current takeProfit threshold).
    function _requestTakeProfit(uint256 price_) internal returns (bool sent) {
        if (callback == address(0)) return false; // M12, see _requestStopLoss
        uint256 actionId = ++actionCounter;
        bytes memory payload = abi.encodeCall(
            PiggyGuardCallback.executeTakeProfit, (address(0), price_, takeProfit, actionId)
        );
        sent = _sendCallback(actionId, payload);
        if (sent) {
            emit ActionRequested("takeProfit", actionId, price_, block.timestamp);
        }
        return sent;
    }

    /// @notice Request a DCA callback. The vault reads the price from the
    ///         feed itself, so the payload carries no price.
    /// @return sent Same contract as _requestStopLoss; the Cron caller has
    ///         no latch to set, but the return value keeps the three
    ///         request paths uniform (fix-04, round-3 H1).
    function _requestDca() internal returns (bool sent) {
        if (callback == address(0)) return false; // M12, see _requestStopLoss
        uint256 actionId = ++actionCounter;
        bytes memory payload = abi.encodeCall(PiggyGuardCallback.executeDCA, (address(0), actionId));
        sent = _sendCallback(actionId, payload);
        if (sent) {
            emit ActionRequested("dca", actionId, 0, block.timestamp);
        }
        return sent;
    }

    /// @dev A failed request must not revert react() (the network bills
    ///      reverted reactions anyway) and must not vanish silently either:
    ///      the failure is emitted as CallbackRequestFailed so the lost
    ///      action is observable and the owner can re-arm it (Perch P3).
    /// @return sent True only when the system contract accepted the
    ///         request. Callers latch a crossing only on true — "we tried"
    ///         is not "it was sent" (fix-04, Perch round-3 H1).
    function _sendCallback(uint256 actionId_, bytes memory payload_) internal returns (bool sent) {
        try SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                recipient: callback,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload_
            })
        ) {
            return true;
        } catch (bytes memory reason) {
            emit CallbackRequestFailed(actionId_, reason);
            return false;
        }
    }
}
