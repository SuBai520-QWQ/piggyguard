// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { PiggyGuardReactive } from "../src/PiggyGuardReactive.sol";
import { MockSystem } from "./mocks/MockSystem.sol";

/// @notice Unit tests for the reactive decision logic (latches, band re-arm,
///         Cron DCA, silent ignore of foreign logs).
/// @dev The constructor's SYSTEM.subscribe calls target the real SYSTEM address
///      (0x8888...), which has no code on a local test chain — those calls
///      succeed silently. react() is invoked via vm.prank(SYSTEM) so the
///      onlySystem guard passes, and requestCallbackV_1_0 likewise no-ops.
///      ActionRequested events are counted to prove exactly-once firing.
contract PiggyGuardReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;

    MockPriceFeed feed;
    PiggyGuardReactive guard;

    uint256 constant PRICE_TOPIC = 0x945c1c4e99aa89f648fbfe3df471b916f719e16d960fcec0737d4d56bd696838;
    /// @notice Cron100 topic — must equal PiggyGuardReactive.CRON100_TOPIC.
    uint256 constant CRON_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    bytes32 constant ACTION_TOPIC = keccak256("ActionRequested(string,uint256,uint256)");

    function setUp() public {
        // The guard's constructor calls SYSTEM.subscribe; on a local chain
        // that address has no code and the call reverts, so etch a mock
        // system contract there first (test-only, never deployed on-chain).
        vm.etch(SYSTEM, type(MockSystem).runtimeCode);
        feed = new MockPriceFeed(100_00000000); // $100.00
        guard = new PiggyGuardReactive(
            address(feed),
            90_00000000, // stop-loss $90
            120_00000000, // take-profit $120
            CRON_TOPIC
        );
        guard.setCallback(address(0xCA11BAC));
    }

    function guardCronTopic() internal view returns (uint256) {
        return guard.CRON100_TOPIC();
    }

    function priceLog(uint256 price_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 84532,
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
            chainId: 5318007,
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

    function testStopLossFiresOncePerCrossing() public {
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(85_00000000)); // below $90 -> fires
        vm.prank(SYSTEM);
        guard.react(priceLog(80_00000000)); // still below -> must NOT fire again
        assertEq(countActions(), 1);
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
    }

    function testInBandPriceDoesNothing() public {
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(priceLog(100_00000000));
        assertEq(countActions(), 0);
    }

    function testCronTickRequestsDca() public {
        // Build the log BEFORE pranking: cronLog() calls the guard contract,
        // which would consume the prank meant for react().
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 1);
    }

    function testCronTickSkippedWhenDcaDisabled() public {
        guard.setDcaEnabled(false);
        IReactive.LogRecord memory log = cronLog();
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(log);
        assertEq(countActions(), 0);
    }

    function testForeignLogIsIgnoredSilently() public {
        IReactive.LogRecord memory foreignLog = priceLog(50_00000000);
        foreignLog.contractAddress = address(0xDEAD); // not our feed
        vm.recordLogs();
        vm.prank(SYSTEM);
        guard.react(foreignLog); // must not revert, must not fire
        assertEq(countActions(), 0);
    }

    function testNonSystemCannotCallReact() public {
        vm.expectRevert();
        guard.react(priceLog(85_00000000));
    }
}
