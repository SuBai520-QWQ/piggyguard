// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { PiggyVault } from "./PiggyVault.sol";

/// @title PiggyGuardCallback — destination-chain callback receiver (Base Sepolia).
/// @notice The contract the Reactive network calls back into. Authentication is
///         the Omni double guard (inherited from AbstractCallback):
///         - onlyServiceProvider: caller must be the destination-chain callback
///           proxy (its address is a constructor argument — the Base Sepolia
///           proxy address comes from the official docs at deploy time);
///         - onlyCallbackSender: the address the proxy injects into the
///           payload's first 160 bits must be our PiggyGuardReactive contract.
///         Each function forwards one automated action to the PiggyVault.
/// @dev The callback contract itself holds no funds; the callback proxy bills
///      delivery to this contract, so it must keep a reserve via the proxy's
///      depositTo (see plan R4). Deploy order (plan §2.2): reactive first,
///      then this contract, then setCallback() backfills the address.
contract PiggyGuardCallback is AbstractCallback {
    event ActionReceived(
        string action, address indexed reactiveSender, uint256 price, uint256 actionId
    );

    error ZeroAddress();

    PiggyVault public immutable vault;

    constructor(IPayable callbackProxy_, address reactiveContract_, address vault_)
        payable
        AbstractCallback(callbackProxy_, reactiveContract_)
    {
        // A zero in any of the three wiring addresses would silently disable
        // authentication or forwarding; fail the deployment instead.
        if (
            address(callbackProxy_) == address(0) || reactiveContract_ == address(0)
                || vault_ == address(0)
        ) revert ZeroAddress();
        vault = PiggyVault(vault_);
    }

    /// @notice Stop-loss: sell the whole risk position at the trigger price.
    function executeStopLoss(address sender, uint256 price, uint256 actionId)
        external
        onlyServiceProvider
        onlyCallbackSender(sender)
    {
        emit ActionReceived("stopLoss", sender, price, actionId);
        vault.executeStopLoss(price, actionId);
    }

    /// @notice Take-profit: sell half the risk position at the trigger price.
    function executeTakeProfit(address sender, uint256 price, uint256 actionId)
        external
        onlyServiceProvider
        onlyCallbackSender(sender)
    {
        emit ActionReceived("takeProfit", sender, price, actionId);
        vault.executeTakeProfit(price, actionId);
    }

    /// @notice DCA tick: buy the risk asset with the vault's fixed DCA amount.
    ///         The vault reads the price from the feed itself.
    function executeDCA(address sender, uint256 actionId)
        external
        onlyServiceProvider
        onlyCallbackSender(sender)
    {
        emit ActionReceived("dca", sender, 0, actionId);
        vault.executeDCA(actionId);
    }
}
