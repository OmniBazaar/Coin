// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OmniCoinReputation is Ownable, ReentrancyGuard {
    struct ReputationScore {
        uint256 score;
        uint256 positiveInteractions;
        uint256 negativeInteractions;
        uint256 lastUpdate;
    }

    mapping(address => ReputationScore) public reputationScores;

    uint256 public minValidatorReputation;
    uint256 public reputationDecayPeriod;
    uint256 public reputationDecayRate;

    event ReputationUpdated(
        address indexed user,
        uint256 oldScore,
        uint256 newScore
    );
    event MinValidatorReputationUpdated(uint256 oldValue, uint256 newValue);
    event ReputationDecayPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event ReputationDecayRateUpdated(uint256 oldRate, uint256 newRate);

    constructor(address _config, address initialOwner) Ownable(initialOwner) {
        minValidatorReputation = 1000;
        reputationDecayPeriod = 30 days;
        reputationDecayRate = 1; // 1% decay per period
    }

    function updateReputation(
        address user,
        int256 change
    ) external onlyOwner nonReentrant {
        ReputationScore storage score = reputationScores[user];
        uint256 oldScore = score.score;

        // Apply decay if applicable
        if (score.lastUpdate > 0) {
            uint256 periods = (block.timestamp - score.lastUpdate) /
                reputationDecayPeriod;
            if (periods > 0) {
                uint256 decay = (score.score * reputationDecayRate * periods) /
                    100;
                if (decay > score.score) {
                    score.score = 0;
                } else {
                    score.score -= decay;
                }
            }
        }

        // Update score
        if (change > 0) {
            score.score += uint256(change);
            score.positiveInteractions++;
        } else if (change < 0) {
            uint256 absChange = uint256(-change);
            if (absChange > score.score) {
                score.score = 0;
            } else {
                score.score -= absChange;
            }
            score.negativeInteractions++;
        }

        score.lastUpdate = block.timestamp;

        emit ReputationUpdated(user, oldScore, score.score);
    }

    function setMinValidatorReputation(
        uint256 _minReputation
    ) external onlyOwner {
        emit MinValidatorReputationUpdated(
            minValidatorReputation,
            _minReputation
        );
        minValidatorReputation = _minReputation;
    }

    function setReputationDecayPeriod(uint256 _period) external onlyOwner {
        emit ReputationDecayPeriodUpdated(reputationDecayPeriod, _period);
        reputationDecayPeriod = _period;
    }

    function setReputationDecayRate(uint256 _rate) external onlyOwner {
        emit ReputationDecayRateUpdated(reputationDecayRate, _rate);
        reputationDecayRate = _rate;
    }

    function getReputation(
        address user
    )
        external
        view
        returns (
            uint256 score,
            uint256 positiveInteractions,
            uint256 negativeInteractions,
            uint256 lastUpdate
        )
    {
        ReputationScore storage reputation = reputationScores[user];
        return (
            reputation.score,
            reputation.positiveInteractions,
            reputation.negativeInteractions,
            reputation.lastUpdate
        );
    }

    function isEligibleValidator(address user) external view returns (bool) {
        return reputationScores[user].score >= minValidatorReputation;
    }
}
