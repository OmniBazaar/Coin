// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title Bootstrap
 * @author OmniBazaar Development Team
 * @notice Single source of truth for validator/node discovery on Avalanche C-Chain
 * @dev This contract serves as the primary node registry for OmniBazaar network discovery.
 *      Validators and service nodes register themselves here when starting up.
 *      WebApp and other clients query this contract to discover available validators.
 *
 *      Architecture:
 *      - Deployed on Avalanche C-Chain (publicly accessible)
 *      - Validators self-register when they start (paying gas)
 *      - Clients query this contract to find validators
 *      - Admin functions for emergency deactivation only
 *
 *      Node Types:
 *      - 0 = Gateway Validator (runs avalanchego, participates in consensus)
 *      - 1 = Computation Node (runs TypeScript services, no consensus)
 *      - 2 = Listing Node (stores marketplace listings only)
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract Bootstrap is AccessControl {
    /**
     * @notice Node information for registered validators/nodes
     * @dev Struct fields ordered for optimal storage packing:
     *      Slot 1: active (1) + nodeType (1) + stakingPort (2) + nodeAddress (20) = 24 bytes
     *      Slot 2: lastUpdate (32 bytes)
     *      Remaining: string pointers (32 bytes each)
     * @param active Whether this node is currently active
     * @param nodeType Type of node: 0=gateway, 1=computation, 2=listing
     * @param stakingPort Port for avalanchego P2P staking connections
     * @param nodeAddress Node's Ethereum address
     * @param lastUpdate Timestamp of last update (for freshness checking)
     * @param multiaddr libp2p multiaddress for P2P connections
     * @param httpEndpoint HTTP API endpoint
     * @param wsEndpoint WebSocket endpoint
     * @param region Geographic region
     * @param avalancheRpcEndpoint RPC endpoint for OmniCoin L1 blockchain
     * @param publicIp Public IP address for avalanchego peer discovery
     * @param nodeId TLS-derived NodeID for avalanchego (e.g., "NodeID-...")
     */
    struct NodeInfo {
        // Slot 1: packed fields (24 bytes used of 32)
        bool active;
        uint8 nodeType;
        uint16 stakingPort;
        address nodeAddress;
        // Slot 2: full slot
        uint256 lastUpdate;
        // String pointers (each takes a slot)
        string multiaddr;
        string httpEndpoint;
        string wsEndpoint;
        string region;
        string avalancheRpcEndpoint;
        string publicIp;
        string nodeId;
    }

    /// @notice Role identifier for bootstrap administrator (emergency actions only)
    bytes32 public constant BOOTSTRAP_ADMIN_ROLE = keccak256("BOOTSTRAP_ADMIN_ROLE");

    /// @notice Address of OmniCore contract on OmniCoin L1 (for reference)
    address public omniCoreAddress;

    /// @notice Chain ID of the OmniCoin L1 network
    uint256 public omniCoreChainId;

    /// @notice RPC URL for OmniCoin L1 (off-chain reference)
    string public omniCoreRpcUrl;

    /// @notice List of all registered node addresses
    address[] public registeredNodes;

    /// @notice Mapping from node address to index in registeredNodes array
    mapping(address => uint256) public nodeIndex;

    /// @notice Mapping from node address to node info
    mapping(address => NodeInfo) public nodeRegistry;

    /// @notice Count of active nodes by type (0=gateway, 1=computation, 2=listing)
    mapping(uint8 => uint256) public activeNodeCounts;

    /**
     * @notice Emitted when OmniCore reference is updated
     * @param omniCoreAddress New OmniCore contract address
     * @param chainId New chain ID
     * @param rpcUrl New RPC URL
     */
    event OmniCoreUpdated(
        address indexed omniCoreAddress,
        uint256 indexed chainId,
        string rpcUrl
    );

    /**
     * @notice Emitted when a node registers or updates
     * @param nodeAddress Node's Ethereum address
     * @param nodeType Type of node (0=gateway, 1=computation, 2=listing)
     * @param httpEndpoint HTTP API endpoint
     * @param isNew Whether this is a new registration (true) or update (false)
     */
    event NodeRegistered(
        address indexed nodeAddress,
        uint8 indexed nodeType,
        string httpEndpoint,
        bool isNew
    );

    /**
     * @notice Emitted when a node deactivates
     * @param nodeAddress Node's Ethereum address
     * @param reason Reason for deactivation
     */
    event NodeDeactivated(
        address indexed nodeAddress,
        string reason
    );

    /**
     * @notice Emitted when admin force-deactivates a node
     * @param nodeAddress Node's Ethereum address
     * @param admin Admin who performed the action
     * @param reason Reason for deactivation
     */
    event NodeAdminDeactivated(
        address indexed nodeAddress,
        address indexed admin,
        string reason
    );

    /**
     * @notice Invalid address provided
     */
    error InvalidAddress();

    /**
     * @notice Invalid string parameter provided
     */
    error InvalidParameter();

    /**
     * @notice Invalid chain ID provided
     */
    error InvalidChainId();

    /**
     * @notice Invalid node type (must be 0, 1, or 2)
     */
    error InvalidNodeType();

    /**
     * @notice Node is not active
     */
    error NodeNotActive();

    /**
     * @notice Node not found
     */
    error NodeNotFound();

    /**
     * @notice Initializes the Bootstrap contract
     * @param _omniCoreAddress Address of OmniCore contract on OmniCoin L1
     * @param _omniCoreChainId Chain ID of OmniCoin L1
     * @param _omniCoreRpcUrl RPC URL for OmniCoin L1
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address _omniCoreAddress,
        uint256 _omniCoreChainId,
        string memory _omniCoreRpcUrl
    ) {
        if (_omniCoreAddress == address(0)) revert InvalidAddress();
        if (_omniCoreChainId == 0) revert InvalidChainId();
        if (bytes(_omniCoreRpcUrl).length == 0) revert InvalidParameter();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BOOTSTRAP_ADMIN_ROLE, msg.sender);

        omniCoreAddress = _omniCoreAddress;
        omniCoreChainId = _omniCoreChainId;
        omniCoreRpcUrl = _omniCoreRpcUrl;

        emit OmniCoreUpdated(_omniCoreAddress, _omniCoreChainId, _omniCoreRpcUrl);
    }

    // ============================================================
    //                    SELF-REGISTRATION FUNCTIONS
    // ============================================================

    /**
     * @notice Register or update a node (self-registration)
     * @dev Nodes call this when starting up. Pays gas to register on C-Chain.
     *      This is the primary way nodes join the network.
     * @param multiaddr libp2p multiaddr for P2P connections (required for gateway nodes)
     * @param httpEndpoint HTTP endpoint URL (required)
     * @param wsEndpoint WebSocket endpoint URL (optional)
     * @param region Geographic region code (e.g. "US", "EU", "ASIA")
     * @param nodeType Type of node: 0=gateway, 1=computation, 2=listing
     */
    function registerNode(
        string calldata multiaddr,
        string calldata httpEndpoint,
        string calldata wsEndpoint,
        string calldata region,
        uint8 nodeType
    ) external {
        _registerNodeInternal(
            multiaddr,
            httpEndpoint,
            wsEndpoint,
            region,
            nodeType,
            "",  // avalancheRpcEndpoint
            0,   // stakingPort
            "",  // publicIp
            ""   // nodeId
        );
    }

    /**
     * @notice Register or update a gateway node with avalanchego peer discovery info
     * @dev Gateway validators call this to provide full peer discovery information.
     *      Required for new validators to bootstrap into the network.
     * @param multiaddr libp2p multiaddr for P2P connections
     * @param httpEndpoint HTTP endpoint URL (required)
     * @param wsEndpoint WebSocket endpoint URL
     * @param region Geographic region code (e.g. "US", "EU", "ASIA")
     * @param avalancheRpcEndpoint RPC endpoint for OmniCoin L1 (e.g., "http://x.x.x.x:40681/ext/bc/.../rpc")
     * @param stakingPort Avalanchego staking port (e.g., 35579)
     * @param publicIp Public IP address for peer discovery
     * @param nodeId TLS-derived NodeID (e.g., "NodeID-...")
     */
    function registerGatewayNode(
        string calldata multiaddr,
        string calldata httpEndpoint,
        string calldata wsEndpoint,
        string calldata region,
        string calldata avalancheRpcEndpoint,
        uint16 stakingPort,
        string calldata publicIp,
        string calldata nodeId
    ) external {
        // Gateway validators must provide peer discovery info
        if (bytes(publicIp).length == 0) revert InvalidParameter();
        if (bytes(nodeId).length == 0) revert InvalidParameter();
        if (stakingPort == 0) revert InvalidParameter();

        _registerNodeInternal(
            multiaddr,
            httpEndpoint,
            wsEndpoint,
            region,
            0,  // nodeType = gateway
            avalancheRpcEndpoint,
            stakingPort,
            publicIp,
            nodeId
        );
    }

    /**
     * @notice Update node endpoints (self-update)
     * @dev Nodes can update their endpoints without changing type
     * @param multiaddr New libp2p multiaddr
     * @param httpEndpoint New HTTP endpoint URL
     * @param wsEndpoint New WebSocket endpoint URL
     * @param region New geographic region
     */
    function updateNode(
        string calldata multiaddr,
        string calldata httpEndpoint,
        string calldata wsEndpoint,
        string calldata region
    ) external {
        NodeInfo storage info = nodeRegistry[msg.sender];
        if (!info.active) revert NodeNotActive();
        if (bytes(httpEndpoint).length == 0) revert InvalidParameter();
        // multiaddr required for gateway validators
        if (info.nodeType == 0 && bytes(multiaddr).length == 0) revert InvalidParameter();

        info.multiaddr = multiaddr;
        info.httpEndpoint = httpEndpoint;
        info.wsEndpoint = wsEndpoint;
        info.region = region;
        info.lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time

        emit NodeRegistered(msg.sender, info.nodeType, httpEndpoint, false);
    }

    /**
     * @notice Deactivate a node (self-deactivation)
     * @dev Nodes call this when going offline gracefully
     * @param reason Reason for deactivation
     */
    function deactivateNode(string calldata reason) external {
        NodeInfo storage info = nodeRegistry[msg.sender];
        if (!info.active) revert NodeNotActive();

        info.active = false;

        // Update active count
        if (info.nodeType < 3 && activeNodeCounts[info.nodeType] > 0) {
            --activeNodeCounts[info.nodeType];
        }

        emit NodeDeactivated(msg.sender, reason);
    }

    /**
     * @notice Send heartbeat to update last activity timestamp
     * @dev Optional - nodes can call this periodically to show liveness
     */
    function heartbeat() external {
        NodeInfo storage info = nodeRegistry[msg.sender];
        if (!info.active) revert NodeNotActive();

        info.lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ============================================================
    //                    ADMIN FUNCTIONS (EMERGENCY)
    // ============================================================

    /**
     * @notice Admin force-deactivate a node
     * @dev Only for emergency situations (misbehaving nodes)
     * @param nodeAddress Address of the node to deactivate
     * @param reason Reason for deactivation
     */
    function adminDeactivateNode(
        address nodeAddress,
        string calldata reason
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        NodeInfo storage info = nodeRegistry[nodeAddress];
        if (!info.active) revert NodeNotActive();

        info.active = false;

        // Update active count
        if (info.nodeType < 3 && activeNodeCounts[info.nodeType] > 0) {
            --activeNodeCounts[info.nodeType];
        }

        emit NodeAdminDeactivated(nodeAddress, msg.sender, reason);
    }

    /**
     * @notice Updates the OmniCore contract reference
     * @dev Only callable by BOOTSTRAP_ADMIN_ROLE
     * @param _omniCoreAddress New OmniCore contract address
     * @param _omniCoreChainId New chain ID
     * @param _omniCoreRpcUrl New RPC URL
     */
    function updateOmniCore(
        address _omniCoreAddress,
        uint256 _omniCoreChainId,
        string calldata _omniCoreRpcUrl
    ) external onlyRole(BOOTSTRAP_ADMIN_ROLE) {
        if (_omniCoreAddress == address(0)) revert InvalidAddress();
        if (_omniCoreChainId == 0) revert InvalidChainId();
        if (bytes(_omniCoreRpcUrl).length == 0) revert InvalidParameter();

        omniCoreAddress = _omniCoreAddress;
        omniCoreChainId = _omniCoreChainId;
        omniCoreRpcUrl = _omniCoreRpcUrl;

        emit OmniCoreUpdated(_omniCoreAddress, _omniCoreChainId, _omniCoreRpcUrl);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get active nodes by type
     * @dev Returns array of active node addresses of specified type
     * @param nodeType Type of nodes to retrieve (0=gateway, 1=computation, 2=listing)
     * @param limit Maximum number of nodes to return (gas optimization)
     * @return nodes Array of active node addresses
     */
    function getActiveNodes(
        uint8 nodeType,
        uint256 limit
    ) external view returns (address[] memory nodes) {
        if (nodeType > 2) revert InvalidNodeType();

        uint256 count = 0;
        uint256 maxCount = limit;
        if (maxCount == 0 || maxCount > registeredNodes.length) {
            maxCount = registeredNodes.length;
        }

        // Count active nodes of this type
        for (uint256 i = 0; i < registeredNodes.length && count < maxCount; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (info.active && info.nodeType == nodeType) {
                ++count;
            }
        }

        // Allocate array
        nodes = new address[](count);
        uint256 index = 0;

        // Fill array
        for (uint256 i = 0; i < registeredNodes.length && index < count; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (info.active && info.nodeType == nodeType) {
                nodes[index] = registeredNodes[i];
                ++index;
            }
        }

        return nodes;
    }

    /**
     * @notice Get all active nodes with full info
     * @dev More expensive but provides complete node information
     * @return addresses Array of node addresses
     * @return infos Array of node information
     */
    function getAllActiveNodes()
        external
        view
        returns (
            address[] memory addresses,
            NodeInfo[] memory infos
        )
    {
        uint256 count = 0;

        // Count active nodes
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            if (nodeRegistry[registeredNodes[i]].active) {
                ++count;
            }
        }

        // Allocate arrays
        addresses = new address[](count);
        infos = new NodeInfo[](count);

        // Populate arrays
        uint256 index = 0;
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            address addr = registeredNodes[i];
            if (nodeRegistry[addr].active) {
                addresses[index] = addr;
                infos[index] = nodeRegistry[addr];
                ++index;
            }
        }

        return (addresses, infos);
    }

    /**
     * @notice Get node information
     * @param nodeAddress Address of the node
     * @return multiaddr libp2p multiaddr for P2P connections
     * @return httpEndpoint HTTP endpoint URL
     * @return wsEndpoint WebSocket endpoint URL
     * @return region Geographic region
     * @return nodeType Type of node
     * @return active Whether node is active
     * @return lastUpdate Last update timestamp
     */
    function getNodeInfo(address nodeAddress) external view returns (
        string memory multiaddr,
        string memory httpEndpoint,
        string memory wsEndpoint,
        string memory region,
        uint8 nodeType,
        bool active,
        uint256 lastUpdate
    ) {
        NodeInfo storage info = nodeRegistry[nodeAddress];
        return (
            info.multiaddr,
            info.httpEndpoint,
            info.wsEndpoint,
            info.region,
            info.nodeType,
            info.active,
            info.lastUpdate
        );
    }

    /**
     * @notice Get count of active nodes by type
     * @param nodeType Type of nodes (0=gateway, 1=computation, 2=listing)
     * @return count Number of active nodes
     */
    function getActiveNodeCount(uint8 nodeType) external view returns (uint256 count) {
        if (nodeType > 2) revert InvalidNodeType();
        return activeNodeCounts[nodeType];
    }

    /**
     * @notice Get total registered node count
     * @return count Total number of registered nodes (active and inactive)
     */
    function getTotalNodeCount() external view returns (uint256 count) {
        return registeredNodes.length;
    }

    /**
     * @notice Get active nodes within a time window
     * @dev Returns nodes that have been updated within the specified time period
     * @param nodeType Type of nodes to retrieve (0=gateway, 1=computation, 2=listing)
     * @param timeWindowSeconds Time window in seconds (e.g., 3600 for last hour)
     * @param limit Maximum number of nodes to return
     * @return nodes Array of active node addresses within time window
     */
    function getActiveNodesWithinTime(
        uint8 nodeType,
        uint256 timeWindowSeconds,
        uint256 limit
    ) external view returns (address[] memory nodes) {
        if (nodeType > 2) revert InvalidNodeType();

        // solhint-disable-next-line not-rely-on-time
        uint256 cutoffTime = block.timestamp - timeWindowSeconds;

        uint256 count = 0;
        uint256 maxCount = limit;
        if (maxCount == 0 || maxCount > registeredNodes.length) {
            maxCount = registeredNodes.length;
        }

        // Count matching nodes
        for (uint256 i = 0; i < registeredNodes.length && count < maxCount; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (info.active && info.nodeType == nodeType && info.lastUpdate >= cutoffTime) {
                ++count;
            }
        }

        // Allocate and fill array
        nodes = new address[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < registeredNodes.length && index < count; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (info.active && info.nodeType == nodeType && info.lastUpdate >= cutoffTime) {
                nodes[index] = registeredNodes[i];
                ++index;
            }
        }

        return nodes;
    }

    /**
     * @notice Gets OmniCore contract information
     * @return _omniCoreAddress Address of OmniCore on OmniCoin L1
     * @return _chainId Chain ID of OmniCoin L1
     * @return _rpcUrl RPC URL for OmniCoin L1
     */
    function getOmniCoreInfo()
        external
        view
        returns (
            address _omniCoreAddress,
            uint256 _chainId,
            string memory _rpcUrl
        )
    {
        return (omniCoreAddress, omniCoreChainId, omniCoreRpcUrl);
    }

    /**
     * @notice Check if a node is registered and active
     * @param nodeAddress Address to check
     * @return isActive Whether the node is active
     * @return nodeType Type of node (0, 1, or 2)
     */
    function isNodeActive(address nodeAddress) external view returns (bool isActive, uint8 nodeType) {
        NodeInfo storage info = nodeRegistry[nodeAddress];
        return (info.active, info.nodeType);
    }

    // ============================================================
    //              AVALANCHEGO PEER DISCOVERY FUNCTIONS
    // ============================================================

    /**
     * @notice Get all active gateway validators with full information
     * @dev Used by new validators to discover peers before starting avalanchego.
     *      Returns complete NodeInfo for each active gateway validator.
     * @return infos Array of NodeInfo structs for active gateway validators
     */
    function getActiveGatewayValidators() external view returns (NodeInfo[] memory infos) {
        uint256 count = 0;

        // Count active gateway validators
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (info.active && info.nodeType == 0) {
                ++count;
            }
        }

        // Allocate array
        infos = new NodeInfo[](count);
        uint256 index = 0;

        // Populate array
        for (uint256 i = 0; i < registeredNodes.length && index < count; ++i) {
            address addr = registeredNodes[i];
            NodeInfo storage info = nodeRegistry[addr];
            if (info.active && info.nodeType == 0) {
                infos[index] = info;
                ++index;
            }
        }

        return infos;
    }

    /**
     * @notice Get bootstrap peer list in avalanchego format
     * @dev Returns formatted strings for direct use in avalanchego CLI flags.
     *      Only includes gateway validators with complete peer discovery info.
     * @return ips Comma-separated IP:port list for --bootstrap-ips flag
     * @return ids Comma-separated NodeID list for --bootstrap-ids flag
     * @return count Number of valid peers found
     */
    function getAvalancheBootstrapPeers()
        external
        view
        returns (
            string memory ips,
            string memory ids,
            uint256 count
        )
    {
        // First pass: count valid peers (gateway validators with peer discovery info)
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (
                info.active &&
                info.nodeType == 0 &&
                bytes(info.publicIp).length > 0 &&
                bytes(info.nodeId).length > 0 &&
                info.stakingPort > 0
            ) {
                ++count;
            }
        }

        if (count == 0) {
            return ("", "", 0);
        }

        // Second pass: build comma-separated strings
        // Note: This is gas-intensive but acceptable for view function
        bool first = true;
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (
                info.active &&
                info.nodeType == 0 &&
                bytes(info.publicIp).length > 0 &&
                bytes(info.nodeId).length > 0 &&
                info.stakingPort > 0
            ) {
                if (first) {
                    ips = string.concat(info.publicIp, ":", _uint16ToString(info.stakingPort));
                    ids = info.nodeId;
                    first = false;
                } else {
                    ips = string.concat(ips, ",", info.publicIp, ":", _uint16ToString(info.stakingPort));
                    ids = string.concat(ids, ",", info.nodeId);
                }
            }
        }

        return (ips, ids, count);
    }

    /**
     * @notice Get extended node information including peer discovery fields
     * @param nodeAddress Address of the node
     * @return info Complete NodeInfo struct
     */
    function getNodeInfoExtended(address nodeAddress) external view returns (NodeInfo memory info) {
        return nodeRegistry[nodeAddress];
    }

    // ============================================================
    //                    INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Internal node registration logic
     * @param multiaddr libp2p multiaddr
     * @param httpEndpoint HTTP endpoint URL
     * @param wsEndpoint WebSocket endpoint URL
     * @param region Geographic region
     * @param nodeType Node type (0=gateway, 1=computation, 2=listing)
     * @param avalancheRpcEndpoint RPC endpoint for OmniCoin L1
     * @param stakingPort Avalanchego staking port
     * @param publicIp Public IP address
     * @param nodeId TLS-derived NodeID
     */
    function _registerNodeInternal(
        string calldata multiaddr,
        string calldata httpEndpoint,
        string calldata wsEndpoint,
        string calldata region,
        uint8 nodeType,
        string memory avalancheRpcEndpoint,
        uint16 stakingPort,
        string memory publicIp,
        string memory nodeId
    ) internal {
        if (nodeType > 2) revert InvalidNodeType();
        if (bytes(httpEndpoint).length == 0) revert InvalidParameter();
        // multiaddr is required for gateway validators (nodeType 0) for P2P bootstrap
        if (nodeType == 0 && bytes(multiaddr).length == 0) revert InvalidParameter();

        NodeInfo storage info = nodeRegistry[msg.sender];
        bool isNew = bytes(info.httpEndpoint).length == 0;

        // If first time registration, add to array
        if (isNew) {
            nodeIndex[msg.sender] = registeredNodes.length;
            registeredNodes.push(msg.sender);
        }

        // Update active count if status changes
        if (!info.active && nodeType < 3) {
            ++activeNodeCounts[nodeType];
        } else if (info.active && info.nodeType != nodeType && info.nodeType < 3) {
            // Node type changed - update counts
            --activeNodeCounts[info.nodeType];
            ++activeNodeCounts[nodeType];
        }

        // Update node info (following struct field order for clarity)
        // Slot 1 packed fields
        info.active = true;
        info.nodeType = nodeType;
        info.stakingPort = stakingPort;
        info.nodeAddress = msg.sender;
        // Slot 2
        info.lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        // String fields
        info.multiaddr = multiaddr;
        info.httpEndpoint = httpEndpoint;
        info.wsEndpoint = wsEndpoint;
        info.region = region;
        info.avalancheRpcEndpoint = avalancheRpcEndpoint;
        info.publicIp = publicIp;
        info.nodeId = nodeId;

        emit NodeRegistered(msg.sender, nodeType, httpEndpoint, isNew);
    }

    /**
     * @notice Convert uint16 to string
     * @dev Used for building IP:port strings
     * @param value The uint16 value to convert
     * @return result String representation
     */
    function _uint16ToString(uint16 value) internal pure returns (string memory result) {
        if (value == 0) {
            return "0";
        }

        uint16 temp = value;
        uint256 digits;
        while (temp != 0) {
            ++digits;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            --digits;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
