// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyVault } from "../src/PiggyVault.sol";
import { PiggyGuardCallback } from "../src/PiggyGuardCallback.sol";
import { PiggyGuardReactive } from "../src/PiggyGuardReactive.sol";

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
///         (default $10).
///         After deployment: fund the reactive contract's SYSTEM reserves with
///         `depositTo` (lREACT) and the callback contract's proxy reserves
///         (Base Sepolia ETH) — see README "Reserves" — or the loop silently
///         stops (plan R4).
contract DeployBase is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        uint256 initialPrice = vm.envOr("INITIAL_PRICE", uint256(100_00000000));
        uint256 dcaAmount = vm.envOr("DCA_AMOUNT", uint256(10_00000000));

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

        vm.startBroadcast(deployerKey);
        PiggyGuardReactive guard = new PiggyGuardReactive{ value: 0.1 ether }(
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

        vm.startBroadcast(deployerKey);
        PiggyGuardCallback callback =
            new PiggyGuardCallback(IPayable(payable(proxy)), reactive, vaultAddr);
        PiggyVault(vaultAddr).setExecutor(address(callback));
        vm.stopBroadcast();

        console.log("PiggyGuardCallback (Base Sepolia):", address(callback));
        console.log("vault.executor =", address(callback));
        console.log("NEXT (Lasna): WireUpReactive with CALLBACK=%s", address(callback));
        console.log("NEXT (Base Sepolia): depositTo the callback proxy for", address(callback));
    }
}

contract WireUpReactive is Script {
    /// @notice Lasna only. Backfills the callback address on the reactive
    ///         contract (deploy order: reactive first, callback second).
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address reactive = vm.envAddress("REACTIVE");
        address callbackAddr = vm.envAddress("CALLBACK");

        vm.startBroadcast(deployerKey);
        PiggyGuardReactive(payable(reactive)).setCallback(callbackAddr);
        vm.stopBroadcast();

        console.log("PiggyGuardReactive (Lasna):", reactive);
        console.log("reactive.callback =", callbackAddr);
    }
}
