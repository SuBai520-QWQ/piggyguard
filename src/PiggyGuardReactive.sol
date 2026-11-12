// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title PiggyGuardReactive — Lasna reactive contract (Omni).
/// @notice Watches two event streams and orders the vault's three automated
///         actions, with no off-chain bot involved:
///         1. PriceUpdated from MockPriceFeed on Base Sepolia — price at or
///            below stopLoss orders a stop-loss sell; at or above takeProfit
///            orders a take-profit sell. Each crossing fires at most once
///            (latched until the price returns inside the band), so a price
///            that stays below the line does not spam callbacks.
///         2. Cron100 ticks on Lasna — each tick orders one DCA buy.
///         Non-matching logs are ignored silently; react() never reverts on
///         purpose, because the network bills reverted reactions anyway
///         (official docs) and a revert must never be used as a filter.
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

    event ActionRequested(string action, uint256 price, uint256 timestamp);
    event CallbackUpdated(address indexed callback);
    event ThresholdsUpdated(uint256 stopLoss, uint256 takeProfit);
    event DcaToggled(bool enabled);

    error NotOwner(address sender);
    error ZeroAddress();

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
    ///         returns inside the (stopLoss, takeProfit) band.
    bool public stopLossLatched;
    bool public takeProfitLatched;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor(address priceFeed_, uint256 stopLoss_, uint256 takeProfit_, uint256 cronTopic_)
        payable
    {
        if (priceFeed_ == address(0)) revert ZeroAddress();
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

    function setThresholds(uint256 stopLoss_, uint256 takeProfit_) external onlyOwner {
        stopLoss = stopLoss_;
        takeProfit = takeProfit_;
        emit ThresholdsUpdated(stopLoss_, takeProfit_);
    }

    function setDcaEnabled(bool enabled_) external onlyOwner {
        dcaEnabled = enabled_;
        emit DcaToggled(enabled_);
    }

    /// @inheritdoc IReactive
    function react(IReactive.LogRecord calldata log_) external override onlySystem {
        // Price event from our feed on Base Sepolia.
        if (log_.contractAddress == priceFeed && log_.topic0 == PRICE_UPDATED_TOPIC) {
            _onPrice(log_.topic1);
            return;
        }
        // Cron tick on Lasna: one DCA buy per tick.
        if (log_.topic0 == cronTopic) {
            if (dcaEnabled) {
                _requestDca();
            }
            return;
        }
        // Anything else: ignore silently, never revert.
    }

    function _onPrice(uint256 price_) internal {
        if (price_ <= stopLoss) {
            if (!stopLossLatched) {
                stopLossLatched = true;
                takeProfitLatched = false;
                _requestCallback("executeStopLoss(address,uint256)", price_);
            }
        } else if (price_ >= takeProfit) {
            if (!takeProfitLatched) {
                takeProfitLatched = true;
                stopLossLatched = false;
                _requestCallback("executeTakeProfit(address,uint256)", price_);
            }
        } else {
            // Back inside the band: re-arm both crossings.
            stopLossLatched = false;
            takeProfitLatched = false;
        }
    }

    /// @notice Request a price-triggered callback (stop-loss / take-profit).
    ///         The payload's first argument is address(0) by design: the
    ///         network injects this contract's address there for the callback
    ///         contract to verify.
    function _requestCallback(string memory signature_, uint256 price_) internal {
        bytes memory payload = abi.encodeWithSignature(signature_, address(0), price_);
        emit ActionRequested(signature_, price_, block.timestamp);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                recipient: callback,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    /// @notice Request a DCA callback. The vault reads the price from the
    ///         feed itself, so the payload carries no price.
    function _requestDca() internal {
        bytes memory payload = abi.encodeWithSignature("executeDCA(address)", address(0));
        emit ActionRequested("executeDCA(address)", 0, block.timestamp);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID,
                recipient: callback,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }
}
