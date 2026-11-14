// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";

contract MockPriceFeedTest is Test {
    MockPriceFeed feed;

    event PriceUpdated(uint256 indexed price, uint256 timestamp);

    function setUp() public {
        feed = new MockPriceFeed(100_00000000); // $100.00
    }

    function testInitialPrice() public view {
        assertEq(feed.latestPrice(), 100_00000000);
        assertEq(feed.owner(), address(this));
    }

    function testPushUpdatesPriceAndEmits() public {
        vm.expectEmit(true, false, false, true, address(feed));
        emit PriceUpdated(90_00000000, block.timestamp);
        feed.pushPrice(90_00000000);
        assertEq(feed.latestPrice(), 90_00000000);
    }

    function testNonOwnerCannotPush() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(MockPriceFeed.NotOwner.selector, address(0xBEEF)));
        feed.pushPrice(1);
    }

    function testPushZeroReverts() public {
        vm.expectRevert(MockPriceFeed.ZeroPrice.selector);
        feed.pushPrice(0);
        // The rejected push must not change the stored price.
        assertEq(feed.latestPrice(), 100_00000000);
    }

    /// @notice fix-03 (Perch P13): a zero initial price is rejected at
    ///         deployment instead of poisoning every consumer.
    function testConstructorRejectsZeroPrice() public {
        vm.expectRevert(MockPriceFeed.ZeroPrice.selector);
        new MockPriceFeed(0);
    }
}
