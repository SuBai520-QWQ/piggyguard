// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyVault } from "../src/PiggyVault.sol";
import { PiggyGuardCallback } from "../src/PiggyGuardCallback.sol";
import { PiggyGuardReactive } from "../src/PiggyGuardReactive.sol";

/// @notice Minimal view of the Reactive callback proxy on Base Sepolia: only
///         the reserve top-up WireUpBase needs. Declared here (rather than
///         relying on the full IPayable surface) so the script compiles
///         against any proxy build that exposes depositTo(address).
interface ICallbackProxy {
    function depositTo(address recipient) external payable;
}

/// @title PiggyGuard deploy script (stage 3 — testnets only).
/// @notice Deploy order follows plan §2.2: feed + vault (Base Sepolia) ->
///         reactive (Lasna, payable 0.1 lREACT) -> callback (Base Sepolia)
///         -> setCallback backfill + vault.setExecutor wiring.
///         Four steps, each on a specific chain — a script may only talk to
///         contracts that live on the chain its --rpc-url points at:
///           Step 1 (Base Sepolia): `forge script script/Deploy.s.sol:DeployBase
///             --rpc-url $BASE_SEPOLIA_RPC --broadcast`
///           Step 2 (Lasna): `forge script script/Deploy.s.sol:DeployReactive
///             --rpc-url $LASNA_RPC --broadcast`
///           Step 3 (Base Sepolia): `forge script script/Deploy.s.sol:WireUpBase
///             --rpc-url $BASE_SEPOLIA_RPC --broadcast`
///           Step 4 (Lasna): `forge script script/Deploy.s.sol:WireUpReactive
///             --rpc-url $LASNA_RPC --broadcast`
///         Required env vars: PRIVATE_KEY, BASE_SEPOLIA_CALLBACK_PROXY
///         (Base Sepolia callback proxy address, from dev.reactive.network),
///         plus the addresses printed by earlier steps (PRICE_FEED, VAULT,
///         REACTIVE, CALLBACK). Optional: INITIAL_PRICE (default $100),
///         STOP_LOSS (default $90), TAKE_PROFIT (default $120), DCA_AMOUNT
///         (default $10), REACTIVE_RESERVE (default 0.1 ether — the Lasna
///         reserve the reactive contract starts with; size it as
///         expected reactions × per-reaction cost and re-check `debt`
///         before demo day, see README "Reserves"), CALLBACK_RESERVE
///         (default 0.05 ether, in wei — the Base Sepolia reserve
///         WireUpBase deposits to the callback proxy for the callback
///         contract; 0 skips the deposit).
///         After deployment: fund the reactive contract's SYSTEM reserves with
///         `depositTo` (lREACT) and the callback contract's proxy reserves
///         (Base Sepolia ETH) — see README "Reserves" — or the loop silently
///         stops (plan R4). WireUpBase now performs the callback-side
///         deposit itself.
contract DeployBase is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 initialPrice = vm.envOr("INITIAL_PRICE", uint256(100_00000000));
        uint256 dcaAmount = vm.envOr("DCA_AMOUNT", uint256(10_00000000));

        // Prices are 8-decimal fixed point, not dollars: a bare `100` here
        // would mean $0.000001 and silently disable every trigger.
        require(
            initialPrice >= 1e8,
            "INITIAL_PRICE must be >= 1e8 (8-decimal fixed point: 1e8 == $1.00)"
        );

        vm.startBroadcast(deployerKey);
        MockPriceFeed feed = new MockPriceFeed(initialPrice);
        PiggyVault vault = new PiggyVault(address(feed), dcaAmount);
        vm.stopBroadcast();

        console.log("MockPriceFeed:", address(feed));
        console.log("PiggyVault:", address(vault));
        console.log("NEXT: deploy reactive on Lasna (DeployReactive), then");
        console.log("WireUpBase on Base Sepolia, then WireUpReactive on Lasna.");
        console.log("NOTE: the callback contract is deployed by WireUpBase, once");
        console.log("the reactive address is known (its address is immutable).");
    }
}

contract DeployReactive is Script {
    /// @notice Cron100 topic — must equal PiggyGuardReactive.CRON100_TOPIC.
    uint256 private constant CRON100_TOPIC =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address priceFeed = vm.envAddress("PRICE_FEED");
        uint256 stopLoss = vm.envOr("STOP_LOSS", uint256(90_00000000));
        uint256 takeProfit = vm.envOr("TAKE_PROFIT", uint256(120_00000000));
        // Reserve the reactive contract starts with (review H4/L7): was a
        // hardcoded 0.1 ether; now env-configurable with the same default.
        uint256 reserve = vm.envOr("REACTIVE_RESERVE", uint256(0.1 ether));

        // Thresholds are 8-decimal fixed point, not dollars: a bare `90`
        // would mean $0.0000009, i.e. a stop-loss that can never trigger.
        require(
            stopLoss >= 1e8,
            "STOP_LOSS must be >= 1e8 (8-decimal fixed point: 1e8 == $1.00)"
        );
        require(
            takeProfit >= 1e8,
            "TAKE_PROFIT must be >= 1e8 (8-decimal fixed point: 1e8 == $1.00)"
        );

        vm.startBroadcast(deployerKey);
        PiggyGuardReactive guard = new PiggyGuardReactive{ value: reserve }(
            priceFeed, stopLoss, takeProfit, CRON100_TOPIC
        );
        vm.stopBroadcast();

        console.log("PiggyGuardReactive (Lasna):", address(guard));
        console.log("NEXT (Base Sepolia): WireUpBase with REACTIVE=%s", address(guard));
    }
}

contract WireUpBase is Script {
    /// @notice Base Sepolia only. Deploys the callback contract and points the
    ///         vault's executor at it. Must NOT touch the Lasna reactive
    ///         contract: on this chain that address has no code, so a call to
    ///         it would revert the whole broadcast (review C1).
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("BASE_SEPOLIA_CALLBACK_PROXY");
        address reactive = vm.envAddress("REACTIVE");
        address vaultAddr = vm.envAddress("VAULT");
        // Callback-delivery reserve, in wei. 0 means "already funded, or
        // fund it by hand later" and skips the deposit instead of reverting.
        uint256 callbackReserve = vm.envOr("CALLBACK_RESERVE", uint256(0.05 ether));
        // Fail fast on a mistyped VAULT (review M7): the vault lives on this
        // chain, so it must have code here. The reactive address must NOT be
        // checked — it lives on Lasna and has no code on Base Sepolia (C1).
        require(vaultAddr.code.length > 0, "VAULT has no code on this chain");
        // Same fail-fast for the callback proxy: a mistyped proxy address
        // would deploy a callback whose onlyServiceProvider guard can never
        // be satisfied, and every callback would then be rejected.
        require(
            proxy.code.length > 0,
            "BASE_SEPOLIA_CALLBACK_PROXY has no code on this chain"
        );

        vm.startBroadcast(deployerKey);
        PiggyGuardCallback callback =
            new PiggyGuardCallback(IPayable(payable(proxy)), reactive, vaultAddr);
        PiggyVault(vaultAddr).setExecutor(address(callback));
        // The callback proxy bills delivery to the callback contract, so the
        // callback needs a reserve before the first callback lands (plan R4).
        // Without it the loop stops silently on the first delivery.
        if (callbackReserve > 0) {
            (bool ok,) = proxy.call{ value: callbackReserve }(
                abi.encodeCall(ICallbackProxy.depositTo, (address(callback)))
            );
            require(ok, "callback proxy depositTo failed");
        }
        vm.stopBroadcast();

        console.log("PiggyGuardCallback (Base Sepolia):", address(callback));
        console.log("vault.executor =", address(callback));
        if (callbackReserve > 0) {
            console.log("callback proxy reserve deposited (wei):", callbackReserve);
        } else {
            console.log("CALLBACK_RESERVE is 0: callback proxy left unfunded");
        }
        console.log("NEXT (Lasna): WireUpReactive with CALLBACK=%s", address(callback));
    }
}

contract WireUpReactive is Script {
    /// @notice Lasna only. Backfills the callback address on the reactive
    ///         contract (deploy order: reactive first, callback second).
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address reactive = vm.envAddress("REACTIVE");
        address callbackAddr = vm.envAddress("CALLBACK");
        // Fail fast on a mistyped REACTIVE (review M7): unlike in WireUpBase,
        // the reactive contract DOES live on this chain (Lasna).
        require(reactive.code.length > 0, "REACTIVE has no code on this chain");

        vm.startBroadcast(deployerKey);
        PiggyGuardReactive(payable(reactive)).setCallback(callbackAddr);
        vm.stopBroadcast();

        console.log("PiggyGuardReactive (Lasna):", reactive);
        console.log("reactive.callback =", callbackAddr);
    }
}
