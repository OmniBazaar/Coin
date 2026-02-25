// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOmniCore
 * @author OmniBazaar Team
 * @notice Interface for OmniCore contract
 * @dev Core validator registry, staking, and settlement for OmniBazaar
 */
interface IOmniCore {
    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a node is registered
    /// @param wallet Node wallet address
    /// @param nodeType Type of node (gateway, computation, listing)
    /// @param endpoint Node endpoint URL
    event NodeRegistered(
        address indexed wallet,
        string nodeType,
        string endpoint
    );

    /// @notice Emitted when a node is deactivated
    /// @param wallet Node wallet address
    event NodeDeactivated(address indexed wallet);

    /// @notice Emitted when tokens are staked
    /// @param user User address
    /// @param amount Amount staked
    /// @param duration Lock duration in seconds
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 duration
    );

    /// @notice Emitted when tokens are unlocked
    /// @param user User address
    /// @param amount Amount unlocked
    /// @param rewards Rewards earned
    event Unlocked(
        address indexed user,
        uint256 amount,
        uint256 rewards
    );

    /// @notice Emitted when validator status changes
    /// @param validator Validator address
    /// @param isValidator New validator status
    event ValidatorStatusChanged(
        address indexed validator,
        bool isValidator
    );

    /// @notice Emitted when master root is updated
    /// @param rootHash New root hash
    /// @param timestamp Update timestamp
    event MasterRootUpdated(
        bytes32 indexed rootHash,
        uint256 timestamp
    );

    // ═══════════════════════════════════════════════════════════════════════
    //                         NODE REGISTRY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Register a new node
    /// @param nodeType Type of node (gateway, computation, listing)
    /// @param endpoint Node endpoint URL
    function registerNode(string calldata nodeType, string calldata endpoint) external;

    /// @notice Deactivate own node
    function deactivateNode() external;

    /// @notice Admin deactivate a node
    /// @param wallet Node wallet address
    function adminDeactivateNode(address wallet) external;

    /// @notice Get node information
    /// @param wallet Node wallet address
    /// @return NodeInfo struct
    function getNodeInfo(address wallet) external view returns (NodeInfo memory);

    /// @notice Get all active nodes
    /// @return Array of active node addresses
    function getActiveNodes() external view returns (address[] memory);

    /// @notice Get active node count
    /// @return Number of active nodes
    function getActiveNodeCount() external view returns (uint256);

    /// @notice Get total node count (including inactive)
    /// @return Total number of nodes
    function getTotalNodeCount() external view returns (uint256);

    /// @notice Get active nodes with heartbeat within time window
    /// @param timeWindow Time window in seconds
    /// @return Array of active node addresses
    function getActiveNodesWithinTime(uint256 timeWindow) external view returns (address[] memory);

    // ═══════════════════════════════════════════════════════════════════════
    //                         VALIDATOR MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Check if address is a validator
    /// @param validator Address to check
    /// @return True if validator
    function isValidator(address validator) external view returns (bool);

    /// @notice Set validator status (admin only)
    /// @param validator Validator address
    /// @param status New validator status
    function setValidator(address validator, bool status) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STAKING
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Stake tokens
    /// @param amount Amount to stake
    /// @param duration Lock duration in seconds
    function stake(uint256 amount, uint256 duration) external;

    /// @notice Unlock staked tokens
    function unlock() external;

    /// @notice Get stake information
    /// @param user User address
    /// @return Stake struct with staking details
    function getStake(address user) external view returns (Stake memory);

    // ═══════════════════════════════════════════════════════════════════════
    //                         DEX INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposit tokens to DEX
    /// @param amount Amount to deposit
    function depositToDEX(uint256 amount) external;

    /// @notice Withdraw tokens from DEX
    /// @param amount Amount to withdraw
    function withdrawFromDEX(uint256 amount) external;

    /// @notice Get DEX balance
    /// @param user User address
    /// @return Balance in DEX
    function getDEXBalance(address user) external view returns (uint256);

    /// @notice Settle a DEX trade
    /// @param maker Maker address
    /// @param taker Taker address
    /// @param makerAmount Amount from maker
    /// @param takerAmount Amount from taker
    /// @param makerFee Fee from maker
    /// @param takerFee Fee from taker
    function settleDEXTrade(
        address maker,
        address taker,
        uint256 makerAmount,
        uint256 takerAmount,
        uint256 makerFee,
        uint256 takerFee
    ) external;

    /// @notice Batch settle DEX trades
    /// @param makers Array of maker addresses
    /// @param takers Array of taker addresses
    /// @param makerAmounts Array of maker amounts
    /// @param takerAmounts Array of taker amounts
    /// @param makerFees Array of maker fees
    /// @param takerFees Array of taker fees
    function batchSettleDEX(
        address[] calldata makers,
        address[] calldata takers,
        uint256[] calldata makerAmounts,
        uint256[] calldata takerAmounts,
        uint256[] calldata makerFees,
        uint256[] calldata takerFees
    ) external;

    /// @notice Distribute DEX fees
    /// @param validators Array of validators
    /// @param amounts Array of fee amounts
    function distributeDEXFees(
        address[] calldata validators,
        uint256[] calldata amounts
    ) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                         MERKLE ROOT (LEGACY)
    // ═══════════════════════════════════════════════════════════════════════

    // NOTE: updateMasterRoot() and verifyProof() removed — merkle root system deprecated.
    // See StakingRewardPool.sol for trustless reward computation.

    // ═══════════════════════════════════════════════════════════════════════
    //                         LEGACY MIGRATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Register legacy users for migration
    /// @param users Array of legacy user addresses
    /// @param balances Array of legacy balances
    /// @param merkleRoots Array of merkle roots for claims
    function registerLegacyUsers(
        address[] calldata users,
        uint256[] calldata balances,
        bytes32[] calldata merkleRoots
    ) external;

    /// @notice Claim legacy balance with M-of-N validator signatures
    /// @param username Legacy username
    /// @param claimAddress Address to receive the tokens
    /// @param nonce Unique nonce to prevent replay
    /// @param signatures Array of validator signatures authorizing the claim
    function claimLegacyBalance(
        string calldata username,
        address claimAddress,
        bytes32 nonce,
        bytes[] calldata signatures
    ) external;

    /// @notice Get legacy status for user
    /// @param user User address
    /// @return balance Legacy balance
    /// @return claimed Whether balance has been claimed
    function getLegacyStatus(address user) external view returns (uint256 balance, bool claimed);

    // ═══════════════════════════════════════════════════════════════════════
    //                         SERVICE REGISTRY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set service address
    /// @param serviceName Service name
    /// @param serviceAddress Service contract address
    function setService(string calldata serviceName, address serviceAddress) external;

    /// @notice Get service address
    /// @param serviceName Service name
    /// @return Service contract address
    function getService(string calldata serviceName) external view returns (address);

    // ═══════════════════════════════════════════════════════════════════════
    //                         USERNAME REGISTRY
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Check if username is available
    /// @param username Username to check
    /// @return True if username is available
    function isUsernameAvailable(string calldata username) external view returns (bool);
}
