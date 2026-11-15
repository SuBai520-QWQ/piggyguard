// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyGuardCallback } from "../src/PiggyGuardCallback.sol";
import { PiggyGuardReactive } from "../src/PiggyGuardReactive.sol";
import { MockSystem } from "./mocks/MockSystem.sol";

/// @notice Unit tests for the reactive decision logic (latches, band re-arm,
///         Cron DCA, silent ignore of foreign logs).
/// @dev The constructor's SYSTEM.subscribe calls target the real SYSTEM address
///      (0x8888...), which has no code on a local test chain — those calls
///      succeed silently. react() is invoked via vm.prank(SYSTEM) so the
///      onlySystem guard passes, and requestCallbackV_1_0 likewise no-ops.
///      ActionRequested events are counted to prove exactly-once firing.
///      MockSystem (etched at SYSTEM) additionally records the two
///      subscriptions and every callback request, so the tests can assert the
///      exact subscription tuple and the callback envelope (chain, recipient,
///      gas limit, selector, price, actionId).
contract PiggyGuardReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant CALLBACK = address(0xCA11BAC);
    address constant CRON_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 constant LASNA_CHAIN_ID = 5318007;
    uint256 constant GAS_LIMIT = 1_000_000;

    uint256 constant PRICE_TOPIC = 0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838;
    /// @notice Cron100 topic — must equal PiggyGuardReactive.CRON100_TOPIC.
    uint256 constant CRON_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    bytes32 constant ACTION_TOPIC = keccak256("ActionRequested(string,uint256,uint256,uint256)");

    MockPriceFeed feed;
    PiggyGuardReactive guard;
    MockSystem system;

    function setUp() public {
        // The guard's constructor calls SYSTEM.subscribe; on a local chain
        // that address has no code and the call reverts, so etch a mock
        // system contract there first (test-only, never deployed on-chain).
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        system = MockSystem(payable(SYSTEM));
        feed = new MockPriceFeed(100_00000000); // $100.00
        guard = new PiggyGuardReactive(
            address(feed),
            90_00000000, // stop-loss $90
            120_00000000, // take-profit $120
            CRON_TOPIC
        );
        guard.setCallback(CALLBACK);
    }

    // ---- helpers ----

    function guardCronTopic() internal view returns (uint256) {
        return guard.CRON100_TOPIC();
    }

    function priceLog(uint256 price_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(feed),
            topic0: PRICE_TOPIC,
            topic1: price_,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function cronLog() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: LASNA_CHAIN_ID,
            contractAddress: guard.CRON_CONTRACT(),
            topic0: guardCronTopic(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function countActions() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ACTION_TOPIC) n++;
        }
        return n;
    }

    /// @dev Strip the 4-byte selector so the ABI arguments can be decoded.
    function payloadArgs(bytes memory payload_) internal pure returns (bytes memory args) {
        args = new bytes(payload_.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload_[i + 4];
        }
    }

    /// @dev H6: the callback must be addressed to Base Sepolia / callback with
    ///      the fixed gas limit and the expected selector.
    function assertCallbackEnvelope(bytes4 selector_) internal view {
        assertEq(system.lastChainId(), BASE_SEPOLIA_CHAIN_ID);
        assertEq(system.lastRecipient(), CALLBACK);
        assertEq(system.lastGasLimit(), GAS_LIMIT);
        assertEq(bytes32(bytes4(system.lastPayload())), bytes32(selector_));
    }

    /// @dev fix-04: the payload now carries the band threshold as its third
    ///      argument (sender, trigger price, threshold, actionId), so the
    ///      vault can re-check the condition at execution time (C1/C2).
    function assertPricePayload(
        bytes4 selector_,
        uint256 expectedPrice_,
        uint256 expectedThreshold_,
        uint256 expectedActionId
    ) internal view {
        assertCallbackEnvelope(selector_);
        (address sender, uint256 price, uint256 threshold, uint256 actionId) =
            abi.decode(payloadArgs(system.lastPayload()), (address, uint256, uint256, uint256));
        assertEq(sender, address(0)); // network-injected placeholder
        assertEq(price, expectedPrice_);
        assertEq(threshold, expectedThreshold_);
        assertEq(actionId, expectedActionId);
    }

    function assertDcaPayload(uint256 expectedActionId) internal view {
        assertCallbackEnvelope(PiggyGuardCallback.executeDCA.selector);
        (address sender, uint256 actionId) =
            abi.decode(payloadArgs(system.lastPayload()), (address, uint256));
        assertEq(sender, address(0));
        assertEq(actionId, expectedActionId);
    }

    // ---- H7: subscription tuple ----

    function testSubscriptionsMatchTheLoop() public view {
        assertEq(system.subscribeCalls(), 2);

        (
            uint256 chainId0,
            address contract0,
            uint256 topic00,
            uint256 topic10,
            uint256 topic20,
            uint256 topic30
        ) = system.subscriptions(0);
        assertEq(chainId0, BASE_SEPOLIA_CHAIN_ID); // Base Sepolia
        assertEq(contract0, address(feed)); // MockPriceFeed
        assertEq(topic00, PRICE_TOPIC); // PriceUpdated(uint256,uint256)
        assertEq(topic10, REACTIVE_IGNORE);
        assertEq(topic20, REACTIVE_IGNORE);
        assertEq(topic30, REACTIVE_IGNORE);

        (
            uint256 chainId1,
            address contract1,
            uint256 topic01,
            uint256 topic11,
            uint256 topic21,
            uint256 topic31
        ) = system.subscriptions(1);
        assertEq(chainId1, LASNA_CHAIN_ID); // Lasna
        assertEq(contract1, CRON_CONTRACT); // 0x0000...fffFfF
        assertEq(topic01, CRON_TOPIC); // Cron100(uint256)
        assertEq(topic11, REACTIVE_IGNORE);
        assertEq(topic21, REACTIVE_IGNORE);
        assertEq(topic31, REACTIVE_IGNORE);
    }

    // ---- original price / latch behaviour (now with payload assertions) ----

    function testStopLossFiresOncePerCrossing() public {
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // below $90 -> fires
        assertEq(system.callbackRequests(), 1);
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 85_00000000, 90_00000000, 1);

        vm.prank(SYSTEM);
        guard.react(priceLog(80_00000000)); // still below -> must NOT fire again
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 1);
        assertTrue(guard.stopLossLatched());
    }

    function testBandReturnRearmsBothCrossings() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000)); // back inside band
        assertFalse(guard.stopLossLatched());
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // fires again after re-arm
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 2);
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 85_00000000, 90_00000000, 2);
    }

    function testTakeProfitFiresAndClearsStopLossLatch() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(130_00000000)); // above $120 -> fires
        assertEq(countActions(), 1);
        assertTrue(guard.takeProfitLatched());
        assertFalse(guard.stopLossLatched());
        assertEq(system.callbackRequests(), 2);
        assertPricePayload(PiggyGuardCallback.executeTakeProfit.selector, 130_00000000, 120_00000000, 2);
    }

    function testInBandPriceDoesNothing() public {
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000));
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 0);
    }

    function testCronTickRequestsDca() public {
        // Build the log BEFORE pranking: cronLog() calls the guard contract,
        // which would consume the prank meant for react().
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 1);
        assertDcaPayload(1);
    }

    function testCronTickSkippedWhenDcaDisabled() public {
        guard.setDcaEnabled(false);
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 0);
    }

    function testForeignLogIsIgnoredSilently() public {
        IReactive.LogRecord memory foreignLog = priceLog(50_00000000);
        foreignLog.contractAddress = address(0xDEAD); // not our feed
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(foreignLog); // must not revert, must not fire
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 0);
    }

    function testNonSystemCannotCallReact() public {
        vm.expectRevert();
        guard.react(priceLog(85_00000000));
    }

    // ---- H2: DCA yields to the exit latches ----

    function testStopLossLatchSuppressesDca() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // stop-loss fires, latch set
        assertTrue(guard.stopLossLatched());

        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log); // Cron tick must not buy back in
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 1); // only the stop-loss request
    }

    function testTakeProfitLatchSuppressesDca() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(130_00000000)); // take-profit fires, latch set
        assertTrue(guard.takeProfitLatched());

        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 1);
    }

    function testDcaResumesAfterBandReturn() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // stop-loss latched
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000)); // back in band -> latch cleared
        assertFalse(guard.stopLossLatched());

        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 2);
        assertDcaPayload(2);
    }

    // ---- M1: threshold changes validate and re-arm ----

    function testSetThresholdsRejectsInvertedBand() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PiggyGuardReactive.InvalidThresholds.selector, 120_00000000, 90_00000000
            )
        );
        guard.setThresholds(120_00000000, 90_00000000);

        vm.expectRevert(
            abi.encodeWithSelector(
                PiggyGuardReactive.InvalidThresholds.selector, 100_00000000, 100_00000000
            )
        );
        guard.setThresholds(100_00000000, 100_00000000);
    }

    function testSetThresholdsClearsLatchesAndAllowsNewCrossing() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // old stop-loss $90 latched
        assertTrue(guard.stopLossLatched());

        guard.setThresholds(80_00000000, 120_00000000); // lower the stop-loss
        assertFalse(guard.stopLossLatched());
        assertFalse(guard.takeProfitLatched());

        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(75_00000000)); // valid new crossing of $80
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 2);
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 75_00000000, 80_00000000, 2);
    }

    // ---- M3: action ids are monotonic across all three actions ----

    function testActionIdsAreMonotonicAcrossActions() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // stop-loss -> id 1
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 85_00000000, 90_00000000, 1);

        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000)); // back in band
        vm.prank(SYSTEM);
        guard.react(priceLog(130_00000000)); // take-profit -> id 2
        assertPricePayload(PiggyGuardCallback.executeTakeProfit.selector, 130_00000000, 120_00000000, 2);

        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000)); // back in band, DCA allowed again
        IReactive.LogRecord memory log = cronLog();
        vm.prank(SYSTEM);
        guard.react(log); // DCA -> id 3
        assertDcaPayload(3);
        assertEq(guard.actionCounter(), 3);
        assertEq(system.callbackRequests(), 3);
    }

    // ---- M6: constructor validation ----

    function testConstructorRejectsZeroCronTopic() public {
        vm.expectRevert(PiggyGuardReactive.ZeroTopic.selector);
        new PiggyGuardReactive(address(feed), 90_00000000, 120_00000000, 0);
    }

    function testConstructorRejectsInvertedThresholds() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PiggyGuardReactive.InvalidThresholds.selector, 120_00000000, 90_00000000
            )
        );
        new PiggyGuardReactive(address(feed), 120_00000000, 90_00000000, CRON_TOPIC);
    }

    // ---- M12: no billed callback requests before the callback is wired ----

    function testNoRequestsBeforeCallbackIsSet() public {
        // Deploy a second guard and deliberately skip setCallback: between the
        // reactive deployment and WireUp, Cron ticks and price crossings must
        // not produce (billed) callback requests to the zero address.
        PiggyGuardReactive unwired =
            new PiggyGuardReactive(address(feed), 90_00000000, 120_00000000, CRON_TOPIC);
        uint256 requestsBefore = system.callbackRequests();

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chainId: LASNA_CHAIN_ID,
            contractAddress: CRON_CONTRACT,
            topic0: CRON_TOPIC,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM);
        unwired.react(log); // Cron tick with callback == address(0)
        assertEq(system.callbackRequests(), requestsBefore);
        assertEq(unwired.actionCounter(), 0);

        vm.prank(SYSTEM);
        unwired.react(priceLog(85_00000000)); // crossing: dropped, no request
        // fix-03 (Perch P11): the latch is NOT set — the crossing stays armed
        // so it can still fire once the callback is wired.
        assertFalse(unwired.stopLossLatched());
        assertEq(system.callbackRequests(), requestsBefore);
        assertEq(unwired.actionCounter(), 0);

        // Wire the callback: the very next delivery of the same crossing fires.
        unwired.setCallback(CALLBACK);
        vm.prank(SYSTEM);
        unwired.react(priceLog(85_00000000));
        assertTrue(unwired.stopLossLatched());
        assertEq(system.callbackRequests(), requestsBefore + 1);
        assertEq(unwired.actionCounter(), 1);
    }

    // ---- fix-03: log validation and zero / boundary prices ----

    function testZeroPriceLogIsIgnored() public {
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(0)); // malformed: must not read as a stop-loss
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 0);
        assertFalse(guard.stopLossLatched());
    }

    function testPriceLogFromWrongChainIsIgnored() public {
        IReactive.LogRecord memory log = priceLog(50_00000000);
        log.chainId = 1; // not Base Sepolia
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 0);
    }

    function testCronLogFromWrongContractIsIgnored() public {
        IReactive.LogRecord memory log = cronLog();
        log.contractAddress = address(0xDEAD); // Cron topic, wrong emitter
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 0);
    }

    function testStopLossTriggersAtExactThreshold() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(90_00000000)); // price == stopLoss: triggers (<=)
        assertTrue(guard.stopLossLatched());
        assertEq(system.callbackRequests(), 1);
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 90_00000000, 90_00000000, 1);
    }

    function testTakeProfitTriggersAtExactThreshold() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(120_00000000)); // price == takeProfit: triggers (>=)
        assertTrue(guard.takeProfitLatched());
        assertEq(system.callbackRequests(), 1);
        assertPricePayload(PiggyGuardCallback.executeTakeProfit.selector, 120_00000000, 120_00000000, 1);
    }

    // ---- fix-03 (Perch P8 / PG-N4): zero stop-loss is not a valid band ----

    function testConstructorRejectsZeroStopLoss() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PiggyGuardReactive.InvalidThresholds.selector, 0, 120_00000000
            )
        );
        new PiggyGuardReactive(address(feed), 0, 120_00000000, CRON_TOPIC);
    }

    function testSetThresholdsRejectsZeroStopLoss() public {
        vm.expectRevert(
            abi.encodeWithSelector(PiggyGuardReactive.InvalidThresholds.selector, 0, 120_00000000)
        );
        guard.setThresholds(0, 120_00000000);
        assertEq(guard.stopLoss(), 90_00000000); // unchanged
    }

    // ---- fix-03 (M5): explicit latch recovery ----

    function testResetLatchesRearmsCrossing() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // fires + latches
        assertTrue(guard.stopLossLatched());
        assertEq(system.callbackRequests(), 1);

        guard.resetLatches();
        assertFalse(guard.stopLossLatched());

        vm.prank(SYSTEM);
        guard.react(priceLog(84_00000000)); // still below band: fires again
        assertEq(system.callbackRequests(), 2);
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 84_00000000, 90_00000000, 2);
    }

    // ---- fix-03 (M2): disabling DCA unsubscribes the Cron ticks ----

    function testSetDcaEnabledUnsubscribesAndResubscribes() public {
        assertEq(system.subscribeCalls(), 2); // constructor: price + cron
        guard.setDcaEnabled(false);
        assertEq(system.unsubscribeCalls(), 1);
        assertEq(system.subscribeCalls(), 2);

        guard.setDcaEnabled(false); // no change: no second unsubscribe
        assertEq(system.unsubscribeCalls(), 1);

        guard.setDcaEnabled(true);
        assertEq(system.subscribeCalls(), 3); // cron re-subscribed
        assertEq(system.unsubscribeCalls(), 1);
    }

    // ---- fix-04 (Perch round-3 M3): a failing unsubscribe must not -------
    // ---- brick the DCA toggle -------------------------------------------

    function testSetDcaEnabledSurvivesUnsubscribeFailure() public {
        system.setFailUnsubscribe(true); // system contract rejects the call
        guard.setDcaEnabled(false); // must NOT revert
        assertFalse(guard.dcaEnabled()); // the flag still flipped
        assertEq(system.unsubscribeCalls(), 0); // the call itself failed

        system.setFailUnsubscribe(false);
        guard.setDcaEnabled(true);
        assertTrue(guard.dcaEnabled());
    }

    // ---- fix-04 (Perch round-3 H1): a failed callback request must -------
    // ---- NOT latch the crossing ------------------------------------------

    /// @notice Round-2 regression: _sendCallback swallowed the failure and
    ///         _requestStopLoss still returned true, so the latch was set
    ///         for a request that never left Lasna and the action was lost
    ///         forever. Now the failure leaves the crossing armed and the
    ///         next price event retries it. Also pins L2: no
    ///         ActionRequested event is emitted for the failed attempt.
    function testCallbackFailureDoesNotLatch() public {
        system.setFailCallbacks(true); // e.g. reactive reserve exhausted
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // crossing seen, request fails
        assertEq(countActions(), 0); // L2: no ActionRequested for a failure
        assertEq(system.callbackRequests(), 0); // nothing was handed out
        assertFalse(guard.stopLossLatched()); // H1: NOT latched

        system.setFailCallbacks(false); // reserve topped up again
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(84_00000000)); // next event retries the crossing
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 1);
        assertTrue(guard.stopLossLatched());
        // The failed attempt burned action id 1; the retry carries id 2.
        assertPricePayload(
            PiggyGuardCallback.executeStopLoss.selector, 84_00000000, 90_00000000, 2
        );
    }

    // ---- fix-04 (Perch round-3 H2): forceCheck drives the judgement ------

    /// @notice After resetLatches() a quiet feed produces no new event, so
    ///         recovery used to stall. forceCheck re-runs the judgement
    ///         with the owner-supplied last known price.
    function testForceCheckRefiresAfterResetLatches() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // fires + latches
        assertTrue(guard.stopLossLatched());
        assertEq(system.callbackRequests(), 1);

        guard.resetLatches();
        assertFalse(guard.stopLossLatched());
        // No new price log arrives. The owner drives the judgement with
        // the last known price ($60, still below the line):
        guard.forceCheck(60_00000000);
        assertTrue(guard.stopLossLatched()); // crossing fired again
        assertEq(system.callbackRequests(), 2);
        assertPricePayload(
            PiggyGuardCallback.executeStopLoss.selector, 60_00000000, 90_00000000, 2
        );
    }

    function testForceCheckInBandPriceJustClearsLatches() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // latch set
        assertTrue(guard.stopLossLatched());

        guard.forceCheck(100_00000000); // back inside the band
        assertFalse(guard.stopLossLatched());
        assertFalse(guard.takeProfitLatched());
        assertEq(system.callbackRequests(), 1); // no new request
    }

    function testForceCheckOnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(PiggyGuardReactive.NotOwner.selector, address(0xBAD))
        );
        guard.forceCheck(60_00000000);
    }

    // ---- latch auto-clear when the condition disappears (round-3 item 2) -

    /// @notice The in-band branch of _onPrice already re-arms both
    ///         crossings; this pins the take-profit side explicitly (the
    ///         stop-loss side is covered by testBandReturnRearmsBothCrossings).
    function testTakeProfitLatchClearsWhenPriceReturnsInBand() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(130_00000000)); // take-profit fires + latches
        assertTrue(guard.takeProfitLatched());

        vm.prank(SYSTEM);
        guard.react(priceLog(110_00000000)); // back below the line, in band
        assertFalse(guard.takeProfitLatched());
        assertEq(system.callbackRequests(), 1); // no extra request
    }
}
