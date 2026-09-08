// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockBootstrapForAttestation
 * @notice Test-only stub of `Bootstrap.sol`'s minimal surface used by
 *         `RandomCommitteeVerifier`. Lets tests poke individual node state
 *         without exercising the full Bootstrap registration flow.
 * @dev Implements the `IBootstrapReader` interface declared at the bottom
 *      of `RandomCommitteeVerifier.sol`. Storage layout intentionally
 *      independent of the real Bootstrap — tests need direct control of
 *      every (address → active, nodeType) tuple.
 */
contract MockBootstrapForAttestation {
    struct NodeState {
        bool active;
        uint8 nodeType;
        bool registered;
    }

    mapping(address node => NodeState state) private _nodes;
    address[] private _registered;

    /**
     * @notice Test helper: mark an address as active gateway validator.
     */
    function setNodeActive(address node, bool active, uint8 nodeType) external {
        if (!_nodes[node].registered) {
            _nodes[node].registered = true;
            _registered.push(node);
        }
        _nodes[node].active = active;
        _nodes[node].nodeType = nodeType;
    }

    /// @notice Mirror of `Bootstrap.isNodeActive(address)`.
    function isNodeActive(address nodeAddress)
        external
        view
        returns (bool isActive, uint8 nodeType)
    {
        NodeState memory s = _nodes[nodeAddress];
        return (s.active, s.nodeType);
    }

    /// @notice Returns active nodes of `nodeType` up to `limit`.
    function getActiveNodes(uint8 nodeType, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        uint256 max = limit;
        if (max == 0 || max > _registered.length) {
            max = _registered.length;
        }
        // Pass 1: count matches up to max.
        uint256 count;
        for (uint256 i = 0; i < _registered.length && count < max; ++i) {
            NodeState memory s = _nodes[_registered[i]];
            if (s.active && s.nodeType == nodeType) {
                ++count;
            }
        }
        // Pass 2: fill array.
        address[] memory out = new address[](count);
        uint256 idx;
        for (uint256 i = 0; i < _registered.length && idx < count; ++i) {
            NodeState memory s = _nodes[_registered[i]];
            if (s.active && s.nodeType == nodeType) {
                out[idx] = _registered[i];
                ++idx;
            }
        }
        return out;
    }
}
