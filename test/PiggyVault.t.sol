// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyVault } from "../src/PiggyVault.sol";

contract PiggyVaultTest is Test {
    MockPriceFeed feed;
    PiggyVault vault;

    address executor = address(0xCA11BAC);

    function setUp() public {
        feed = new MockPriceFeed(100_00000000); // $100.00
        vault = new PiggyVault(address(feed), 10_00000000); // DCA $10 / tick
        vault.setExecutor(executor);
        vault.fundRisk(2_00000000); // 2 risk units
        vault.fundSafe(100_00000000); // $100 safe
    }

    function testStopLossSellsEverything() public {
        vm.prank(executor);
        vault.executeStopLoss(80_00000000); // $80
        assertEq(vault.riskBalance(), 0);
        // 2 units * $80 = $160 safe, plus the $100 already there.
        assertEq(vault.safeBalance(), 260_00000000);
    }

    function testTakeProfitSellsHalf() public {
        vm.prank(executor);
        vault.executeTakeProfit(120_00000000); // $120
        assertEq(vault.riskBalance(), 1_00000000);
        // sold 1 unit * $120 = $120 safe, plus $100.
        assertEq(vault.safeBalance(), 220_00000000);
    }

    function testDcaBuysAtFeedPrice() public {
        vm.prank(executor);
        vault.executeDCA();
        // $10 at $100 buys 0.1 risk units; safe drops by $10.
        assertEq(vault.safeBalance(), 90_00000000);
        assertEq(vault.riskBalance(), 2_10000000);
    }

    function testDcaSkipsWhenSafeBalanceTooLow() public {
        vault.withdrawSafe(95_00000000); // leave $5 < $10 DCA amount
        vm.prank(executor);
        vault.executeDCA(); // must not revert
        assertEq(vault.safeBalance(), 5_00000000);
        assertEq(vault.riskBalance(), 2_00000000);
    }

    function testOnlyExecutorCanExecute() public {
        vm.expectRevert(abi.encodeWithSelector(PiggyVault.NotExecutor.selector, address(this)));
        vault.executeStopLoss(80_00000000);
    }

    function testPauseBlocksExecution() public {
        vault.pause();
        vm.prank(executor);
        vm.expectRevert(PiggyVault.PausedVault.selector);
        vault.executeStopLoss(80_00000000);
        vault.unpause();
        vm.prank(executor);
        vault.executeStopLoss(80_00000000);
        assertEq(vault.riskBalance(), 0);
    }

    function testWithdrawMoreThanBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PiggyVault.InsufficientBalance.selector, 300_00000000, 100_00000000
            )
        );
        vault.withdrawSafe(300_00000000);
    }
}
