// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { PiggyGuardCallback } from "./PiggyGuardCallback.sol";

/// @title PiggyGuardReactive — Lasna reactive contract (Omni).
/// @notice Watches two event streams and orders the vault's three automated
///         actions, with no off-chain bot involved:
///         1. PriceUpdated from MockPriceFeed on Base Sepolia — price at or
///            below stopLoss orders a stop-loss sell; at or above takeProfit
///            orders a take-profit sell. Each crossing fires at most once
///            (latched until the price returns inside the band), so a price
///            that stays below the line does not spam callbacks.
///         2. Cron100 ticks on Lasna — each tick orders one DCA buy. While a
///            stop-loss or take-profit latch is set the position is in exit
///            mode, so DCA requests are suppressed until the price is back
///            inside the band.
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
///         (Perch P3); the latch stays set, and the owner can re-arm the
///         crossing with resetLatches() or setThresholds().
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

    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    event ActionRequested(string action, uint256 actionId, uint256 price, uint256 timestamp);
    event CallbackRequestFailed(uint256 actionId, bytes reason);
    event CallbackUpdated(address indexed callback);
    event ThresholdsUpdated(uint256 stopLoss, uint256 takeProfit);
    event DcaToggled(bool enabled);
    event LatchesReset();

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
    bool public dcaEnabled = true;

    /// @notice Latches: one callback per crossing; cleared when the price
    ///         returns inside the (stopLoss, takeProfit) band, when the owner
    ///         changes the thresholds, or via resetLatches(). A crossing of
    ///         one side also clears the opposite latch. A latch is set only
    ///         when a callback request was actually handed to the network:
    ///         a crossing seen before setCallback() wires the destination
    ///         does not consume the latch (fix-03, Perch P11).
    bool public stopLossLatched;
    bool public takeProfitLatched;

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
        stopLossLatched = false;
        takeProfitLatched = false;
        emit ThresholdsUpdated(stopLoss_, takeProfit_);
    }

    /// @notice Re-arm both crossings without touching the band: the recovery
    ///         path when a callback request failed (CallbackRequestFailed)
    ///         after its latch was set (review M5).
    function resetLatches() external onlyOwner {
        stopLossLatched = false;
        takeProfitLatched = false;
        emit LatchesReset();
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
            SYSTEM.unsubscribe(
                LASNA_CHAIN_ID,
                CRON_CONTRACT,
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
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
        // Cron tick on Lasna: one DCA buy per tick. DCA is the lowest-priority
        // strategy: while either exit latch is set, buying back in would undo
        // the stop-loss / take-profit, so the tick is skipped until the price
        // returns inside the band and the latches clear.
        if (
            log_.chainId == LASNA_CHAIN_ID && log_.contractAddress == CRON_CONTRACT
                && log_.topic0 == cronTopic
        ) {
            if (dcaEnabled && !stopLossLatched && !takeProfitLatched) {
                _requestDca();
            }
            return;
        }
        // Anything else: ignore silently, never revert.
    }

    function _onPrice(uint256 price_) internal {
        // A zero price can only come from a malformed log (the feed rejects
        // zero pushes and zero initial prices); it must never be read as
        // "below the stop-loss" (fix-03, Perch P2).
        if (price_ == 0) return;
        if (price_ <= stopLoss) {
            if (!stopLossLatched) {
                // The latch is set only when a request was really handed
                // out: before setCallback() wires the destination, the
                // crossing stays armed (fix-03, Perch P11).
                if (_requestStopLoss(price_)) {
                    stopLossLatched = true;
                    takeProfitLatched = false;
                }
            }
        } else if (price_ >= takeProfit) {
            if (!takeProfitLatched) {
                if (_requestTakeProfit(price_)) {
                    takeProfitLatched = true;
                    stopLossLatched = false;
                }
            }
        } else {
            // Back inside the band: re-arm both crossings (and, with them, DCA).
            stopLossLatched = false;
            takeProfitLatched = false;
        }
    }

    /// @notice Request a stop-loss callback. The payload's first argument is
    ///         address(0) by design: the network injects this contract's
    ///         address there for the callback contract to verify.
    /// @return sent False when no callback destination is wired yet: the
    ///         caller must NOT latch the crossing in that case (Perch P11).
    function _requestStopLoss(uint256 price_) internal returns (bool sent) {
        // M12: until setCallback wires the destination, requests are dropped
        // silently — a callback to address(0) can never succeed, but every
        // react() that asks for one is still billed against the reserves.
        if (callback == address(0)) return false;
        uint256 actionId = ++actionCounter;
        bytes memory payload =
            abi.encodeCall(PiggyGuardCallback.executeStopLoss, (address(0), price_, actionId));
        emit ActionRequested("stopLoss", actionId, price_, block.timestamp);
        _sendCallback(actionId, payload);
        return true;
    }

    /// @notice Request a take-profit callback (same address(0) placeholder).
    function _requestTakeProfit(uint256 price_) internal returns (bool sent) {
        if (callback == address(0)) return false; // M12, see _requestStopLoss
        uint256 actionId = ++actionCounter;
        bytes memory payload =
            abi.encodeCall(PiggyGuardCallback.executeTakeProfit, (address(0), price_, actionId));
        emit ActionRequested("takeProfit", actionId, price_, block.timestamp);
        _sendCallback(actionId, payload);
        return true;
    }

    /// @notice Request a DCA callback. The vault reads the price from the
    ///         feed itself, so the payload carries no price.
    function _requestDca() internal {
        if (callback == address(0)) return; // M12, see _requestStopLoss
        uint256 actionId = ++actionCounter;
        bytes memory payload = abi.encodeCall(PiggyGuardCallback.executeDCA, (address(0), actionId));
        emit ActionRequested("dca", actionId, 0, block.timestamp);
        _sendCallback(actionId, payload);
    }

    /// @dev A failed request must not revert react() (the network bills
    ///      reverted reactions anyway) and must not vanish silently either:
    ///      the failure is emitted as CallbackRequestFailed so the lost
    ///      action is observable and the owner can re-arm it (Perch P3).
    function _sendCallback(uint256 actionId_, bytes memory payload_) internal {
        try SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                recipient: callback,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload_
            })
        ) { } catch (bytes memory reason) {
            emit CallbackRequestFailed(actionId_, reason);
        }
    }
}
