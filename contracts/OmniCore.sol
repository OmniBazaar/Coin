// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OmniCore
 * @author OmniCoin Development Team
 * @notice Ultra-lean core contract consolidating registry, validators, and minimal staking
 * @dev Replaces OmniCoinRegistry, OmniCoinConfig, ValidatorRegistry, OmniCoinAccount, and KYCMerkleVerifier
 */
contract OmniCore is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Type declarations
    /// @notice Minimal stake information
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Node info for discovery
    struct NodeInfo {
        string multiaddr;      // libp2p multiaddr for P2P connections (e.g., "/ip4/1.2.3.4/tcp/14002/p2p/12D3...")
        string httpEndpoint;   // HTTP API endpoint
        string wsEndpoint;     // WebSocket endpoint
        string region;         // Geographic region
        uint8 nodeType;        // 0=gateway, 1=computation, 2=listing
        bool active;           // Whether node is currently active
        uint256 lastUpdate;    // Last update timestamp
    }

    // Constants
    /// @notice Admin role for governance operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role for Avalanche validators to update merkle roots
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    /// @notice Fee percentage for ODDAO (70% = 7000 basis points)
    uint256 public constant ODDAO_FEE_BPS = 7000;
    
    /// @notice Fee percentage for staking pool (20% = 2000 basis points)
    uint256 public constant STAKING_FEE_BPS = 2000;
    
    /// @notice Fee percentage for validator (10% = 1000 basis points)
    uint256 public constant VALIDATOR_FEE_BPS = 1000;
    
    /// @notice Total basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;
    
    // Immutable state variables
    /// @notice OmniCoin token address
    IERC20 public immutable OMNI_COIN;
    
    // State variables
    /// @notice Service registry mapping service names to addresses
    mapping(bytes32 => address) public services;
    
    /// @notice Validator registry for active validators
    mapping(address => bool) public validators;
    
    /// @notice Master merkle root covering ALL off-chain data
    bytes32 public masterRoot;
    
    /// @notice Last epoch when root was updated
    uint256 public lastRootUpdate;
    
    /// @notice User stakes - minimal on-chain data
    mapping(address => Stake) public stakes;
    
    /// @notice Total staked amount for security
    uint256 public totalStaked;
    
    /// @notice DEX balances for settlement (user => token => amount)
    mapping(address => mapping(address => uint256)) public dexBalances;
    
    /// @notice ODDAO address for receiving 70% of DEX fees
    address public oddaoAddress;
    
    /// @notice Staking pool address for receiving 20% of DEX fees
    address public stakingPoolAddress;
    
    // Node Discovery Registry State (added 2025-08-16)
    /// @notice Registry of node endpoints for discovery
    mapping(address => NodeInfo) public nodeRegistry;
    
    /// @notice Count of active nodes by type
    mapping(uint8 => uint256) public activeNodeCounts;
    
    /// @notice List of all registered node addresses
    address[] public registeredNodes;
    
    /// @notice Mapping to track node address index in array
    mapping(address => uint256) public nodeIndex;
    
    // Legacy Migration State (added 2025-08-06)
    /// @notice Reserved legacy usernames (username hash => reserved)
    mapping(bytes32 => bool) public legacyUsernames;
    
    /// @notice Legacy balances to be claimed (username hash => amount in 18 decimals)
    mapping(bytes32 => uint256) public legacyBalances;
    
    /// @notice Claimed legacy accounts (username hash => claim address)
    mapping(bytes32 => address) public legacyClaimed;
    
    /// @notice Total legacy tokens to distribute
    uint256 public totalLegacySupply;
    
    /// @notice Total legacy tokens claimed so far
    uint256 public totalLegacyClaimed;

    // Events
    /// @notice Emitted when a service is registered or updated
    /// @param name Service identifier
    /// @param serviceAddress Address of the service contract
    /// @param timestamp Block timestamp of update
    event ServiceUpdated(
        bytes32 indexed name,
        address indexed serviceAddress,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a validator is added or removed
    /// @param validator Address of the validator
    /// @param active Whether validator is active
    /// @param timestamp Block timestamp of change
    event ValidatorUpdated(
        address indexed validator,
        bool indexed active,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a legacy balance is claimed
    /// @param username Legacy username being claimed
    /// @param claimAddress Address receiving the tokens
    /// @param amount Amount of tokens claimed (18 decimals)
    /// @param timestamp Block timestamp of claim
    event LegacyBalanceClaimed(
        string indexed username,
        address indexed claimAddress,
        uint256 indexed amount,
        uint256 timestamp
    );
    
    /// @notice Emitted when legacy users are registered
    /// @param count Number of users registered
    /// @param totalAmount Total amount reserved for distribution
    event LegacyUsersRegistered(
        uint256 indexed count,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when master merkle root is updated
    /// @param newRoot New merkle root hash
    /// @param epoch Epoch number for this update
    /// @param timestamp Block timestamp of update
    event MasterRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed timestamp
    );

    /// @notice Emitted when tokens are staked
    /// @param user Address of the staker
    /// @param amount Amount of tokens staked
    /// @param tier Staking tier selected
    /// @param duration Lock duration in seconds
    event TokensStaked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed tier,
        uint256 duration
    );

    /// @notice Emitted when tokens are unlocked
    /// @param user Address of the staker
    /// @param amount Amount of tokens unlocked
    /// @param timestamp Block timestamp of unlock
    event TokensUnlocked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed timestamp
    );

    /// @notice Emitted when DEX trade is settled
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param token Token traded
    /// @param amount Amount traded
    /// @param orderId Off-chain order ID
    event DEXSettlement(
        address indexed buyer,
        address indexed seller,
        address indexed token,
        uint256 amount,
        bytes32 orderId
    );
    
    /// @notice Emitted when batch settlement occurs
    /// @param batchId Batch identifier
    /// @param count Number of settlements
    event BatchSettlement(
        bytes32 indexed batchId,
        uint256 indexed count
    );

    /// @notice Emitted when a node registers or updates its endpoints
    /// @param nodeAddress Address of the node
    /// @param nodeType Type of node (0=gateway, 1=computation, 2=listing)
    /// @param httpEndpoint HTTP endpoint URL
    /// @param active Whether node is active
    event NodeRegistered(
        address indexed nodeAddress,
        uint8 indexed nodeType,
        string httpEndpoint,
        bool indexed active
    );

    /// @notice Emitted when a node is deactivated
    /// @param nodeAddress Address of the node
    /// @param reason Reason for deactivation
    event NodeDeactivated(
        address indexed nodeAddress,
        string reason
    );

    // Custom errors
    error InvalidAddress();
    error InvalidAmount();
    error InvalidSignature();
    error StakeNotFound();
    error StakeLocked();
    error InvalidProof();
    error Unauthorized();

    /**
     * @notice Initialize OmniCore with admin and token
     * @param admin Address to grant admin role
     * @param _omniCoin Address of OmniCoin token
     * @param _oddaoAddress ODDAO fee recipient (70% of fees)
     * @param _stakingPoolAddress Staking pool fee recipient (20% of fees)
     */
    constructor(
        address admin, 
        address _omniCoin,
        address _oddaoAddress,
        address _stakingPoolAddress
    ) {
        if (admin == address(0) || _omniCoin == address(0) || 
            _oddaoAddress == address(0) || _stakingPoolAddress == address(0)) {
            revert InvalidAddress();
        }
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        OMNI_COIN = IERC20(_omniCoin);
        oddaoAddress = _oddaoAddress;
        stakingPoolAddress = _stakingPoolAddress;
    }

    /**
     * @notice Register or update a service in the registry
     * @dev Only admin can update services
     * @param name Service identifier
     * @param serviceAddress Address of the service contract
     */
    function setService(bytes32 name, address serviceAddress) external onlyRole(ADMIN_ROLE) {
        if (serviceAddress == address(0)) revert InvalidAddress();
        services[name] = serviceAddress;
        emit ServiceUpdated(name, serviceAddress, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Add or remove a validator
     * @dev Only admin can manage validators
     * @param validator Address of the validator
     * @param active Whether validator should be active
     */
    function setValidator(address validator, bool active) external onlyRole(ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        validators[validator] = active;
        
        if (active) {
            _grantRole(AVALANCHE_VALIDATOR_ROLE, validator);
        } else {
            _revokeRole(AVALANCHE_VALIDATOR_ROLE, validator);
        }
        
        emit ValidatorUpdated(validator, active, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Update the master merkle root
     * @dev Only Avalanche validators can update the root
     * @param newRoot New merkle root hash
     * @param epoch Epoch number for this update
     */
    function updateMasterRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        masterRoot = newRoot;
        lastRootUpdate = epoch;
        emit MasterRootUpdated(newRoot, epoch, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // =============================================================================
    // Node Discovery Registry Functions (Added 2025-08-16)
    // =============================================================================

    /**
     * @notice Register or update node endpoints for discovery
     * @dev Nodes self-register their endpoints, no expensive heartbeats required
     * @param multiaddr libp2p multiaddr for P2P connections (e.g., "/ip4/1.2.3.4/tcp/14002/p2p/12D3...")
     * @param httpEndpoint HTTP endpoint URL (e.g. "https://node1.omnibazaar.com")
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
        if (nodeType > 2) revert InvalidAmount();
        if (bytes(httpEndpoint).length == 0) revert InvalidAddress();
        // multiaddr is required for gateway validators (nodeType 0) for P2P bootstrap
        if (nodeType == 0 && bytes(multiaddr).length == 0) revert InvalidAddress();

        NodeInfo storage info = nodeRegistry[msg.sender];

        // If first time registration, add to array
        if (bytes(info.httpEndpoint).length == 0) {
            nodeIndex[msg.sender] = registeredNodes.length;
            registeredNodes.push(msg.sender);
        }

        // Update active count if status changes
        if (!info.active && nodeType < 3) {
            ++activeNodeCounts[nodeType];
        }

        // Update node info
        info.multiaddr = multiaddr;
        info.httpEndpoint = httpEndpoint;
        info.wsEndpoint = wsEndpoint;
        info.region = region;
        info.nodeType = nodeType;
        info.active = true;
        info.lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time

        emit NodeRegistered(msg.sender, nodeType, httpEndpoint, true);
    }

    /**
     * @notice Deactivate a node (self-deactivation)
     * @dev Nodes can deactivate themselves when going offline
     * @param reason Reason for deactivation
     */
    function deactivateNode(string calldata reason) external {
        NodeInfo storage info = nodeRegistry[msg.sender];
        
        if (!info.active) revert InvalidAddress();
        
        info.active = false;
        
        // Update active count
        if (info.nodeType < 3) {
            if (activeNodeCounts[info.nodeType] > 0) {
                --activeNodeCounts[info.nodeType];
            }
        }
        
        emit NodeDeactivated(msg.sender, reason);
    }

    /**
     * @notice Admin force-deactivate a node
     * @dev Only admin can force deactivate misbehaving nodes
     * @param nodeAddress Address of the node to deactivate
     * @param reason Reason for deactivation
     */
    function adminDeactivateNode(
        address nodeAddress,
        string calldata reason
    ) external onlyRole(ADMIN_ROLE) {
        NodeInfo storage info = nodeRegistry[nodeAddress];

        if (!info.active) revert InvalidAddress();

        info.active = false;

        // Update active count
        if (info.nodeType < 3) {
            if (activeNodeCounts[info.nodeType] > 0) {
                --activeNodeCounts[info.nodeType];
            }
        }

        emit NodeDeactivated(nodeAddress, reason);
    }

    /**
     * @notice Clear all stale node registrations (TEST/DEV ONLY)
     * @dev Admin-only function to clean up old validator entries from testing
     * @param olderThanSeconds Deactivate nodes not updated in this many seconds (e.g., 300 for 5 minutes)
     * @return deactivatedCount Number of nodes deactivated
     */
    function clearStaleNodes(uint256 olderThanSeconds) external onlyRole(ADMIN_ROLE) returns (uint256 deactivatedCount) {
        uint256 cutoff = block.timestamp - olderThanSeconds; // solhint-disable-line not-rely-on-time
        deactivatedCount = 0;

        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            address addr = registeredNodes[i];
            NodeInfo storage info = nodeRegistry[addr];

            if (info.active && info.lastUpdate < cutoff) {
                info.active = false;

                // Update active count
                if (info.nodeType < 3 && activeNodeCounts[info.nodeType] > 0) {
                    --activeNodeCounts[info.nodeType];
                }

                ++deactivatedCount;
                emit NodeDeactivated(addr, "Stale - cleared by admin");
            }
        }

        return deactivatedCount;
    }

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
        if (nodeType > 2) revert InvalidAmount();
        
        uint256 count = 0;
        uint256 maxCount = limit;
        if (maxCount > registeredNodes.length) {
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
        if (nodeType > 2) revert InvalidAmount();
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
     * @dev Returns nodes that have been active within the specified time period
     * @param nodeType Type of nodes to retrieve (0=gateway, 1=computation, 2=listing)
     * @param timeWindowSeconds Time window in seconds (e.g., 86400 for last 24 hours)
     * @return addresses Array of node addresses
     * @return infos Array of node information structs
     */
    function getActiveNodesWithinTime(
        uint8 nodeType,
        uint256 timeWindowSeconds
    ) external view returns (
        address[] memory addresses,
        NodeInfo[] memory infos
    ) {
        if (nodeType > 2) revert InvalidAmount();

        uint256 cutoff = block.timestamp - timeWindowSeconds; // solhint-disable-line not-rely-on-time
        uint256 count = 0;

        // First pass: count active nodes within time window
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            NodeInfo storage info = nodeRegistry[registeredNodes[i]];
            if (info.active && info.nodeType == nodeType && info.lastUpdate >= cutoff) {
                ++count;
            }
        }

        // Allocate arrays with exact size
        addresses = new address[](count);
        infos = new NodeInfo[](count);
        uint256 index = 0;

        // Second pass: populate arrays
        for (uint256 i = 0; i < registeredNodes.length; ++i) {
            address addr = registeredNodes[i];
            NodeInfo storage info = nodeRegistry[addr];
            if (info.active && info.nodeType == nodeType && info.lastUpdate >= cutoff) {
                addresses[index] = addr;
                infos[index] = info;
                ++index;
            }
        }

        return (addresses, infos);
    }

    /**
     * @notice Stake tokens with minimal on-chain data
     * @dev Locks tokens on-chain, calculations done off-chain
     * @param amount Amount of tokens to stake
     * @param tier Staking tier (for off-chain calculations)
     * @param duration Lock duration in seconds
     */
    function stake(
        uint256 amount,
        uint256 tier,
        uint256 duration
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (stakes[msg.sender].active) revert InvalidAmount();
        
        // Transfer tokens from user
        OMNI_COIN.safeTransferFrom(msg.sender, address(this), amount);
        
        // Store minimal stake data
        stakes[msg.sender] = Stake({
            amount: amount,
            tier: tier,
            duration: duration,
            lockTime: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            active: true
        });
        
        totalStaked += amount;
        
        emit TokensStaked(msg.sender, amount, tier, duration);
    }

    /**
     * @notice Unlock staked tokens after lock period
     * @dev Simple unlock without reward calculation (done off-chain)
     */
    function unlock() external nonReentrant {
        Stake storage userStake = stakes[msg.sender];
        
        if (!userStake.active) revert StakeNotFound();
        if (block.timestamp < userStake.lockTime) revert StakeLocked(); // solhint-disable-line not-rely-on-time
        
        uint256 amount = userStake.amount;
        
        // Clear stake
        userStake.active = false;
        userStake.amount = 0;
        totalStaked -= amount;
        
        // Transfer tokens back
        OMNI_COIN.safeTransfer(msg.sender, amount);
        
        emit TokensUnlocked(msg.sender, amount, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Unlock with rewards verified by merkle proof
     * @dev Validator provides proof of rewards earned
     * @param user Address of the staker
     * @param totalAmount Total amount including rewards
     * @param proof Merkle proof for reward verification
     */
    function unlockWithRewards(
        address user,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        Stake storage userStake = stakes[user];
        
        if (!userStake.active) revert StakeNotFound();
        if (totalAmount < userStake.amount) revert InvalidAmount();
        
        // Verify merkle proof (implementation depends on MasterMerkleEngine)
        if (!verifyProof(user, totalAmount, proof)) revert InvalidProof();
        
        // Clear stake
        uint256 baseAmount = userStake.amount;
        userStake.active = false;
        userStake.amount = 0;
        totalStaked -= baseAmount;
        
        // Transfer total amount (base + rewards)
        OMNI_COIN.safeTransfer(user, totalAmount);
        
        emit TokensUnlocked(user, totalAmount, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // =============================================================================
    // DEX Settlement Functions (Ultra-Minimal)
    // =============================================================================
    
    /**
     * @notice Settle a DEX trade
     * @dev All order matching happens off-chain in validators
     * @param buyer Buyer address
     * @param seller Seller address
     * @param token Token being traded
     * @param amount Amount of tokens
     * @param orderId Off-chain order identifier
     */
    function settleDEXTrade(
        address buyer,
        address seller,
        address token,
        uint256 amount,
        bytes32 orderId
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        if (buyer == address(0) || seller == address(0) || token == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) revert InvalidAmount();
        
        // Simple balance transfer
        if (dexBalances[seller][token] < amount) revert InvalidAmount();
        
        dexBalances[seller][token] -= amount;
        dexBalances[buyer][token] += amount;
        
        emit DEXSettlement(buyer, seller, token, amount, orderId);
    }
    
    /**
     * @notice Batch settle multiple DEX trades
     * @dev Efficient batch processing for gas optimization
     * @param buyers Array of buyer addresses
     * @param sellers Array of seller addresses
     * @param tokens Array of token addresses
     * @param amounts Array of amounts
     * @param batchId Batch identifier
     */
    function batchSettleDEX(
        address[] calldata buyers,
        address[] calldata sellers,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32 batchId
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        uint256 length = buyers.length;
        if (length == 0 || length != sellers.length || 
            length != tokens.length || length != amounts.length) {
            revert InvalidAmount();
        }
        
        for (uint256 i = 0; i < length; ++i) {
            if (dexBalances[sellers[i]][tokens[i]] > amounts[i] || dexBalances[sellers[i]][tokens[i]] == amounts[i]) {
                dexBalances[sellers[i]][tokens[i]] -= amounts[i];
                dexBalances[buyers[i]][tokens[i]] += amounts[i];
            }
        }
        
        emit BatchSettlement(batchId, length);
    }
    
    /**
     * @notice Distribute DEX fees
     * @dev Called by validators to distribute fees according to tokenomics
     * @param token Fee token
     * @param totalFee Total fee amount
     * @param validator Validator processing the transaction
     */
    function distributeDEXFees(
        address token,
        uint256 totalFee,
        address validator
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        if (totalFee == 0) return;
        
        // Calculate fee splits using basis points for precision
        uint256 oddaoFee = (totalFee * ODDAO_FEE_BPS) / BASIS_POINTS;
        uint256 stakingFee = (totalFee * STAKING_FEE_BPS) / BASIS_POINTS;
        uint256 validatorFee = totalFee - oddaoFee - stakingFee; // Remainder to avoid rounding loss
        
        if (oddaoFee > 0) {
            dexBalances[oddaoAddress][token] += oddaoFee;
        }
        if (stakingFee > 0) {
            dexBalances[stakingPoolAddress][token] += stakingFee;
        }
        if (validatorFee > 0) {
            dexBalances[validator][token] += validatorFee;
        }
    }
    
    /**
     * @notice Deposit tokens to DEX
     * @dev Simple deposit for trading
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToDEX(address token, uint256 amount) external nonReentrant {
        if (token == address(0) || amount == 0) revert InvalidAmount();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        dexBalances[msg.sender][token] += amount;
    }
    
    /**
     * @notice Withdraw tokens from DEX
     * @dev Simple withdrawal
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawFromDEX(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (dexBalances[msg.sender][token] < amount) revert InvalidAmount();
        
        dexBalances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Get service address by name
     * @param name Service identifier
     * @return serviceAddress Address of the service
     */
    function getService(bytes32 name) external view returns (address serviceAddress) {
        return services[name];
    }

    /**
     * @notice Check if an address is an active validator
     * @param validator Address to check
     * @return active Whether the address is an active validator
     */
    function isValidator(address validator) external view returns (bool active) {
        return validators[validator];
    }

    /**
     * @notice Get stake information for a user
     * @param user Address of the staker
     * @return Stake information
     */
    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }
    
    /**
     * @notice Get DEX balance for a user
     * @param user User address
     * @param token Token address
     * @return balance DEX balance
     */
    function getDEXBalance(address user, address token) external view returns (uint256 balance) {
        return dexBalances[user][token];
    }

    /**
     * @notice Verify a merkle proof against the master root
     * @dev Simplified verification - actual implementation in validators
     * @param user User address
     * @param amount Amount to verify
     * @param proof Merkle proof path
     * @return valid Whether the proof is valid
     */
    function verifyProof(
        address user,
        uint256 amount,
        bytes32[] calldata proof
    ) public view returns (bool valid) {
        // Simplified verification - actual logic in MasterMerkleEngine
        bytes32 leaf = keccak256(abi.encodePacked(user, amount));
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement || computedHash == proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == masterRoot;
    }

    // =============================================================================
    // Legacy Migration Functions (Added 2025-08-06)
    // =============================================================================
    
    /**
     * @notice Register legacy users and their balances
     * @dev Only callable by admin during initialization
     * @param usernames Array of legacy usernames to reserve
     * @param balances Array of balances in 18 decimal precision
     */
    function registerLegacyUsers(
        string[] calldata usernames,
        uint256[] calldata balances
    ) external onlyRole(ADMIN_ROLE) {
        if (usernames.length != balances.length) revert InvalidAmount();
        if (usernames.length > 100) revert InvalidAmount(); // Gas limit protection
        
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < usernames.length; ++i) {
            bytes32 usernameHash = keccak256(abi.encodePacked(usernames[i]));
            
            // Skip if already registered
            if (legacyUsernames[usernameHash]) continue;
            
            // Reserve username and store balance
            legacyUsernames[usernameHash] = true;
            legacyBalances[usernameHash] = balances[i];
            totalAmount += balances[i];
        }
        
        totalLegacySupply += totalAmount;
        
        emit LegacyUsersRegistered(usernames.length, totalAmount);
    }
    
    /**
     * @notice Claim legacy balance after off-chain validation
     * @dev Validators verify legacy credentials off-chain before authorizing claim
     * @param username Legacy username
     * @param claimAddress Address to receive the tokens
     * @param nonce Unique nonce to prevent replay
     * @param signature Validator signature authorizing the claim
     */
    function claimLegacyBalance(
        string calldata username,
        address claimAddress,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant {
        if (claimAddress == address(0)) revert InvalidAddress();
        
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        
        // Check username is registered and not claimed
        if (!legacyUsernames[usernameHash]) revert InvalidAddress();
        if (legacyClaimed[usernameHash] != address(0)) revert InvalidAmount();
        
        // Verify validator signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            username,
            claimAddress,
            nonce,
            address(this),
            block.chainid
        ));
        
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        
        address signer = _recoverSigner(ethSignedMessageHash, signature);
        if (!validators[signer]) revert InvalidSignature();
        
        // Get balance and mark as claimed
        uint256 amount = legacyBalances[usernameHash];
        legacyClaimed[usernameHash] = claimAddress;
        totalLegacyClaimed += amount;
        
        // Transfer tokens (must be pre-minted to this contract)
        OMNI_COIN.safeTransfer(claimAddress, amount);
        
        emit LegacyBalanceClaimed(
            username,
            claimAddress,
            amount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Check if a legacy username is available
     * @param username Username to check
     * @return available True if not reserved by legacy system
     */
    function isUsernameAvailable(string calldata username) external view returns (bool available) {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        return !legacyUsernames[usernameHash];
    }
    
    /**
     * @notice Get legacy migration status for a username
     * @param username Legacy username
     * @return reserved Whether username is reserved
     * @return balance Legacy balance to claim
     * @return claimed Whether balance has been claimed
     * @return claimAddress Address that claimed (if any)
     */
    function getLegacyStatus(string calldata username) external view returns (
        bool reserved,
        uint256 balance,
        bool claimed,
        address claimAddress
    ) {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        reserved = legacyUsernames[usernameHash];
        balance = legacyBalances[usernameHash];
        claimAddress = legacyClaimed[usernameHash];
        claimed = (claimAddress != address(0));
    }
    
    /**
     * @notice Internal function to recover signer from signature
     * @param messageHash Hash of the signed message
     * @param signature Signature bytes
     * @return Recovered signer address
     */
    function _recoverSigner(
        bytes32 messageHash,
        bytes memory signature
    ) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignature();
        
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        return ecrecover(messageHash, v, r, s);
    }
}