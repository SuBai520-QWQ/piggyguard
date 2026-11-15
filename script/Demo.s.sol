// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyVault } from "../src/PiggyVault.sol";

/// @title PiggyGuard demo seed (Base Sepolia).
/// @notice Funds a freshly wired vault with the README's typical parameters and
///         pushes one price. A push below the stop-loss ($85 vs $90) emits the
///         PriceUpdated event that starts the reactive loop:
///         Base Sepolia origin tx -> Lasna react() -> Base Sepolia callback.
///         Run after DeployBase, DeployReactive, WireUpBase and WireUpReactive:
///           forge script script/Demo.s.sol:Demo \
///             --rpc-url $BASE_SEPOLIA_RPC --broadcast
///         Required env vars: PRIVATE_KEY, VAULT, PRICE_FEED, CALLBACK.
///         Optional: DEMO_RISK (default 2 units), DEMO_SAFE (default $100),
///         DEMO_PRICE (default $85).
/// @dev Forge prints the broadcast table (one tx hash per call) directly above
///      this script's console output; the addresses and amounts below let the
///      operator match each hash to its step.
contract Demo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");
        address feedAddr = vm.envAddress("PRICE_FEED");
        address expectedCallback = vm.envAddress("CALLBACK");
        uint256 riskAmount = vm.envOr("DEMO_RISK", uint256(2_00000000));
        uint256 safeAmount = vm.envOr("DEMO_SAFE", uint256(100_00000000));
        uint256 demoPrice = vm.envOr("DEMO_PRICE", uint256(85_00000000));

        PiggyVault vault = PiggyVault(vaultAddr);
        MockPriceFeed feed = MockPriceFeed(feedAddr);

        address deployer = vm.addr(deployerKey);

        // Wiring checks before any state change: funding a vault whose
        // executor is not the callback we expect, or whose owner is not this
        // key, produces a demo that looks seeded but can never be driven —
        // and the failure surfaces minutes later on Lasna, not here.
        require(
            vault.executor() == expectedCallback,
            "vault.executor() != CALLBACK: run WireUpBase first"
        );
        require(vault.owner() == deployer, "vault.owner() != the PRIVATE_KEY deployer");
        require(feed.owner() == deployer, "feed.owner() != the PRIVATE_KEY deployer");
        // 8-decimal fixed point, not dollars: a bare `85` would mean
        // $0.00000085 and would never cross the stop-loss line.
        require(
            demoPrice >= 1e8,
            "DEMO_PRICE must be >= 1e8 (8-decimal fixed point: 1e8 == $1.00)"
        );

        console.log("== PiggyGuard demo seed (Base Sepolia) ==");
        console.log("MockPriceFeed:", feedAddr);
        console.log("PiggyVault:", vaultAddr);
        console.log("deployer (must own vault + feed):", deployer);
        console.log("vault.executor (must be the callback):", vault.executor());
        console.log("tx 1: vault.fundRisk(amount)", riskAmount);
        console.log("tx 2: vault.fundSafe(amount)", safeAmount);
        console.log("tx 3: feed.pushPrice(price)", demoPrice);

        vm.startBroadcast(deployerKey);
        vault.fundRisk(riskAmount);
        vault.fundSafe(safeAmount);
        feed.pushPrice(demoPrice);
        vm.stopBroadcast();

        console.log("== after ==");
        console.log("riskBalance:", vault.riskBalance());
        console.log("safeBalance:", vault.safeBalance());
        console.log("feed.latestPrice:", feed.latestPrice());
        console.log("NEXT: Reactscan (Lasna) shows react(); BaseScan shows the callback tx.");
    }
}
