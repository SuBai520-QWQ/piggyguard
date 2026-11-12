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
///         Run in two steps because the reactive contract lives on Lasna
///         while the other three live on Base Sepolia:
///           Step 1 (Base Sepolia): `forge script script/Deploy.s.sol:DeployBase
///             --rpc-url $BASE_SEPOLIA_RPC --broadcast`
///           Step 2 (Lasna): `forge script script/Deploy.s.sol:DeployReactive
///             --rpc-url $LASNA_RPC --broadcast`
///           Step 3 (Base Sepolia): `forge script script/Deploy.s.sol:WireUp
///             --rpc-url $BASE_SEPOLIA_RPC --broadcast`
///         Required env vars: PRIVATE_KEY, BASE_SEPOLIA_CALLBACK_PROXY
///         (Base Sepolia callback proxy address, from dev.reactive.network),
///         plus the addresses printed by steps 1–2 (PRICE_FEED, VAULT,
///         REACTIVE). Optional: INITIAL_PRICE (default $100), STOP_LOSS
///         (default $90), TAKE_PROFIT (default $120), DCA_AMOUNT (default $10).
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
        console.log("NEXT: deploy reactive on Lasna (DeployReactive), then WireUp.");
        console.log("NOTE: the callback contract is deployed by WireUp, once");
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
        console.log("NEXT: WireUp on Base Sepolia with REACTIVE=%s", address(guard));
    }
}

contract WireUp is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("BASE_SEPOLIA_CALLBACK_PROXY");
        address reactive = vm.envAddress("REACTIVE");
        address vaultAddr = vm.envAddress("VAULT");

        vm.startBroadcast(deployerKey);
        PiggyGuardCallback callback =
            new PiggyGuardCallback(IPayable(payable(proxy)), reactive, vaultAddr);
        PiggyGuardReactive(payable(reactive)).setCallback(address(callback));
        PiggyVault(vaultAddr).setExecutor(address(callback));
        vm.stopBroadcast();

        console.log("PiggyGuardCallback (Base Sepolia):", address(callback));
        console.log("Wired: reactive.callback = callback; vault.executor = callback");
        console.log("NEXT: depositTo reserves (reactive lREACT + callback proxy ETH).");
    }
}
