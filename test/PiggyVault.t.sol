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
        vault.executeStopLoss(80_00000000, 1); // $80 (exactly -20% vs feed: allowed)
        assertEq(vault.riskBalance(), 0);
        // 2 units * $80 = $160 safe, plus the $100 already there.
        assertEq(vault.safeBalance(), 260_00000000);
    }

    function testTakeProfitSellsHalf() public {
        vm.prank(executor);
        vault.executeTakeProfit(120_00000000, 1); // $120 (exactly +20% vs feed: allowed)
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

    // ---- fix-03 (Perch P16): pause skips, never reverts ----

    function testPausedExecutionSkipsWithoutReverting() public {
        vault.pause();
        vm.expectEmit(false, false, false, true, address(vault));
        emit StopLossSkipped("vault paused", 80_00000000);
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1); // skip, no revert, no sale
        assertEq(vault.riskBalance(), 2_00000000);
        assertEq(vault.safeBalance(), 100_00000000);
        // The skip did not consume the id: after unpausing, the same
        // delivery can still execute.
        assertEq(vault.lastStopLossId(), 0);
        vault.unpause();
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.lastStopLossId(), 1);
    }

    function testWithdrawMoreThanBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PiggyVault.InsufficientBalance.selector, 300_00000000, 100_00000000
            )
        );
        vault.withdrawSafe(300_00000000);
    }

    // ---- fix-03 (Perch P2 / PG-N2): zero trigger price skips, never trades ----

    function testZeroPriceStopLossSkips() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit StopLossSkipped("zero price", 0);
        vm.prank(executor);
        vault.executeStopLoss(0, 1);
        assertEq(vault.riskBalance(), 2_00000000); // position NOT wiped
        assertEq(vault.safeBalance(), 100_00000000);
        assertEq(vault.lastStopLossId(), 0); // not consumed
    }

    function testZeroPriceTakeProfitSkips() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit TakeProfitSkipped("zero price", 0);
        vm.prank(executor);
        vault.executeTakeProfit(0, 1);
        assertEq(vault.riskBalance(), 2_00000000);
        assertEq(vault.safeBalance(), 100_00000000);
        assertEq(vault.lastTakeProfitId(), 0);
    }

    // ---- fix-03 (Perch P5/P17): trigger price must stay near the feed ----

    function testStopLossPriceDeviationSkips() public {
        // Feed says $100; a $50 trigger price is 50% away — too far to trust.
        vm.expectEmit(false, false, false, true, address(vault));
        emit StopLossSkipped("price deviates from feed", 50_00000000);
        vm.prank(executor);
        vault.executeStopLoss(50_00000000, 1);
        assertEq(vault.riskBalance(), 2_00000000);
        assertEq(vault.lastStopLossId(), 0);
    }

    function testTakeProfitPriceDeviationSkips() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit TakeProfitSkipped("price deviates from feed", 200_00000000);
        vm.prank(executor);
        vault.executeTakeProfit(200_00000000, 1); // +100% vs feed
        assertEq(vault.riskBalance(), 2_00000000);
        assertEq(vault.lastTakeProfitId(), 0);
    }

    // ---- M3 as fixed by fix-03 (PG-N1/P1): per-type replay watermarks ----

    function testReplaySameActionIdIsIgnored() public {
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000);
        assertEq(vault.lastStopLossId(), 1);

        // The exact same callback is delivered again: no second sale.
        vm.expectEmit(false, false, false, true, address(vault));
        emit ActionIgnored(1, 1);
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000);
        assertEq(vault.lastStopLossId(), 1);
    }

    function testOutOfOrderSameTypeActionIdIsIgnored() public {
        vm.prank(executor);
        vault.executeDCA(2); // newest DCA executes
        assertEq(vault.safeBalance(), 90_00000000);
        uint256 riskAfterFirst = vault.riskBalance();
        assertEq(vault.lastDcaId(), 2);

        // An older DCA arrives late: ignored, no second buy.
        vm.expectEmit(false, false, false, true, address(vault));
        emit ActionIgnored(1, 2);
        vm.prank(executor);
        vault.executeDCA(1);
        assertEq(vault.safeBalance(), 90_00000000);
        assertEq(vault.riskBalance(), riskAfterFirst);
        assertEq(vault.lastDcaId(), 2);
    }

    /// @notice PG-N1 regression: under the old single watermark, the
    ///         take-profit landing first permanently swallowed this stop-loss.
    function testOutOfOrderAcrossTypesBothExecute() public {
        vm.prank(executor);
        vault.executeTakeProfit(110_00000000, 2); // later action lands first
        assertEq(vault.riskBalance(), 1_00000000); // sold half
        assertEq(vault.lastTakeProfitId(), 2);

        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 1); // earlier stop-loss still works
        assertEq(vault.riskBalance(), 0);
        // $100 + 1 * $110 (take-profit) + 1 * $85 (stop-loss) = $295.
        assertEq(vault.safeBalance(), 295_00000000);
        assertEq(vault.lastStopLossId(), 1);
    }

    /// @notice PG-N1 regression, second half: a skipped no-op action must not
    ///         burn an id that an in-flight action of another type needs.
    function testSkippedDcaDoesNotBurnIdOrBlockStopLoss() public {
        PiggyVault broke = new PiggyVault(address(feed), 10_00000000);
        broke.setExecutor(executor);
        broke.fundRisk(2_00000000); // position, but no safe balance

        vm.prank(executor);
        broke.executeDCA(5); // skips: insufficient safe balance
        assertEq(broke.lastDcaId(), 0); // skip consumed nothing

        broke.fundSafe(100_00000000);
        vm.prank(executor);
        broke.executeStopLoss(85_00000000, 4); // in-flight stop-loss survives
        assertEq(broke.riskBalance(), 0);
        assertEq(broke.lastStopLossId(), 4);
    }

    // ---- fix-03 (Perch P4): a new executor restarts the id space ----

    function testSetExecutorResetsWatermarks() public {
        vm.prank(executor);
        vault.executeStopLoss(80_00000000, 7);
        assertEq(vault.lastStopLossId(), 7);

        address newExecutor = address(0xBEEF2);
        vault.setExecutor(newExecutor);
        assertEq(vault.lastStopLossId(), 0);
        assertEq(vault.lastTakeProfitId(), 0);
        assertEq(vault.lastDcaId(), 0);

        // The redeployed pair numbers from 1 again — and it works.
        vm.prank(newExecutor);
        vault.executeDCA(1);
        assertEq(vault.lastDcaId(), 1);
        assertEq(vault.safeBalance(), 250_00000000); // 260 - 10 DCA spend
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
        // fix-03: the skip no longer consumes the id, so once a position
        // exists the same delivery can still execute.
        assertEq(empty.lastStopLossId(), 0);
        empty.fundRisk(1_00000000);
        vm.prank(executor);
        empty.executeStopLoss(80_00000000, 1);
        assertEq(empty.riskBalance(), 0);
        assertEq(empty.safeBalance(), 180_00000000);
        assertEq(empty.lastStopLossId(), 1);
    }

    /// @notice fix-03 (Perch P18): dust no longer locks — a take-profit on a
    ///         position whose 50% rounds to zero sells the remainder.
    function testTakeProfitOnDustPositionSellsRemainder() public {
        PiggyVault dust = new PiggyVault(address(feed), 10_00000000);
        dust.setExecutor(executor);
        dust.fundRisk(1); // 1 wei: 50% rounds down to a zero sale

        vm.prank(executor);
        dust.executeTakeProfit(120_00000000, 1);
        assertEq(dust.riskBalance(), 0); // remainder sold, nothing locked
        assertEq(dust.safeBalance(), 120); // 1 unit * $120 / 1e8 scale
        assertEq(dust.lastTakeProfitId(), 1);
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

    // ---- fix-03 (PG-N3 mitigation): DCA circuit breaker on price jumps ----

    function testDcaCircuitBreakerSkipsOneTickAfterPriceJump() public {
        vm.prank(executor);
        vault.executeDCA(1); // at $100: executes, reference = $100
        assertEq(vault.riskBalance(), 2_10000000);
        assertEq(vault.dcaReferencePrice(), 100_00000000);

        feed.pushPrice(200_00000000); // price doubles before the next tick
        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaSkipped("price moved too far since last DCA", 90_00000000);
        vm.prank(executor);
        vault.executeDCA(2); // skipped — no blind buy at the new level
        assertEq(vault.safeBalance(), 90_00000000); // not charged
        assertEq(vault.riskBalance(), 2_10000000);
        assertEq(vault.dcaReferencePrice(), 200_00000000); // re-baselined

        vm.prank(executor);
        vault.executeDCA(3); // next tick trades at the new level: $10 -> 0.05
        assertEq(vault.safeBalance(), 80_00000000);
        assertEq(vault.riskBalance(), 2_15000000);
    }

    // ---- M9: fuzz — a take-profit can never sell more than the position ----

    function testFuzz_TakeProfitNeverSellsMoreThanPosition(uint256 amount_) public {
        amount_ = bound(amount_, 0, 1e16);
        PiggyVault fuzzVault = new PiggyVault(address(feed), 10_00000000);
        fuzzVault.setExecutor(executor);
        fuzzVault.fundRisk(amount_);

        vm.prank(executor);
        fuzzVault.executeTakeProfit(100_00000000, 1); // at the feed price
        uint256 expectedSold = amount_ < 2 ? amount_ : amount_ / 2;
        assertEq(fuzzVault.riskBalance(), amount_ - expectedSold);
        // received = sold * $100.00 / PRICE_SCALE = sold * 100
        assertEq(fuzzVault.safeBalance(), expectedSold * 100);
    }
}
