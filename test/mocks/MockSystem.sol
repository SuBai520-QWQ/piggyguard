// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Minimal stand-in for Reactive's system contract (0x8888...), used
///         only in local tests via vm.etch. It records subscriptions and
///         callback requests so tests can assert on them. It is NOT part of
///         the deployed system and never goes on-chain.
contract MockSystem {
    struct Subscription {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    uint256 public subscribeCalls;
    Subscription[] public subscriptions;

    uint256 public callbackRequests;
    bytes public lastPayload;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGasLimit;

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        subscribeCalls++;
        subscriptions.push(
            Subscription({
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_
            })
        );
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
