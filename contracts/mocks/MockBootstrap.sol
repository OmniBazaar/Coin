// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockBootstrap
 * @notice Mock Bootstrap contract for testing OmniValidatorRewards V3
 * @dev Provides configurable isNodeActive() responses for testing
 *      per-node-type reward caps and overflow routing.
 */
contract MockBootstrap {
    /// @notice Node info for mock responses
    struct MockNode {
        bool active;
        uint8 nodeType;
    }

    /// @notice Registered mock nodes
    mapping(address => MockNode) public nodes;

    /**
     * @notice Set a mock node's active status and type
     * @param nodeAddress Address of the node
     * @param active Whether the node is active
     * @param nodeType Node type (0=gateway, 1=computation, 2=listing)
     */
    function setNode(
        address nodeAddress,
        bool active,
        uint8 nodeType
    ) external {
        nodes[nodeAddress] = MockNode({
            active: active,
            nodeType: nodeType
        });
    }

    /**
     * @notice Check if a node is active and get its type
     * @param nodeAddress Address of the node to check
     * @return isActive Whether the node is currently active
     * @return nodeType Node type (0=gateway, 1=computation, 2=listing)
     */
    function isNodeActive(
        address nodeAddress
    ) external view returns (bool isActive, uint8 nodeType) {
        MockNode storage node = nodes[nodeAddress];
        return (node.active, node.nodeType);
    }
}
