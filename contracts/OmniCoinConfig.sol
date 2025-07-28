// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinConfig
 * @author OmniCoin Development Team
 * @notice Configuration contract for OmniCoin system parameters and settings
 * @dev This contract stores bridge configurations, staking tiers, and governance parameters
 */
contract OmniCoinConfig is RegistryAware, Ownable, ReentrancyGuard {
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct BridgeConfig {
        uint256 chainId;
        address token;
        bool isActive;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 fee;
    }

    struct StakingTier {
        uint256 minAmount;
        uint256 maxAmount;
        uint256 rewardRate;
        uint256 lockPeriod;
        uint256 penaltyRate;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Array of bridge configurations for different chains
    BridgeConfig[] public bridgeConfigs;

    /// @notice Array of staking tiers with different reward rates
    StakingTier[] public stakingTiers;

    /// @notice Token emission rate for rewards
    uint256 public emissionRate;
    /// @notice Whether to use participation score in calculations
    bool public useParticipationScore;
    /// @notice Minimum tokens required to create a proposal
    uint256 public proposalThreshold;
    /// @notice Duration of voting period in seconds
    uint256 public votingPeriod;
    /// @notice Percentage of votes required for quorum
    uint256 public quorum;
    
    /// @notice Testnet mode flag - bypasses reputation requirements for testing
    bool public isTestnetMode;
    
    /// @notice Privacy fee rate for private transactions (basis points)
    uint256 public privacyFeeRate;
    /// @notice Privacy fee multiplier for premium features
    uint256 public privacyFeeMultiplier;
    /// @notice Whether privacy features are enabled globally
    bool public privacyEnabled;
    /// @notice Bridge fee for converting between public and private tokens
    uint256 public tokenBridgeFee;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a new bridge configuration is added
     * @param chainId The chain ID of the bridge
     * @param token The token address on the target chain
     * @param minAmount Minimum amount for bridge transfers
     * @param maxAmount Maximum amount for bridge transfers
     * @param fee Fee for bridge transfers
     */
    event BridgeConfigAdded(
        uint256 indexed chainId,
        address indexed token,
        uint256 indexed minAmount,
        uint256 maxAmount,
        uint256 fee
    );
    
    /**
     * @notice Emitted when a bridge configuration is removed
     * @param chainId The chain ID of the removed bridge
     */
    event BridgeConfigRemoved(uint256 indexed chainId);
    
    /**
     * @notice Emitted when a staking tier is updated
     * @param tierId The ID of the updated tier
     * @param minAmount Minimum staking amount for this tier
     * @param maxAmount Maximum staking amount for this tier
     * @param rewardRate Reward rate for this tier
     * @param lockPeriod Lock period for this tier
     * @param penaltyRate Penalty rate for early withdrawal
     */
    event StakingTierUpdated(
        uint256 indexed tierId,
        uint256 indexed minAmount,
        uint256 indexed maxAmount,
        uint256 rewardRate,
        uint256 lockPeriod,
        uint256 penaltyRate
    );
    
    /**
     * @notice Emitted when emission rate is updated
     * @param oldRate Previous emission rate
     * @param newRate New emission rate
     */
    event EmissionRateUpdated(uint256 indexed oldRate, uint256 indexed newRate);
    
    /**
     * @notice Emitted when participation score usage is toggled
     * @param enabled Whether participation score is enabled
     */
    event ParticipationScoreToggled(bool indexed enabled);
    
    /**
     * @notice Emitted when proposal threshold is updated
     * @param oldThreshold Previous threshold
     * @param newThreshold New threshold
     */
    event ProposalThresholdUpdated(uint256 indexed oldThreshold, uint256 indexed newThreshold);
    
    /**
     * @notice Emitted when voting period is updated
     * @param oldPeriod Previous voting period
     * @param newPeriod New voting period
     */
    event VotingPeriodUpdated(uint256 indexed oldPeriod, uint256 indexed newPeriod);
    
    /**
     * @notice Emitted when quorum requirement is updated
     * @param oldQuorum Previous quorum
     * @param newQuorum New quorum
     */
    event QuorumUpdated(uint256 indexed oldQuorum, uint256 indexed newQuorum);
    
    /**
     * @notice Emitted when testnet mode is toggled
     * @param enabled Whether testnet mode is enabled
     */
    event TestnetModeToggled(bool indexed enabled);
    
    /**
     * @notice Emitted when privacy fee rate is updated
     * @param oldRate Previous fee rate
     * @param newRate New fee rate
     */
    event PrivacyFeeRateUpdated(uint256 indexed oldRate, uint256 indexed newRate);
    
    /**
     * @notice Emitted when privacy fee multiplier is updated
     * @param oldMultiplier Previous multiplier
     * @param newMultiplier New multiplier
     */
    event PrivacyFeeMultiplierUpdated(uint256 indexed oldMultiplier, uint256 indexed newMultiplier);
    
    /**
     * @notice Emitted when privacy is toggled
     * @param enabled Whether privacy is enabled
     */
    event PrivacyToggled(bool indexed enabled);
    
    /**
     * @notice Emitted when token bridge fee is updated
     * @param oldFee Previous bridge fee
     * @param newFee New bridge fee
     */
    event TokenBridgeFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAmount();
    error InvalidRate();
    error InvalidPeriod();
    error InvalidChainId();
    error TierNotFound();
    error ConfigNotFound();

    /**
     * @notice Initialize the configuration contract
     * @param _registry Registry contract address
     * @param initialOwner The initial owner of the contract
     */
    constructor(address _registry, address initialOwner) 
        RegistryAware(_registry) 
        Ownable(initialOwner) {
        // Initialize default values
        emissionRate = 100; // 100 tokens per block
        useParticipationScore = true;
        proposalThreshold = 10000 * 10 ** 6; // 10,000 tokens
        votingPeriod = 3 days;
        quorum = 100000 * 10 ** 6; // 100,000 tokens
        isTestnetMode = false; // Default to production mode
        
        // Initialize privacy settings
        privacyFeeRate = 100; // 1% in basis points
        privacyFeeMultiplier = 10; // 10x fee for privacy features
        privacyEnabled = true; // Privacy enabled by default
        tokenBridgeFee = 10 * 10 ** 6; // 10 tokens for bridging

        // Initialize default staking tiers
        stakingTiers.push(
            StakingTier({
                minAmount: 1000 * 10 ** 6, // 1,000 tokens
                maxAmount: 10000 * 10 ** 6, // 10,000 tokens
                rewardRate: 5, // 5% APY
                lockPeriod: 30 days,
                penaltyRate: 10 // 10% penalty
            })
        );

        stakingTiers.push(
            StakingTier({
                minAmount: 10000 * 10 ** 6, // 10,000 tokens
                maxAmount: 100000 * 10 ** 6, // 100,000 tokens
                rewardRate: 10, // 10% APY
                lockPeriod: 90 days,
                penaltyRate: 20 // 20% penalty
            })
        );

        stakingTiers.push(
            StakingTier({
                minAmount: 100000 * 10 ** 6, // 100,000 tokens
                maxAmount: type(uint256).max,
                rewardRate: 20, // 20% APY
                lockPeriod: 180 days,
                penaltyRate: 30 // 30% penalty
            })
        );
    }

    /**
     * @notice Add a new bridge configuration
     * @param _chainId Chain ID of the target blockchain
     * @param _token Token address on the target chain
     * @param _minAmount Minimum amount for bridge transfers
     * @param _maxAmount Maximum amount for bridge transfers
     * @param _fee Fee for bridge transfers
     */
    function addBridgeConfig(
        uint256 _chainId,
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _fee
    ) external onlyOwner {
        if (_chainId == block.chainid) revert InvalidChainId();
        if (_token == address(0)) revert InvalidAmount();
        if (_minAmount > _maxAmount) revert InvalidAmount();

        bridgeConfigs.push(
            BridgeConfig({
                chainId: _chainId,
                token: _token,
                isActive: true,
                minAmount: _minAmount,
                maxAmount: _maxAmount,
                fee: _fee
            })
        );

        emit BridgeConfigAdded(_chainId, _token, _minAmount, _maxAmount, _fee);
    }

    /**
     * @notice Remove a bridge configuration
     * @param _chainId Chain ID of the bridge to remove
     */
    function removeBridgeConfig(uint256 _chainId) external onlyOwner {
        for (uint256 i = 0; i < bridgeConfigs.length; ++i) {
            if (bridgeConfigs[i].chainId == _chainId) {
                bridgeConfigs[i].isActive = false;
                emit BridgeConfigRemoved(_chainId);
                break;
            }
        }
    }

    /**
     * @notice Update a staking tier configuration
     * @param _tierId Tier ID to update
     * @param _minAmount Minimum staking amount
     * @param _maxAmount Maximum staking amount
     * @param _rewardRate Annual percentage yield
     * @param _lockPeriod Lock period in seconds
     * @param _penaltyRate Early withdrawal penalty percentage
     */
    function updateStakingTier(
        uint256 _tierId,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _rewardRate,
        uint256 _lockPeriod,
        uint256 _penaltyRate
    ) external onlyOwner {
        if (_tierId > stakingTiers.length || _tierId == stakingTiers.length) revert TierNotFound();

        stakingTiers[_tierId] = StakingTier({
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            rewardRate: _rewardRate,
            lockPeriod: _lockPeriod,
            penaltyRate: _penaltyRate
        });

        emit StakingTierUpdated(
            _tierId,
            _minAmount,
            _maxAmount,
            _rewardRate,
            _lockPeriod,
            _penaltyRate
        );
    }

    /**
     * @notice Set token emission rate
     * @param _rate New emission rate
     */
    function setEmissionRate(uint256 _rate) external onlyOwner {
        emit EmissionRateUpdated(emissionRate, _rate);
        emissionRate = _rate;
    }

    /**
     * @notice Toggle participation score usage
     */
    function toggleParticipationScore() external onlyOwner {
        useParticipationScore = !useParticipationScore;
        emit ParticipationScoreToggled(useParticipationScore);
    }

    /**
     * @notice Set proposal creation threshold
     * @param _threshold New threshold amount
     */
    function setProposalThreshold(uint256 _threshold) external onlyOwner {
        emit ProposalThresholdUpdated(proposalThreshold, _threshold);
        proposalThreshold = _threshold;
    }

    /**
     * @notice Set voting period duration
     * @param _period New voting period in seconds
     */
    function setVotingPeriod(uint256 _period) external onlyOwner {
        emit VotingPeriodUpdated(votingPeriod, _period);
        votingPeriod = _period;
    }

    /**
     * @notice Set quorum requirement
     * @param _quorum New quorum amount
     */
    function setQuorum(uint256 _quorum) external onlyOwner {
        emit QuorumUpdated(quorum, _quorum);
        quorum = _quorum;
    }
    
    /**
     * @notice Toggle testnet mode
     */
    function toggleTestnetMode() external onlyOwner {
        isTestnetMode = !isTestnetMode;
        emit TestnetModeToggled(isTestnetMode);
    }
    
    /**
     * @notice Set privacy fee rate
     * @param _rate New fee rate in basis points
     */
    function setPrivacyFeeRate(uint256 _rate) external onlyOwner {
        if (_rate > 1000) revert InvalidRate(); // Max 10%
        emit PrivacyFeeRateUpdated(privacyFeeRate, _rate);
        privacyFeeRate = _rate;
    }
    
    /**
     * @notice Set privacy fee multiplier
     * @param _multiplier New fee multiplier
     */
    function setPrivacyFeeMultiplier(uint256 _multiplier) external onlyOwner {
        if (_multiplier == 0 || _multiplier > 100) revert InvalidRate(); // Between 1x and 100x
        emit PrivacyFeeMultiplierUpdated(privacyFeeMultiplier, _multiplier);
        privacyFeeMultiplier = _multiplier;
    }
    
    /**
     * @notice Toggle privacy features globally
     */
    function togglePrivacy() external onlyOwner {
        privacyEnabled = !privacyEnabled;
        emit PrivacyToggled(privacyEnabled);
    }
    
    /**
     * @notice Set token bridge fee
     * @param _fee New bridge fee amount
     */
    function setTokenBridgeFee(uint256 _fee) external onlyOwner {
        emit TokenBridgeFeeUpdated(tokenBridgeFee, _fee);
        tokenBridgeFee = _fee;
    }

    /**
     * @notice Check if a chain is supported for bridging
     * @param _chainId Chain ID to check
     * @return supported Whether the chain is supported
     */
    function isBridgeSupported(uint256 _chainId) external view returns (bool supported) {
        for (uint256 i = 0; i < bridgeConfigs.length; ++i) {
            if (
                bridgeConfigs[i].chainId == _chainId &&
                bridgeConfigs[i].isActive
            ) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Get bridge configuration for a specific chain
     * @param _chainId Chain ID to query
     * @return config Bridge configuration
     */
    function getBridgeConfig(
        uint256 _chainId
    ) external view returns (BridgeConfig memory config) {
        for (uint256 i = 0; i < bridgeConfigs.length; ++i) {
            if (bridgeConfigs[i].chainId == _chainId) {
                return bridgeConfigs[i];
            }
        }
        revert ConfigNotFound();
    }

    /**
     * @notice Get staking tier for a given amount
     * @param _amount Amount to check
     * @return tier Staking tier configuration
     */
    function getStakingTier(
        uint256 _amount
    ) external view returns (StakingTier memory tier) {
        for (uint256 i = 0; i < stakingTiers.length; ++i) {
            if (
                _amount > stakingTiers[i].minAmount - 1 &&
                _amount < stakingTiers[i].maxAmount + 1
            ) {
                return stakingTiers[i];
            }
        }
        revert TierNotFound();
    }
    
    /**
     * @notice Get all privacy-related configuration
     * @return feeRate Privacy fee rate in basis points
     * @return feeMultiplier Privacy fee multiplier
     * @return enabled Whether privacy is enabled
     * @return bridgeFee Token bridge fee
     */
    function getPrivacyConfig() external view returns (
        uint256 feeRate,
        uint256 feeMultiplier,
        bool enabled,
        uint256 bridgeFee
    ) {
        return (privacyFeeRate, privacyFeeMultiplier, privacyEnabled, tokenBridgeFee);
    }
}