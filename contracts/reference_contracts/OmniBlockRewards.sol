// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {IOmniCoin} from "./interfaces/IOmniCoin.sol";

/**
 * @title OmniBlockRewards
 * @author OmniCoin Development Team
 * @notice Manages block reward distribution between stakers, ODDAO and validators
 * @dev Implements proper distribution: staking rewards first, then 10% ODDAO, remainder to validator
 */
contract OmniBlockRewards is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for block producers who can claim rewards
    bytes32 public constant BLOCK_PRODUCER_ROLE = keccak256("BLOCK_PRODUCER_ROLE");
    
    /// @notice Role for staking pool to withdraw rewards
    bytes32 public constant STAKING_POOL_ROLE = keccak256("STAKING_POOL_ROLE");
    
    /// @notice ODDAO's share of remaining block rewards after staking (10%)
    uint256 public constant ODDAO_SHARE_BPS = 1000; // 10% in basis points
    
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Minimum block interval between rewards
    uint256 public constant MIN_BLOCK_INTERVAL = 1;
    
    /// @notice Approximate blocks per year (assuming 2 second blocks)
    uint256 public constant BLOCKS_PER_YEAR = 15_768_000; // 365.25 * 24 * 60 * 60 / 2
    
    /// @notice Block reward amount per block (configurable)
    uint256 public blockRewardAmount;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Last block number that received rewards
    uint256 public lastRewardedBlock;
    
    /// @notice Total rewards distributed
    uint256 public totalRewardsDistributed;
    
    /// @notice Total rewards to ODDAO
    uint256 public totalODDAORewards;
    
    /// @notice Total rewards to validators
    uint256 public totalValidatorRewards;
    
    /// @notice Total rewards to staking pool
    uint256 public totalStakingRewards;
    
    /// @notice Accumulated ODDAO rewards pending withdrawal
    uint256 public pendingODDAORewards;
    
    /// @notice Accumulated staking pool rewards pending withdrawal
    uint256 public pendingStakingRewards;
    
    /// @notice Validator rewards by address
    mapping(address => uint256) public validatorRewards;
    
    /// @notice Total rewards claimed by validators
    mapping(address => uint256) public validatorRewardsClaimed;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when block rewards are distributed
    /// @param blockNumber Block number that received rewards
    /// @param validator Address of the validator who produced the block
    /// @param validatorReward Amount given to validator
    /// @param oddaoReward Amount allocated to ODDAO
    /// @param stakingReward Amount allocated to staking pool
    /// @param totalReward Total reward distributed
    event BlockRewardDistributed(
        uint256 indexed blockNumber,
        address indexed validator,
        uint256 indexed validatorReward,
        uint256 oddaoReward,
        uint256 stakingReward,
        uint256 totalReward
    );
    
    /// @notice Emitted when validator claims their rewards
    /// @param validator Address of the validator claiming rewards
    /// @param amount Amount of rewards claimed
    event ValidatorRewardClaimed(
        address indexed validator,
        uint256 indexed amount
    );
    
    /// @notice Emitted when ODDAO rewards are withdrawn
    /// @param recipient Address receiving the ODDAO rewards
    /// @param amount Amount of rewards withdrawn
    event ODDAORewardWithdrawn(
        address indexed recipient,
        uint256 indexed amount
    );
    
    /// @notice Emitted when staking rewards are withdrawn
    /// @param recipient Address receiving the staking rewards
    /// @param amount Amount of rewards withdrawn
    event StakingRewardWithdrawn(
        address indexed recipient,
        uint256 indexed amount
    );
    
    /// @notice Emitted when block reward amount is updated
    /// @param oldAmount Previous block reward amount
    /// @param newAmount New block reward amount
    event BlockRewardAmountUpdated(
        uint256 indexed oldAmount,
        uint256 indexed newAmount
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidBlockNumber();
    error NoRewardAvailable();
    error TransferFailed();
    error InvalidAmount();
    error AlreadyRewarded();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the block rewards contract
     * @param _registry Registry contract address
     * @param _blockRewardAmount Initial block reward amount
     */
    constructor(
        address _registry,
        uint256 _blockRewardAmount
    ) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        blockRewardAmount = _blockRewardAmount;
        lastRewardedBlock = block.number;
    }
    
    // =============================================================================
    // BLOCK REWARD FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Process block reward for the current block
     * @dev Only callable by authorized block producers
     * @param validator Address of the validator who produced the block
     * @param totalStakingRewardsForBlock Pre-calculated staking rewards for this block
     */
    function processBlockReward(address validator, uint256 totalStakingRewardsForBlock) 
        external 
        onlyRole(BLOCK_PRODUCER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        uint256 currentBlock = block.number;
        
        // Ensure we haven't already rewarded this block
        if (currentBlock < lastRewardedBlock + 1) revert AlreadyRewarded();
        
        // Get total block reward
        uint256 totalReward = blockRewardAmount;
        
        // Ensure staking rewards don't exceed block reward
        if (totalStakingRewardsForBlock > totalReward) revert InvalidAmount();
        
        // Step 1: Deduct staking rewards
        uint256 remainingAfterStaking = totalReward - totalStakingRewardsForBlock;
        
        // Step 2: Calculate ODDAO share (10% of remaining)
        uint256 oddaoReward = (remainingAfterStaking * ODDAO_SHARE_BPS) / BASIS_POINTS;
        
        // Step 3: Remainder goes to validator
        uint256 validatorReward = remainingAfterStaking - oddaoReward;
        
        // Get OmniCoin contract
        address omniCoin = registry.getContract(keccak256("OMNICOIN"));
        
        // Mint rewards
        IOmniCoin(omniCoin).mint(address(this), totalReward);
        
        // Distribute rewards
        pendingStakingRewards += totalStakingRewardsForBlock;
        pendingODDAORewards += oddaoReward;
        validatorRewards[validator] += validatorReward;
        
        // Update tracking
        totalRewardsDistributed += totalReward;
        totalStakingRewards += totalStakingRewardsForBlock;
        totalODDAORewards += oddaoReward;
        totalValidatorRewards += validatorReward;
        lastRewardedBlock = currentBlock;
        
        emit BlockRewardDistributed(
            currentBlock,
            validator,
            validatorReward,
            oddaoReward,
            totalStakingRewardsForBlock,
            totalReward
        );
    }
    
    /**
     * @notice Claim accumulated validator rewards
     * @dev Validators can claim their earned rewards
     */
    function claimValidatorRewards() 
        external 
        whenNotPaused 
        nonReentrant 
    {
        uint256 rewards = validatorRewards[msg.sender];
        if (rewards == 0) revert NoRewardAvailable();
        
        validatorRewards[msg.sender] = 0;
        validatorRewardsClaimed[msg.sender] += rewards;
        
        address omniCoin = registry.getContract(keccak256("OMNICOIN"));
        if (!IOmniCoin(omniCoin).transfer(msg.sender, rewards)) {
            revert TransferFailed();
        }
        
        emit ValidatorRewardClaimed(msg.sender, rewards);
    }
    
    /**
     * @notice Withdraw accumulated ODDAO rewards
     * @dev Only callable by ODDAO treasury address
     * @param recipient Address to receive the rewards
     */
    function withdrawODDAORewards(address recipient) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        uint256 rewards = pendingODDAORewards;
        if (rewards == 0) revert NoRewardAvailable();
        
        pendingODDAORewards = 0;
        
        address omniCoin = registry.getContract(keccak256("OMNICOIN"));
        if (!IOmniCoin(omniCoin).transfer(recipient, rewards)) {
            revert TransferFailed();
        }
        
        emit ODDAORewardWithdrawn(recipient, rewards);
    }
    
    /**
     * @notice Withdraw accumulated staking rewards
     * @dev Only callable by staking pool contract
     * @param recipient Address to receive the rewards (staking pool)
     */
    function withdrawStakingRewards(address recipient) 
        external 
        onlyRole(STAKING_POOL_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        uint256 rewards = pendingStakingRewards;
        if (rewards == 0) revert NoRewardAvailable();
        
        pendingStakingRewards = 0;
        
        address omniCoin = registry.getContract(keccak256("OMNICOIN"));
        if (!IOmniCoin(omniCoin).transfer(recipient, rewards)) {
            revert TransferFailed();
        }
        
        emit StakingRewardWithdrawn(recipient, rewards);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get pending rewards for a validator
     * @param validator Address of the validator
     * @return Pending reward amount
     */
    function getPendingValidatorRewards(address validator) 
        external 
        view 
        returns (uint256) 
    {
        return validatorRewards[validator];
    }
    
    /**
     * @notice Get reward statistics
     * @return total Total rewards distributed
     * @return staking Total staking rewards
     * @return oddao Total ODDAO rewards
     * @return validators Total validator rewards
     * @return pendingStaking Pending staking withdrawals
     * @return pendingOddao Pending ODDAO withdrawals
     */
    function getRewardStats() 
        external 
        view 
        returns (
            uint256 total,
            uint256 staking,
            uint256 oddao,
            uint256 validators,
            uint256 pendingStaking,
            uint256 pendingOddao
        ) 
    {
        return (
            totalRewardsDistributed,
            totalStakingRewards,
            totalODDAORewards,
            totalValidatorRewards,
            pendingStakingRewards,
            pendingODDAORewards
        );
    }
    
    /**
     * @notice Calculate rewards for a given number of blocks
     * @param blockCount Number of blocks
     * @param stakingRewardsPerBlock Average staking rewards per block
     * @return totalReward Total reward amount
     * @return stakingShare Total staking pool share
     * @return oddaoShare ODDAO's share
     * @return validatorShare Validator's share
     */
    function calculateRewards(uint256 blockCount, uint256 stakingRewardsPerBlock) 
        external 
        view 
        returns (
            uint256 totalReward,
            uint256 stakingShare,
            uint256 oddaoShare,
            uint256 validatorShare
        ) 
    {
        totalReward = blockRewardAmount * blockCount;
        stakingShare = stakingRewardsPerBlock * blockCount;
        
        if (stakingShare > totalReward) {
            stakingShare = totalReward;
            oddaoShare = 0;
            validatorShare = 0;
        } else {
            uint256 remainingAfterStaking = totalReward - stakingShare;
            oddaoShare = (remainingAfterStaking * ODDAO_SHARE_BPS) / BASIS_POINTS;
            validatorShare = remainingAfterStaking - oddaoShare;
        }
    }
    
    /**
     * @notice Calculate total staking rewards for the current block
     * @dev This would typically be called by validators to determine staking rewards
     * @return totalStakingRewards Total rewards to be distributed to stakers
     * 
     * NOTE: This is a simplified implementation. In production, this would need to:
     * 1. Query the staking contract for all active stakers
     * 2. Calculate each staker's APY based on tier and duration
     * 3. Pro-rate rewards per block
     * 
     * For now, returns 0 to allow testing of the distribution mechanism
     */
    function calculateCurrentBlockStakingRewards() 
        public 
        view 
        returns (uint256 totalStakingRewards) 
    {
        // TODO: Implement actual calculation once staking contract interface is defined
        // This would involve:
        // 1. Get staking contract from registry
        // 2. Iterate through active stakers
        // 3. Calculate rewards based on stake amount, tier APY, and duration bonus
        // 4. Divide by blocks per year to get per-block amount
        
        // For now, return 0 to allow testing
        return 0;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update block reward amount
     * @dev Only callable by admin
     * @param newAmount New block reward amount
     */
    function updateBlockRewardAmount(uint256 newAmount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (newAmount == 0) revert InvalidAmount();
        
        uint256 oldAmount = blockRewardAmount;
        blockRewardAmount = newAmount;
        
        emit BlockRewardAmountUpdated(oldAmount, newAmount);
    }
    
    /**
     * @notice Pause block rewards
     * @dev Emergency pause functionality
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause block rewards
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Grant block producer role
     * @param producer Address to grant role to
     */
    function grantBlockProducerRole(address producer) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        grantRole(BLOCK_PRODUCER_ROLE, producer);
    }
    
    /**
     * @notice Revoke block producer role
     * @param producer Address to revoke role from
     */
    function revokeBlockProducerRole(address producer) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        revokeRole(BLOCK_PRODUCER_ROLE, producer);
    }
    
    /**
     * @notice Grant staking pool role
     * @param stakingPool Address to grant role to
     */
    function grantStakingPoolRole(address stakingPool) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        grantRole(STAKING_POOL_ROLE, stakingPool);
    }
    
    /**
     * @notice Revoke staking pool role
     * @param stakingPool Address to revoke role from
     */
    function revokeStakingPoolRole(address stakingPool) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        revokeRole(STAKING_POOL_ROLE, stakingPool);
    }
}