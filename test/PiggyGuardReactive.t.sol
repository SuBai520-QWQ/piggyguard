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
///         Cron DCA, silent ignore of foreign logs, and the fix-05 result-event
///         confirmation / timeout re-arm pair).
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
    address constant VAULT = address(0xBEEF);
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

    /// @notice Vault result topics (fix-05). Recomputed here rather than read
    ///         from the contract so a drift between the two is a test failure.
    bytes32 constant SL_EXECUTED_TOPIC =
        keccak256("StopLossExecuted(uint256,uint256,uint256,uint256)");
    bytes32 constant SL_SKIPPED_TOPIC = keccak256("StopLossSkipped(string,uint256,uint256)");
    bytes32 constant TP_EXECUTED_TOPIC =
        keccak256("TakeProfitExecuted(uint256,uint256,uint256,uint256)");
    bytes32 constant TP_SKIPPED_TOPIC = keccak256("TakeProfitSkipped(string,uint256,uint256)");

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

    /// @dev Vault result log: StopLossExecuted(actionId, price, sold, received).
    ///      actionId is the first data word.
    function stopLossExecutedLog(
        uint256 actionId_,
        uint256 price_,
        uint256 sold_,
        uint256 received_
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: VAULT,
            topic0: uint256(SL_EXECUTED_TOPIC),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(actionId_, price_, sold_, received_),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    /// @dev StopLossSkipped(reason, actionId, price): the string offset is the
    ///      first data word, actionId the second — the reactive contract reads
    ///      it from there instead of abi.decoding.
    function stopLossSkippedLog(uint256 actionId_, uint256 price_)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: VAULT,
            topic0: uint256(SL_SKIPPED_TOPIC),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode("vault paused", actionId_, price_),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function takeProfitSkippedLog(uint256 actionId_, uint256 price_)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: VAULT,
            topic0: uint256(TP_SKIPPED_TOPIC),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode("proceeds would be zero", actionId_, price_),
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

    // =====================================================================
    // fix-05 (Perch round-4 C1): result-event confirmation + timeout re-arm
    // =====================================================================

    // ---- layer 1: the vault result subscriptions ----

    function testVaultResultSubscriptions() public {
        guard.setVault(VAULT);
        assertEq(system.subscribeCalls(), 6); // 2 constructor + 4 result topics

        (
            uint256 c2,
            address a2,
            uint256 t02,
            uint256 t12,
            uint256 t22,
            uint256 t32
        ) = system.subscriptions(2);
        assertEq(c2, BASE_SEPOLIA_CHAIN_ID);
        assertEq(a2, VAULT);
        assertEq(t02, uint256(SL_EXECUTED_TOPIC));
        assertEq(t12, REACTIVE_IGNORE);
        assertEq(t22, REACTIVE_IGNORE);
        assertEq(t32, REACTIVE_IGNORE);

        (
            uint256 c3,
            address a3,
            uint256 t03,
            uint256 t13,
            uint256 t23,
            uint256 t33
        ) = system.subscriptions(3);
        assertEq(c3, BASE_SEPOLIA_CHAIN_ID);
        assertEq(a3, VAULT);
        assertEq(t03, uint256(SL_SKIPPED_TOPIC));
        assertEq(t13, REACTIVE_IGNORE);
        assertEq(t23, REACTIVE_IGNORE);
        assertEq(t33, REACTIVE_IGNORE);

        (
            uint256 c4,
            address a4,
            uint256 t04,
            uint256 t14,
            uint256 t24,
            uint256 t34
        ) = system.subscriptions(4);
        assertEq(c4, BASE_SEPOLIA_CHAIN_ID);
        assertEq(a4, VAULT);
        assertEq(t04, uint256(TP_EXECUTED_TOPIC));
        assertEq(t14, REACTIVE_IGNORE);
        assertEq(t24, REACTIVE_IGNORE);
        assertEq(t34, REACTIVE_IGNORE);

        (
            uint256 c5,
            address a5,
            uint256 t05,
            uint256 t15,
            uint256 t25,
            uint256 t35
        ) = system.subscriptions(5);
        assertEq(c5, BASE_SEPOLIA_CHAIN_ID);
        assertEq(a5, VAULT);
        assertEq(t05, uint256(TP_SKIPPED_TOPIC));
        assertEq(t15, REACTIVE_IGNORE);
        assertEq(t25, REACTIVE_IGNORE);
        assertEq(t35, REACTIVE_IGNORE);
    }

    function testSetVaultIsIdempotentAndOwnerOnly() public {
        guard.setVault(VAULT);
        assertEq(system.subscribeCalls(), 6);
        guard.setVault(VAULT); // same address: no double subscription
        assertEq(system.subscribeCalls(), 6);

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(PiggyGuardReactive.NotOwner.selector, address(0xBAD))
        );
        guard.setVault(address(0x1234));

        vm.expectRevert(PiggyGuardReactive.ZeroAddress.selector);
        guard.setVault(address(0));
    }

    // ---- layer 1: a result event clears the latch, never re-sends ----

    /// @notice Brief test 2 (first half): a Skipped result releases the latch.
    ///         The result itself must not produce a new request, and a repeat
    ///         of the same price — condition still true — re-requests.
    function testSkippedResultClearsLatchAndSamePriceRefires() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());
        assertEq(system.callbackRequests(), 1);
        assertEq(guard.pendingStopLossId(), 1);

        // The vault saw the request and skipped it (e.g. paused).
        vm.prank(SYSTEM);
        guard.react(stopLossSkippedLog(1, 85_00000000));
        assertFalse(guard.stopLossLatched());
        assertEq(guard.pendingStopLossId(), 0);
        assertEq(guard.stopLossLatchedAtBlock(), 0);
        assertEq(system.callbackRequests(), 1); // the result never re-sends

        // Same price pushed again: the condition still holds -> new request.
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 2);
        assertTrue(guard.stopLossLatched());
        assertEq(guard.pendingStopLossId(), 2);
        assertPricePayload(PiggyGuardCallback.executeStopLoss.selector, 85_00000000, 90_00000000, 2);
    }

    /// @notice Brief test 2 (second half): after the Skipped result, a price
    ///         back inside the band must not request anything.
    function testSkippedResultClearsLatchAndInBandPriceDoesNotRefire() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        vm.prank(SYSTEM);
        guard.react(stopLossSkippedLog(1, 85_00000000));
        assertFalse(guard.stopLossLatched());

        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000)); // back in band
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 1);
        assertFalse(guard.stopLossLatched());
    }

    /// @notice Brief test 3: an Executed result releases the latch, produces
    ///         no request of its own, and an in-band price afterwards stays
    ///         silent — no double-fire.
    function testExecutedResultClearsLatchWithoutRefire() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());

        vm.prank(SYSTEM);
        guard.react(stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000));
        assertFalse(guard.stopLossLatched());
        assertEq(guard.pendingStopLossId(), 0);
        assertEq(system.callbackRequests(), 1); // no auto-resend from the result

        // Price back inside the band: nothing to do, nothing re-sent.
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000));
        assertEq(countActions(), 0);
        assertEq(system.callbackRequests(), 1);
        assertFalse(guard.stopLossLatched());
    }

    /// @notice The take-profit side has the same layer-1 behaviour.
    function testTakeProfitResultClearsLatch() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(130_00000000));
        assertTrue(guard.takeProfitLatched());
        assertEq(guard.pendingTakeProfitId(), 1);

        vm.prank(SYSTEM);
        guard.react(takeProfitSkippedLog(1, 130_00000000));
        assertFalse(guard.takeProfitLatched());
        assertEq(guard.pendingTakeProfitId(), 0);
        assertEq(system.callbackRequests(), 1);
    }

    /// @notice A result for an OLDER request must not release a FRESH latch:
    ///         otherwise the next price event would re-fire an action the
    ///         vault already executed, and a second take-profit sells another
    ///         50%.
    function testStaleResultDoesNotClearFreshLatch() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // id 1
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000)); // in band: latches cleared
        vm.prank(SYSTEM);
        guard.react(priceLog(84_00000000)); // id 2, latch set
        assertEq(guard.pendingStopLossId(), 2);

        // A late result for the OLD request (id 1) arrives now.
        vm.prank(SYSTEM);
        guard.react(stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000));
        assertTrue(guard.stopLossLatched()); // still latched on id 2
        assertEq(guard.pendingStopLossId(), 2);
    }

    /// @notice Result events are only trusted from the wired vault, on the
    ///         origin chain. Before setVault, and from any other emitter,
    ///         they are inert.
    function testResultLogIgnoredBeforeVaultIsSet() public {
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());

        vm.prank(SYSTEM);
        guard.react(stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000));
        assertTrue(guard.stopLossLatched()); // vault not wired: ignored
    }

    function testResultLogFromForeignContractIsIgnored() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());

        IReactive.LogRecord memory log =
            stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000);
        log.contractAddress = address(0xDEAD); // right topic, wrong emitter
        vm.prank(SYSTEM);
        guard.react(log);
        assertTrue(guard.stopLossLatched());
    }

    function testResultLogFromWrongChainIsIgnored() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());

        IReactive.LogRecord memory log =
            stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000);
        log.chainId = LASNA_CHAIN_ID; // right emitter address, wrong chain
        vm.prank(SYSTEM);
        guard.react(log);
        assertTrue(guard.stopLossLatched());
    }

    /// @notice A truncated payload must not revert react() (the actionId is
    ///         read from raw data words, guarded by a length check).
    function testTruncatedResultPayloadDoesNotRevert() public {
        guard.setVault(VAULT);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());

        IReactive.LogRecord memory log =
            stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000);
        log.data = hex"00"; // far too short to hold an actionId
        vm.prank(SYSTEM);
        guard.react(log); // must not revert
        assertTrue(guard.stopLossLatched()); // and must not clear on garbage
    }

    // ---- layer 2: timeout re-arm on the Cron tick ----

    /// @notice Brief test 1: the request was accepted, the delivery failed on
    ///         Base (no result event ever arrives), >300 blocks pass and a
    ///         Cron tick lands: the latch is released and the action is
    ///         re-requested at the last observed price.
    function testTimeoutRearmsAfterFailedDelivery() public {
        guard.setVault(VAULT);
        vm.roll(1000);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // id 1, latched at block 1000
        assertTrue(guard.stopLossLatched());
        assertEq(guard.stopLossLatchedAtBlock(), 1000);
        assertEq(guard.pendingStopLossId(), 1);
        assertEq(system.callbackRequests(), 1);

        // No result event ever arrives: the callback never landed on Base.
        // Advance strictly past the timeout, then deliver a Cron tick.
        vm.roll(1000 + guard.REARM_TIMEOUT_BLOCKS() + 1);
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);

        // The stale latch was released and the action re-requested at the
        // last observed price ($85, still below the $90 line), which
        // re-latched on the new id.
        assertEq(countActions(), 1); // exactly one re-request
        assertEq(system.callbackRequests(), 2);
        assertTrue(guard.stopLossLatched());
        assertEq(guard.pendingStopLossId(), 2);
        assertEq(guard.stopLossLatchedAtBlock(), 1000 + guard.REARM_TIMEOUT_BLOCKS() + 1);
        assertPricePayload(
            PiggyGuardCallback.executeStopLoss.selector, 85_00000000, 90_00000000, 2
        );
    }

    /// @notice Brief test 4: inside the timeout window a Cron tick must not
    ///         re-arm. Pins the boundary too: the check is strictly greater,
    ///         so block.number == latchedAt + TIMEOUT is still "not yet".
    function testCronWithinTimeoutDoesNotRearm() public {
        guard.setVault(VAULT);
        vm.roll(1000);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000));
        assertTrue(guard.stopLossLatched());
        assertEq(system.callbackRequests(), 1);

        // Exactly at the boundary: not past the timeout.
        vm.roll(1000 + guard.REARM_TIMEOUT_BLOCKS());
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);

        assertEq(countActions(), 0); // no re-request
        assertEq(system.callbackRequests(), 1);
        assertTrue(guard.stopLossLatched());
        assertEq(guard.pendingStopLossId(), 1);
        assertEq(guard.stopLossLatchedAtBlock(), 1000); // untouched
    }

    /// @notice The take-profit side has the same layer-2 behaviour.
    function testTakeProfitTimeoutRearm() public {
        guard.setVault(VAULT);
        vm.roll(2000);
        vm.prank(SYSTEM);
        guard.react(priceLog(130_00000000)); // id 1, TP latched at block 2000
        assertTrue(guard.takeProfitLatched());
        assertEq(guard.takeProfitLatchedAtBlock(), 2000);
        assertEq(guard.pendingTakeProfitId(), 1);

        vm.roll(2000 + guard.REARM_TIMEOUT_BLOCKS() + 1);
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);

        assertEq(countActions(), 1);
        assertEq(system.callbackRequests(), 2);
        assertTrue(guard.takeProfitLatched());
        assertEq(guard.pendingTakeProfitId(), 2);
        assertEq(guard.takeProfitLatchedAtBlock(), 2000 + guard.REARM_TIMEOUT_BLOCKS() + 1);
        assertPricePayload(
            PiggyGuardCallback.executeTakeProfit.selector, 130_00000000, 120_00000000, 2
        );
    }

    /// @notice A result event that lands before the timeout must prevent the
    ///         re-arm. After a confirmed execution the Cron tick only does
    ///         its DCA job: the stop-loss is not re-fired on its own, which
    ///         is what keeps the design free of a resend loop.
    function testResultBeforeTimeoutPreventsRearm() public {
        guard.setVault(VAULT);
        vm.roll(1000);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // id 1, latched
        assertTrue(guard.stopLossLatched());

        // The delivery landed and executed.
        vm.prank(SYSTEM);
        guard.react(stopLossExecutedLog(1, 85_00000000, 2_00000000, 170_00000000));
        assertFalse(guard.stopLossLatched());
        assertEq(guard.pendingStopLossId(), 0);

        // Long after the timeout would have fired: the Cron tick finds no
        // latch to re-arm and just buys.
        vm.roll(1000 + guard.REARM_TIMEOUT_BLOCKS() + 1);
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);

        assertEq(countActions(), 1); // the DCA request only
        assertDcaPayload(2);
        assertEq(system.callbackRequests(), 2); // stop-loss + DCA
        assertFalse(guard.stopLossLatched());
    }

    /// @notice The re-arm is bounded to one attempt per Cron tick: a second
    ///         tick immediately after a re-arm sees a fresh latch and leaves
    ///         it alone (the retry rate is the Cron period, by construction).
    function testRearmHappensAtMostOncePerCronTick() public {
        guard.setVault(VAULT);
        vm.roll(1000);
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // id 1
        assertEq(system.callbackRequests(), 1);

        vm.roll(1000 + guard.REARM_TIMEOUT_BLOCKS() + 1);
        IReactive.LogRecord memory log = cronLog();
        vm.prank(SYSTEM);
        guard.react(log); // re-arm -> id 2
        assertEq(system.callbackRequests(), 2);
        assertEq(guard.pendingStopLossId(), 2);

        // Next Cron tick, same block range: the latch is fresh, no re-arm.
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(system.callbackRequests(), 2);
        assertEq(guard.pendingStopLossId(), 2);
    }
}
