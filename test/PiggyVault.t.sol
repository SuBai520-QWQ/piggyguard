// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyVault } from "../src/PiggyVault.sol";

contract PiggyVaultTest is Test {
    MockPriceFeed feed;
    PiggyVault vault;

    address executor = address(0xCA11BAC);

    event ActionIgnored(uint256 actionId, uint256 lastActionId);
    event StopLossSkipped(string reason, uint256 price);
    event TakeProfitSkipped(string reason, uint256 price);
    event DcaSkipped(string reason, uint256 safeBalance);

    function setUp() public {
        feed = new MockPriceFeed(100_00000000); // $100.00
        vault = new PiggyVault(address(feed), 10_00000000); // DCA $10 / tick
        vault.setExecutor(executor);
        vault.fundRisk(2_00000000); // 2 risk units
        vault.fundSafe(100_00000000); // $100 safe
    }

    function testStopLossSellsEverything() public {
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1); // $80
        assertEq(vault.riskBalance(), 0);
        // 2 units * $80 = $160 safe, plus the $100 already there.
        assertEq(vault.safeBalance(), 260_00000000);
    }

    function testTakeProfitSellsHalf() public {
        vm.prank(executor);
        vault.executeTakeProfit(120_00000000, 1); // $120
        assertEq(vault.riskBalance(), 1_00000000);
        // sold 1 unit * $120 = $120 safe, plus $100.
        assertEq(vault.safeBalance(), 220_00000000);
    }

    function testDcaBuysAtFeedPrice() public {
        vm.prank(executor);
        vault.executeDCA(1);
        // $10 at $100 buys 0.1 risk units; safe drops by $10.
        assertEq(vault.safeBalance(), 90_00000000);
        assertEq(vault.riskBalance(), 2_10000000);
    }

    function testDcaSkipsWhenSafeBalanceTooLow() public {
        vault.withdrawSafe(95_00000000); // leave $5 < $10 DCA amount
        vm.prank(executor);
        vault.executeDCA(1); // must not revert
        assertEq(vault.safeBalance(), 5_00000000);
        assertEq(vault.riskBalance(), 2_00000000);
    }

    function testOnlyExecutorCanExecute() public {
        vm.expectRevert(abi.encodeWithSelector(PiggyVault.NotExecutor.selector, address(this)));
        vault.executeStopLoss(80_00000000, 1);
    }

    function testPauseBlocksExecution() public {
        vault.pause();
        vm.prank(executor);
        vm.expectRevert(PiggyVault.PausedVault.selector);
        vault.executeStopLoss(80_00000000, 1);
        vault.unpause();
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1);
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

    // ---- H8: zero price ----

    function testDcaRevertsAtZeroPrice() public {
        // The feed's constructor still accepts 0 (pushPrice rejects it), so the
        // vault keeps its own guard against a divide-by-zero.
        MockPriceFeed zeroFeed = new MockPriceFeed(0);
        PiggyVault zeroVault = new PiggyVault(address(zeroFeed), 10_00000000);
        zeroVault.setExecutor(executor);
        zeroVault.fundSafe(100_00000000);

        vm.prank(executor);
        vm.expectRevert(PiggyVault.ZeroPrice.selector);
        zeroVault.executeDCA(1);
    }

    // ---- M3: replay / out-of-order protection ----

    function testReplaySameActionIdIsIgnored() public {
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000);
        assertEq(vault.lastActionId(), 1);

        // The exact same callback is delivered again: no second sale.
        vm.expectEmit(false, false, false, true, address(vault));
        emit ActionIgnored(1, 1);
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000);
        assertEq(vault.lastActionId(), 1);
    }

    function testOutOfOrderActionIdIsIgnored() public {
        vm.prank(executor);
        vault.executeDCA(2); // newest action executes
        assertEq(vault.safeBalance(), 90_00000000);
        uint256 riskAfterFirst = vault.riskBalance();
        assertEq(vault.lastActionId(), 2);

        // An older action arrives late: ignored, no second buy.
        vm.expectEmit(false, false, false, true, address(vault));
        emit ActionIgnored(1, 2);
        vm.prank(executor);
        vault.executeDCA(1);
        assertEq(vault.safeBalance(), 90_00000000);
        assertEq(vault.riskBalance(), riskAfterFirst);
        assertEq(vault.lastActionId(), 2);
    }

    // ---- M6: zero-address / zero-amount validation ----

    function testConstructorRejectsZeroFeed() public {
        vm.expectRevert(PiggyVault.ZeroAddress.selector);
        new PiggyVault(address(0), 10_00000000);
    }

    function testConstructorRejectsZeroDcaAmount() public {
        vm.expectRevert(PiggyVault.ZeroAmount.selector);
        new PiggyVault(address(feed), 0);
    }

    function testSetExecutorRejectsZeroAddress() public {
        vm.expectRevert(PiggyVault.ZeroAddress.selector);
        vault.setExecutor(address(0));
        assertEq(vault.executor(), executor); // unchanged
    }

    function testSetDcaAmountRejectsZero() public {
        vm.expectRevert(PiggyVault.ZeroAmount.selector);
        vault.setDcaAmount(0);
        assertEq(vault.dcaAmount(), 10_00000000); // unchanged
    }

    // ---- M11: zero-trade executions skip instead of emitting success ----

    function testStopLossOnEmptyPositionSkips() public {
        PiggyVault empty = new PiggyVault(address(feed), 10_00000000);
        empty.setExecutor(executor);
        empty.fundSafe(100_00000000); // safe only, no risk position

        vm.expectEmit(false, false, false, true, address(empty));
        emit StopLossSkipped("no risk balance", 80_00000000);
        vm.prank(executor);
        empty.executeStopLoss(80_00000000, 1);
        assertEq(empty.riskBalance(), 0);
        assertEq(empty.safeBalance(), 100_00000000); // nothing "sold for free"
        assertEq(empty.lastActionId(), 1); // the action is still consumed
    }

    function testTakeProfitOnDustPositionSkips() public {
        PiggyVault dust = new PiggyVault(address(feed), 10_00000000);
        dust.setExecutor(executor);
        dust.fundRisk(1); // 1 wei: 50% rounds down to a zero sale

        vm.expectEmit(false, false, false, true, address(dust));
        emit TakeProfitSkipped("position too small to sell 50%", 120_00000000);
        vm.prank(executor);
        dust.executeTakeProfit(120_00000000, 1);
        assertEq(dust.riskBalance(), 1); // untouched
        assertEq(dust.safeBalance(), 0);
    }

    function testDcaAtExtremePriceSkipsWithoutCharging() public {
        // $20 billion per unit: $10 buys 0 units after integer division.
        MockPriceFeed moonFeed = new MockPriceFeed(20_000_000_000_00000000);
        PiggyVault moonVault = new PiggyVault(address(moonFeed), 10_00000000);
        moonVault.setExecutor(executor);
        moonVault.fundSafe(100_00000000);

        vm.expectEmit(false, false, false, true, address(moonVault));
        emit DcaSkipped("price too high: buys zero", 100_00000000);
        vm.prank(executor);
        moonVault.executeDCA(1); // must not revert, must not charge
        assertEq(moonVault.safeBalance(), 100_00000000); // full amount kept
        assertEq(moonVault.riskBalance(), 0);
    }
}
