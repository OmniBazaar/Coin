// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockOmniCore
 * @author OmniBazaar Team
 * @notice Mock contract for testing OmniParticipation and OmniValidatorRewards
 * @dev Simulates OmniCore for unit tests
 */
contract MockOmniCore {
    /// @notice Stake information structure
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Node information structure
    struct NodeInfo {
        address wallet;
        string nodeType;
        string endpoint;
        uint256 registeredAt;
        uint256 lastHeartbeat;
        bool active;
    }

    mapping(address => bool) private _validators;
    mapping(address => Stake) private _stakes;
    mapping(address => NodeInfo) private _nodes;
    address[] private _activeNodes;
    mapping(address => bool) private _activeNodeMap;

    // ═══════════════════════════════════════════════════════════════════════
    //                         MOCK SETTERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set validator status for user
     * @param validator Validator address
     * @param status Validator status
     */
    function setValidator(address validator, bool status) external {
        _validators[validator] = status;
    }

    /**
     * @notice Set stake for user
     * @param user User address
     * @param amount Stake amount
     * @param tier Staking tier (1-5)
     * @param duration Duration tier (0-3)
     * @param lockTime Lock timestamp
     * @param active Whether stake is active
     */
    function setStake(
        address user,
        uint256 amount,
        uint256 tier,
        uint256 duration,
        uint256 lockTime,
        bool active
    ) external {
        _stakes[user] = Stake({
            amount: amount,
            tier: tier,
            duration: duration,
            lockTime: lockTime,
            active: active
        });
    }

    /**
     * @notice Register a mock node
     * @param wallet Node wallet address
     * @param nodeType Type of node
     * @param endpoint Node endpoint
     */
    function registerMockNode(
        address wallet,
        string memory nodeType,
        string memory endpoint
    ) external {
        _nodes[wallet] = NodeInfo({
            wallet: wallet,
            nodeType: nodeType,
            endpoint: endpoint,
            registeredAt: block.timestamp,
            lastHeartbeat: block.timestamp,
            active: true
        });

        if (!_activeNodeMap[wallet]) {
            _activeNodes.push(wallet);
            _activeNodeMap[wallet] = true;
        }
    }

    /**
     * @notice Deactivate a mock node
     * @param wallet Node wallet address
     */
    function deactivateMockNode(address wallet) external {
        if (_nodes[wallet].active) {
            _nodes[wallet].active = false;
            // Remove from active nodes
            for (uint256 i = 0; i < _activeNodes.length; i++) {
                if (_activeNodes[i] == wallet) {
                    _activeNodes[i] = _activeNodes[_activeNodes.length - 1];
                    _activeNodes.pop();
                    _activeNodeMap[wallet] = false;
                    break;
                }
            }
        }
    }

    /**
     * @notice Update node heartbeat
     * @param wallet Node wallet address
     */
    function updateHeartbeat(address wallet) external {
        _nodes[wallet].lastHeartbeat = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         INTERFACE IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if address is a validator
     * @param validator Address to check
     * @return True if validator
     */
    function isValidator(address validator) external view returns (bool) {
        return _validators[validator];
    }

    /**
     * @notice Get stake information
     * @param user User address
     * @return Stake struct with staking details
     */
    function getStake(address user) external view returns (Stake memory) {
        return _stakes[user];
    }

    /**
     * @notice Get node information
     * @param wallet Node wallet address
     * @return NodeInfo struct
     */
    function getNodeInfo(address wallet) external view returns (NodeInfo memory) {
        return _nodes[wallet];
    }

    /**
     * @notice Get all active nodes
     * @return Array of active node addresses
     */
    function getActiveNodes() external view returns (address[] memory) {
        return _activeNodes;
    }

    /**
     * @notice Get active node count
     * @return Number of active nodes
     */
    function getActiveNodeCount() external view returns (uint256) {
        return _activeNodes.length;
    }

    /**
     * @notice Get total node count
     * @return Total number of nodes
     */
    function getTotalNodeCount() external view returns (uint256) {
        return _activeNodes.length;
    }

    /**
     * @notice Get active nodes with heartbeat within time window
     * @param timeWindow Time window in seconds
     * @return Array of active node addresses
     */
    function getActiveNodesWithinTime(
        uint256 timeWindow
    ) external view returns (address[] memory) {
        uint256 count = 0;
        uint256 cutoff = block.timestamp - timeWindow;

        // Count valid nodes
        for (uint256 i = 0; i < _activeNodes.length; i++) {
            if (_nodes[_activeNodes[i]].lastHeartbeat >= cutoff) {
                count++;
            }
        }

        // Build result array
        address[] memory result = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _activeNodes.length; i++) {
            if (_nodes[_activeNodes[i]].lastHeartbeat >= cutoff) {
                result[index] = _activeNodes[i];
                index++;
            }
        }

        return result;
    }
}
