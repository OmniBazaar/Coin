// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniCoinConfig
 * @dev Configuration contract for OmniCoin parameters that can be set before deployment
 */
contract OmniCoinConfig is Ownable, ReentrancyGuard {
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

    // Bridge configuration
    BridgeConfig[] public bridgeConfigs;

    // Staking configuration
    StakingTier[] public stakingTiers;

    // Configuration
    uint256 public emissionRate;
    bool public useParticipationScore;
    uint256 public proposalThreshold;
    uint256 public votingPeriod;
    uint256 public quorum;

    // Events
    event BridgeConfigAdded(
        uint256 indexed chainId,
        address token,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 fee
    );
    event BridgeConfigRemoved(uint256 indexed chainId);
    event StakingTierUpdated(
        uint256 indexed tierId,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 rewardRate,
        uint256 lockPeriod,
        uint256 penaltyRate
    );
    event EmissionRateUpdated(uint256 oldRate, uint256 newRate);
    event ParticipationScoreToggled(bool enabled);
    event ProposalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event VotingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    constructor(address initialOwner) Ownable(initialOwner) {
        // Initialize default values
        emissionRate = 100; // 100 tokens per block
        useParticipationScore = true;
        proposalThreshold = 10000 * 10 ** 6; // 10,000 tokens
        votingPeriod = 3 days;
        quorum = 100000 * 10 ** 6; // 100,000 tokens

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

    // Bridge functions
    function addBridgeConfig(
        uint256 _chainId,
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _fee
    ) external onlyOwner {
        require(_chainId != block.chainid, "Invalid chain ID");
        require(_token != address(0), "Invalid token");
        require(_minAmount <= _maxAmount, "Invalid amounts");

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

    function removeBridgeConfig(uint256 _chainId) external onlyOwner {
        for (uint256 i = 0; i < bridgeConfigs.length; i++) {
            if (bridgeConfigs[i].chainId == _chainId) {
                bridgeConfigs[i].isActive = false;
                emit BridgeConfigRemoved(_chainId);
                break;
            }
        }
    }

    function isBridgeSupported(uint256 _chainId) external view returns (bool) {
        for (uint256 i = 0; i < bridgeConfigs.length; i++) {
            if (
                bridgeConfigs[i].chainId == _chainId &&
                bridgeConfigs[i].isActive
            ) {
                return true;
            }
        }
        return false;
    }

    function getBridgeConfig(
        uint256 _chainId
    ) external view returns (BridgeConfig memory) {
        for (uint256 i = 0; i < bridgeConfigs.length; i++) {
            if (bridgeConfigs[i].chainId == _chainId) {
                return bridgeConfigs[i];
            }
        }
        revert("OmniCoinConfig: bridge config not found");
    }

    // Staking functions
    function updateStakingTier(
        uint256 _tierId,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _rewardRate,
        uint256 _lockPeriod,
        uint256 _penaltyRate
    ) external onlyOwner {
        require(
            _tierId < stakingTiers.length,
            "OmniCoinConfig: invalid tier ID"
        );

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

    function getStakingTier(
        uint256 _amount
    ) external view returns (StakingTier memory) {
        for (uint256 i = 0; i < stakingTiers.length; i++) {
            if (
                _amount >= stakingTiers[i].minAmount &&
                _amount <= stakingTiers[i].maxAmount
            ) {
                return stakingTiers[i];
            }
        }
        revert("OmniCoinConfig: no matching staking tier");
    }

    // Configuration update functions
    function setEmissionRate(uint256 _rate) external onlyOwner {
        emit EmissionRateUpdated(emissionRate, _rate);
        emissionRate = _rate;
    }

    function toggleParticipationScore() external onlyOwner {
        useParticipationScore = !useParticipationScore;
        emit ParticipationScoreToggled(useParticipationScore);
    }

    function setProposalThreshold(uint256 _threshold) external onlyOwner {
        emit ProposalThresholdUpdated(proposalThreshold, _threshold);
        proposalThreshold = _threshold;
    }

    function setVotingPeriod(uint256 _period) external onlyOwner {
        emit VotingPeriodUpdated(votingPeriod, _period);
        votingPeriod = _period;
    }

    function setQuorum(uint256 _quorum) external onlyOwner {
        emit QuorumUpdated(quorum, _quorum);
        quorum = _quorum;
    }
}
