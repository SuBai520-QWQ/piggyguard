// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyVault } from "../src/PiggyVault.sol";
import { PiggyGuardCallback } from "../src/PiggyGuardCallback.sol";

/// @notice Tests for the trust boundary of the loop: only the callback proxy
///         may call in, the injected sender must be our reactive contract, and
///         each of the three actions really moves the vault's state.
contract PiggyGuardCallbackTest is Test {
    address constant PROXY = address(0xB0B);
    address constant REACTIVE = address(0xA11CE);
    address constant STRANGER = address(0xBAD);

    MockPriceFeed feed;
    PiggyVault vault;
    PiggyGuardCallback callback;

    function setUp() public {
        feed = new MockPriceFeed(100_00000000); // $100.00
        vault = new PiggyVault(address(feed), 10_00000000); // DCA $10 / tick
        callback = new PiggyGuardCallback(IPayable(payable(PROXY)), REACTIVE, address(vault));
        vault.setExecutor(address(callback));
        vault.fundRisk(2_00000000); // 2 risk units
        vault.fundSafe(100_00000000); // $100 safe
    }

    // ---- authentication ----

    function testNonProxyCallReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY)
        );
        callback.executeStopLoss(REACTIVE, 80_00000000, 1);
    }

    function testWrongReactiveSenderRevertsForAllActions() public {
        bytes memory expected = abi.encodeWithSelector(
            AbstractCallback.CallbackNotAuthorized.selector, STRANGER, REACTIVE
        );

        vm.expectRevert(expected);
        vm.prank(PROXY);
        callback.executeStopLoss(STRANGER, 80_00000000, 1);

        vm.expectRevert(expected);
        vm.prank(PROXY);
        callback.executeTakeProfit(STRANGER, 120_00000000, 1);

        vm.expectRevert(expected);
        vm.prank(PROXY);
        callback.executeDCA(STRANGER, 1);
    }

    // ---- forwarding: each action really changes vault state ----

    function testStopLossForwardsToVault() public {
        vm.prank(PROXY);
        callback.executeStopLoss(REACTIVE, 80_00000000, 1);

        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000); // 2 * $80 + $100
        assertEq(vault.lastActionId(), 1);
    }

    function testTakeProfitForwardsToVault() public {
        vm.prank(PROXY);
        callback.executeTakeProfit(REACTIVE, 120_00000000, 1);

        assertEq(vault.riskBalance(), 1_00000000); // sold 50%
        assertEq(vault.safeBalance(), 220_00000000); // 1 * $120 + $100
        assertEq(vault.lastActionId(), 1);
    }

    function testDcaForwardsToVault() public {
        vm.prank(PROXY);
        callback.executeDCA(REACTIVE, 1);

        assertEq(vault.safeBalance(), 90_00000000); // spent $10
        assertEq(vault.riskBalance(), 2_10000000); // bought 0.1 at $100
        assertEq(vault.lastActionId(), 1);
    }

    // ---- M3 at the integration boundary ----

    function testReplayedCallbackIsIgnoredByVault() public {
        vm.prank(PROXY);
        callback.executeStopLoss(REACTIVE, 80_00000000, 1);
        assertEq(vault.safeBalance(), 260_00000000);

        // Same payload delivered twice: the vault must not sell again.
        vm.prank(PROXY);
        callback.executeStopLoss(REACTIVE, 80_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000);
        assertEq(vault.lastActionId(), 1);
    }
}
