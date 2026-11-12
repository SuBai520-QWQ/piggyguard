// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Minimal stand-in for Reactive's system contract (0x8888...), used
///         only in local tests via vm.etch. It records subscriptions and
///         callback requests so tests can assert on them. It is NOT part of
///         the deployed system and never goes on-chain.
contract MockSystem {
    uint256 public subscribeCalls;
    uint256 public callbackRequests;
    bytes public lastPayload;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_)
        external
    {
        callbackRequests++;
        lastPayload = config_.payload;
        lastChainId = config_.chainId;
        lastRecipient = config_.recipient;
        lastGasLimit = config_.gasLimit;
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
