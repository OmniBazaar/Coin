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

    // Constants
    /// @notice Admin role for governance operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role for Avalanche validators to update merkle roots
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
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

    // Events
    /// @notice Emitted when a service is registered or updated
    /// @param name Service identifier
    /// @param serviceAddress Address of the service contract
    /// @param timestamp Block timestamp of update
    event ServiceUpdated(
        bytes32 indexed name,
        address indexed serviceAddress,
        uint256 timestamp
    );

    /// @notice Emitted when a validator is added or removed
    /// @param validator Address of the validator
    /// @param active Whether validator is active
    /// @param timestamp Block timestamp of change
    event ValidatorUpdated(
        address indexed validator,
        bool indexed active,
        uint256 timestamp
    );

    /// @notice Emitted when master merkle root is updated
    /// @param newRoot New merkle root hash
    /// @param epoch Epoch number for this update
    /// @param timestamp Block timestamp of update
    event MasterRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 timestamp
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
        uint256 timestamp
    );

    // Custom errors
    error InvalidAddress();
    error InvalidAmount();
    error StakeNotFound();
    error StakeLocked();
    error InvalidProof();
    error Unauthorized();

    /**
     * @notice Initialize OmniCore with admin and token
     * @param admin Address to grant admin role
     * @param _omniCoin Address of OmniCoin token
     */
    constructor(address admin, address _omniCoin) {
        if (admin == address(0) || _omniCoin == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        OMNI_COIN = IERC20(_omniCoin);
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
}