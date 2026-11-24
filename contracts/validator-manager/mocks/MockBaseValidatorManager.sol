// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @dev Test double for the base manager's owner-gated removal path. It records
/// the caller so a test can prove the forwarder called it, and mimics
/// `onlyOwner` the same way the live base does.
contract MockBaseValidatorManager {
    address public owner;
    bytes32 public lastRemoval;
    uint32 public lastCompletion;
    address public lastCaller;

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address o) external {
        owner = o;
    }

    function initiateValidatorRemoval(bytes32 validationID) external {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        lastRemoval = validationID;
        lastCaller = msg.sender;
    }

    function completeValidatorRemoval(uint32 messageIndex) external {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        lastCompletion = messageIndex;
        lastCaller = msg.sender;
    }

    function resendValidatorRemovalMessage(bytes32) external view {
        require(msg.sender == owner, "Ownable: caller is not the owner");
    }
}
