// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockWarpMessenger
 * @notice Mock implementation of IWarpMessenger for testing
 */
contract MockWarpMessenger {
    struct WarpMessage {
        bytes32 sourceChainID;
        address originSenderAddress;
        bytes payload;
    }
    
    bytes32 public mockBlockchainID = keccak256("test-chain");
    WarpMessage[] public messages;
    mapping(bytes32 => uint32) public messageIndices;
    uint32 public messageCounter;
    
    function getBlockchainID() external view returns (bytes32) {
        return mockBlockchainID;
    }
    
    function sendWarpMessage(bytes calldata payload) external returns (bytes32) {
        bytes32 messageId = keccak256(abi.encodePacked(block.timestamp, msg.sender, payload));
        
        messages.push(WarpMessage({
            sourceChainID: mockBlockchainID,
            originSenderAddress: msg.sender,
            payload: payload
        }));
        
        messageIndices[messageId] = messageCounter;
        messageCounter++;
        
        return messageId;
    }
    
    function getVerifiedWarpMessage(uint32 index) external view returns (WarpMessage memory message, bool valid) {
        if (index < messages.length) {
            return (messages[index], true);
        }
        return (WarpMessage(bytes32(0), address(0), ""), false);
    }
    
    // Helper function to add mock messages for testing
    function addMockMessage(bytes32 sourceChainID, address originSenderAddress, bytes calldata payload) external {
        messages.push(WarpMessage({
            sourceChainID: sourceChainID,
            originSenderAddress: originSenderAddress,
            payload: payload
        }));
    }
}