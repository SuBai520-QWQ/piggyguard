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
    event StopLossSkipped(string reason, uint256 actionId, uint256 price);
    event TakeProfitSkipped(string reason, uint256 actionId, uint256 price);
    event DcaSkipped(string reason, uint256 actionId, uint256 safeBalance);

    function setUp() public {
        feed = new MockPriceFeed(100_00000000); // $100.00
        vault = new PiggyVault(address(feed), 10_00000000); // DCA $10 / tick
        vault.setExecutor(executor);
        vault.fundRisk(2_00000000); // 2 risk units
        vault.fundSafe(100_00000000); // $100 safe
    }

    function testStopLossSellsEverything() public {
        // fix-04: execution happens at the feed's current price. The
        // reactive contract saw $85 (trigger) with a $90 line; by the time
        // the callback lands the feed is at $80, and the sale is at $80.
        feed.pushPrice(80_00000000);
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        // 2 units * $80 = $160 safe, plus the $100 already there.
        assertEq(vault.safeBalance(), 260_00000000);
    }

    function testTakeProfitSellsHalf() public {
        // Trigger $115, line $120; the feed is at $120 when the callback
        // lands, so half the position sells at $120.
        feed.pushPrice(120_00000000);
        vm.prank(executor);
        vault.executeTakeProfit(115_00000000, 120_00000000, 1);
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
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
    }

    // ---- fix-03 (Perch P16): pause skips, never reverts ----

    function testPausedExecutionSkipsWithoutReverting() public {
        feed.pushPrice(80_00000000); // stop-loss condition holds at the feed
        vault.pause();
        vm.expectEmit(false, false, false, true, address(vault));
        emit StopLossSkipped("vault paused", 1, 85_00000000);
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1); // skip, no revert, no sale
        assertEq(vault.riskBalance(), 2_00000000);
        assertEq(vault.safeBalance(), 100_00000000);
        // The skip did not consume the id: after unpausing, the same
        // delivery can still execute.
        assertEq(vault.lastStopLossId(), 0);
        vault.unpause();
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
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

    // ---- fix-04 (Perch round-3 C1/C2): execution price is the feed's ------
    // The fix-03 deviation guard ("skip when the trigger price is >20% from
    // the feed") is GONE: it made the stop-loss silently fail exactly when
    // the market moved most, and it let stale trigger prices trade when
    // they stayed within 20%. The tests below pin the replacement
    // semantics: trade at latestPrice(), re-check the condition there.

    /// @notice C1 scenario: stop-loss line $90, trigger seen at $85, and the
    ///         feed crashes further to $60 before the callback lands. The
    ///         old guard skipped (deviation 41.7%) and the latched reactive
    ///         contract never retried — the position rode the crash. Now
    ///         the stop-loss executes, at $60.
    function testStopLossExecutesAtFeedPriceAfterFurtherCrash() public {
        feed.pushPrice(60_00000000); // feed crashed past the trigger price
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
        assertEq(vault.riskBalance(), 0); // position closed
        // Sold at the CURRENT price $60, not the stale trigger $85:
        // 2 * $60 = $120 proceeds, plus the $100 already there.
        assertEq(vault.safeBalance(), 220_00000000);
        assertEq(vault.lastStopLossId(), 1);
    }

    /// @notice C2 scenario: trigger seen at $85, but the price recovers to
    ///         $95 (back above the $90 line) before the callback lands. The
    ///         old code sold everything at $85 into a $95 market. Now the
    ///         condition re-check skips the action and keeps the position.
    function testStopLossSkippedWhenPriceRecoversAboveLine() public {
        feed.pushPrice(95_00000000); // recovered above the stop-loss line
        vm.expectEmit(false, false, false, true, address(vault));
        emit StopLossSkipped("stop-loss condition no longer holds", 1, 85_00000000);
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
        assertEq(vault.riskBalance(), 2_00000000); // position untouched
        assertEq(vault.safeBalance(), 100_00000000);
        assertEq(vault.lastStopLossId(), 0); // skip consumed nothing
    }

    /// @notice C2 mirror on the take-profit side: trigger seen at $130, the
    ///         price falls back to $115 (below the $120 line) in flight.
    function testTakeProfitSkippedWhenPriceFallsBackBelowLine() public {
        feed.pushPrice(115_00000000);
        vm.expectEmit(false, false, false, true, address(vault));
        emit TakeProfitSkipped("take-profit condition no longer holds", 1, 130_00000000);
        vm.prank(executor);
        vault.executeTakeProfit(130_00000000, 120_00000000, 1);
        assertEq(vault.riskBalance(), 2_00000000);
        assertEq(vault.safeBalance(), 100_00000000);
        assertEq(vault.lastTakeProfitId(), 0);
    }

    /// @notice The payload's trigger price never sets the trade price: even
    ///         a nonsense trigger value executes at the feed price when
    ///         the condition holds there.
    function testStopLossIgnoresTriggerPriceForExecution() public {
        // Feed still at $100 from setUp; line $110 -> condition holds.
        vm.prank(executor);
        vault.executeStopLoss(1, 110_00000000, 1); // trigger price: $0.00000001
        assertEq(vault.riskBalance(), 0);
        // Sold at the feed's $100, not at the payload's price:
        assertEq(vault.safeBalance(), 300_00000000); // $100 + 2 * $100
    }

    function testTakeProfitIgnoresTriggerPriceForExecution() public {
        feed.pushPrice(150_00000000); // feed well above the $120 line
        vm.prank(executor);
        vault.executeTakeProfit(999_00000000, 120_00000000, 1); // absurd trigger
        assertEq(vault.riskBalance(), 1_00000000); // sold half
        // Proceeds at the feed's $150, not the payload's $999:
        assertEq(vault.safeBalance(), 250_00000000); // $100 + 1 * $150
    }

    // ---- M3 as fixed by fix-03 (PG-N1/P1): per-type replay watermarks ----

    function testReplaySameActionIdIsIgnored() public {
        feed.pushPrice(80_00000000);
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
        assertEq(vault.riskBalance(), 0);
        assertEq(vault.safeBalance(), 260_00000000);
        assertEq(vault.lastStopLossId(), 1);

        // The exact same callback is delivered again: no second sale.
        vm.expectEmit(false, false, false, true, address(vault));
        emit ActionIgnored(1, 1);
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1);
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
        feed.pushPrice(110_00000000); // take-profit condition holds at feed
        vm.prank(executor);
        vault.executeTakeProfit(115_00000000, 110_00000000, 2); // later action lands first
        assertEq(vault.riskBalance(), 1_00000000); // sold half
        assertEq(vault.lastTakeProfitId(), 2);

        feed.pushPrice(85_00000000); // stop-loss condition holds at feed
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 1); // earlier stop-loss still works
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
        // Feed is at $100; the $100 line makes the condition hold there.
        broke.executeStopLoss(85_00000000, 100_00000000, 4); // in-flight stop-loss survives
        assertEq(broke.riskBalance(), 0);
        assertEq(broke.lastStopLossId(), 4);
    }

    // ---- fix-03 (Perch P4): a new executor restarts the id space ----

    function testSetExecutorResetsWatermarks() public {
        feed.pushPrice(80_00000000);
        vm.prank(executor);
        vault.executeStopLoss(85_00000000, 90_00000000, 7);
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

    /// @notice fix-04 (Perch round-3 H4): re-setting the SAME executor must
    ///         not reset anything — otherwise every executed id becomes
    ///         valid again and a re-delivered take-profit sells twice.
    function testSetExecutorSameAddressKeepsState() public {
        vm.prank(executor);
        vault.executeDCA(3); // executes at $100: watermark + DCA reference set
        assertEq(vault.lastDcaId(), 3);
        assertEq(vault.dcaReferencePrice(), 100_00000000);

        vault.setExecutor(executor); // same address: a pure no-op
        assertEq(vault.executor(), executor);
        assertEq(vault.lastDcaId(), 3); // watermark NOT reset
        assertEq(vault.dcaReferencePrice(), 100_00000000); // reference kept

        // And a genuine change of executor clears the DCA breaker state too.
        vault.setExecutor(address(0xBEEF2));
        assertEq(vault.lastDcaId(), 0);
        assertEq(vault.dcaReferencePrice(), 0);
        assertEq(vault.dcaCandidatePrice(), 0);
        assertEq(vault.dcaCandidateCount(), 0);
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
        emit StopLossSkipped("no risk balance", 1, 85_00000000);
        vm.prank(executor);
        // Feed at $100, line $100: the condition holds, but there is
        // nothing to sell.
        empty.executeStopLoss(85_00000000, 100_00000000, 1);
        assertEq(empty.riskBalance(), 0);
        assertEq(empty.safeBalance(), 100_00000000); // nothing "sold for free"
        // fix-03: the skip no longer consumes the id, so once a position
        // exists the same delivery can still execute.
        assertEq(empty.lastStopLossId(), 0);
        empty.fundRisk(1_00000000);
        vm.prank(executor);
        empty.executeStopLoss(85_00000000, 100_00000000, 1);
        assertEq(empty.riskBalance(), 0);
        assertEq(empty.safeBalance(), 200_00000000); // sold 1 unit at feed $100
        assertEq(empty.lastStopLossId(), 1);
    }

    /// @notice fix-03 (Perch P18): dust no longer locks — a take-profit on a
    ///         position whose 50% rounds to zero sells the remainder.
    function testTakeProfitOnDustPositionSellsRemainder() public {
        PiggyVault dust = new PiggyVault(address(feed), 10_00000000);
        dust.setExecutor(executor);
        dust.fundRisk(1); // 1 wei: 50% rounds down to a zero sale

        vm.prank(executor);
        // Feed at $100 (shared feed from setUp), line $100: sells the
        // remainder at the feed price.
        dust.executeTakeProfit(120_00000000, 100_00000000, 1);
        assertEq(dust.riskBalance(), 0); // remainder sold, nothing locked
        assertEq(dust.safeBalance(), 100); // 1 unit * $100 / 1e8 scale
        assertEq(dust.lastTakeProfitId(), 1);
    }

    /// @notice fix-04 (Perch round-3 M6): a take-profit whose proceeds
    ///         round to zero must skip instead of clearing the position
    ///         for no income.
    function testTakeProfitSkipsWhenProceedsWouldBeZero() public {
        MockPriceFeed cheapFeed = new MockPriceFeed(50_000000); // $0.50
        PiggyVault cheap = new PiggyVault(address(cheapFeed), 10_00000000);
        cheap.setExecutor(executor);
        cheap.fundRisk(1); // dust: the remainder sale is 1 wei

        vm.expectEmit(false, false, false, true, address(cheap));
        emit TakeProfitSkipped("proceeds would be zero", 1, 60_000000);
        vm.prank(executor);
        // 1 wei * $0.50 / 1e8 scale == 0 proceeds -> skip, keep the dust.
        cheap.executeTakeProfit(60_000000, 50_000000, 1);
        assertEq(cheap.riskBalance(), 1); // position NOT cleared
        assertEq(cheap.safeBalance(), 0);
        assertEq(cheap.lastTakeProfitId(), 0); // id not consumed

        // Once the price is real, the same delivery executes normally.
        cheapFeed.pushPrice(200_00000000); // $200
        vm.prank(executor);
        cheap.executeTakeProfit(60_000000, 50_000000, 1);
        assertEq(cheap.riskBalance(), 0);
        assertEq(cheap.safeBalance(), 200); // 1 wei * $200 / 1e8 scale
        assertEq(cheap.lastTakeProfitId(), 1);
    }

    // ---- fix-04 (Perch round-3 L1): zero fund / withdraw reverts ----

    function testFundRiskRejectsZero() public {
        vm.expectRevert(PiggyVault.ZeroAmount.selector);
        vault.fundRisk(0);
        assertEq(vault.riskBalance(), 2_00000000); // unchanged
    }

    function testWithdrawRiskRejectsZero() public {
        vm.expectRevert(PiggyVault.ZeroAmount.selector);
        vault.withdrawRisk(0);
        assertEq(vault.riskBalance(), 2_00000000); // unchanged
    }

    function testDcaAtExtremePriceSkipsWithoutCharging() public {
        // $20 billion per unit: $10 buys 0 units after integer division.
        MockPriceFeed moonFeed = new MockPriceFeed(20_000_000_000_00000000);
        PiggyVault moonVault = new PiggyVault(address(moonFeed), 10_00000000);
        moonVault.setExecutor(executor);
        moonVault.fundSafe(100_00000000);

        vm.expectEmit(false, false, false, true, address(moonVault));
        emit DcaSkipped("price too high: buys zero", 1, 100_00000000);
        vm.prank(executor);
        moonVault.executeDCA(1); // must not revert, must not charge
        assertEq(moonVault.safeBalance(), 100_00000000); // full amount kept
        assertEq(moonVault.riskBalance(), 0);
    }

    // ---- fix-04 (Perch round-3 H3): DCA breaker needs 3 confirming ticks --
    // The fix-03 breaker re-baselined after ONE skipped tick, so it only
    // ever delayed a blind buy by one tick. Now a far-away price opens a
    // candidate level and DCA_CONFIRMATION_TICKS consecutive ticks near
    // the candidate must confirm it before the reference moves.

    function testDcaCircuitBreakerRequiresThreeConfirmingTicks() public {
        vm.prank(executor);
        vault.executeDCA(1); // at $100: executes, reference = $100
        assertEq(vault.riskBalance(), 2_10000000);
        assertEq(vault.dcaReferencePrice(), 100_00000000);

        feed.pushPrice(60_00000000); // price crashes 100 -> 60 (-40%)

        // Tick 1 at the new level: skipped, candidate opens, no re-baseline.
        vm.expectEmit(false, false, false, true, address(vault));
        emit DcaSkipped("price moved too far since last DCA", 2, 90_00000000);
        vm.prank(executor);
        vault.executeDCA(2);
        assertEq(vault.safeBalance(), 90_00000000); // not charged
        assertEq(vault.riskBalance(), 2_10000000);
        assertEq(vault.dcaReferencePrice(), 100_00000000); // NOT re-baselined
        assertEq(vault.dcaCandidatePrice(), 60_00000000);
        assertEq(vault.dcaCandidateCount(), 1);
        assertEq(vault.lastDcaId(), 1); // skip consumed nothing

        // Tick 2 at the new level: still only confirming.
        vm.prank(executor);
        vault.executeDCA(3);
        assertEq(vault.safeBalance(), 90_00000000);
        assertEq(vault.dcaReferencePrice(), 100_00000000);
        assertEq(vault.dcaCandidateCount(), 2);

        // Tick 3 at the new level: confirmation complete — the candidate
        // becomes the reference and THIS tick buys at $60.
        vm.prank(executor);
        vault.executeDCA(4);
        assertEq(vault.dcaReferencePrice(), 60_00000000);
        assertEq(vault.dcaCandidatePrice(), 0);
        assertEq(vault.dcaCandidateCount(), 0);
        assertEq(vault.safeBalance(), 80_00000000); // $10 spent
        // bought = $10 * 1e8 / $60 = 16666666 (0.16666... units)
        assertEq(vault.riskBalance(), 2_10000000 + 16666666);
        assertEq(vault.lastDcaId(), 4);

        // Tick 4: business as usual at the confirmed level.
        vm.prank(executor);
        vault.executeDCA(5);
        assertEq(vault.safeBalance(), 70_00000000);
        assertEq(vault.riskBalance(), 2_10000000 + 2 * 16666666);
    }

    /// @notice A tick back near the reference level clears a pending
    ///         candidate: the confirming ticks must be consecutive.
    function testDcaCandidateClearsWhenPriceReturnsToReference() public {
        vm.prank(executor);
        vault.executeDCA(1); // reference = $100

        feed.pushPrice(60_00000000); // crash: candidate opens
        vm.prank(executor);
        vault.executeDCA(2); // skipped, candidate count 1
        assertEq(vault.dcaCandidateCount(), 1);

        feed.pushPrice(100_00000000); // back at the reference level
        vm.prank(executor);
        vault.executeDCA(3); // trades normally at $100...
        assertEq(vault.safeBalance(), 80_00000000);
        assertEq(vault.dcaCandidatePrice(), 0); // ...and the candidate is gone
        assertEq(vault.dcaCandidateCount(), 0);

        // A later crash starts the confirmation from scratch.
        feed.pushPrice(60_00000000);
        vm.prank(executor);
        vault.executeDCA(4); // skipped again — count restarted at 1
        assertEq(vault.safeBalance(), 80_00000000);
        assertEq(vault.dcaCandidateCount(), 1);
    }

    // ---- M9: fuzz — a take-profit can never sell more than the position ----

    function testFuzz_TakeProfitNeverSellsMoreThanPosition(uint256 amount_) public {
        amount_ = bound(amount_, 0, 1e16);
        PiggyVault fuzzVault = new PiggyVault(address(feed), 10_00000000);
        fuzzVault.setExecutor(executor);
        if (amount_ > 0) fuzzVault.fundRisk(amount_); // fundRisk(0) reverts (L1)

        vm.prank(executor);
        // Feed is at $100; the $100 line makes the condition hold there.
        fuzzVault.executeTakeProfit(100_00000000, 100_00000000, 1);
        uint256 expectedSold = amount_ < 2 ? amount_ : amount_ / 2;
        assertEq(fuzzVault.riskBalance(), amount_ - expectedSold);
        // received = sold * $100.00 / PRICE_SCALE = sold * 100
        assertEq(fuzzVault.safeBalance(), expectedSold * 100);
    }
}
