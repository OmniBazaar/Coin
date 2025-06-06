// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./omnicoin-erc20-coti.sol";

/**
 * @title OmniCoinReputation
 * @dev Handles reputation tracking for marketplace participants
 */
contract OmniCoinReputation is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct ReputationScore {
        uint256 overallScore;
        uint256 marketplaceScore;
        uint256 validatorScore;
        uint256 referralScore;
        uint256 lastUpdate;
        uint256 totalTransactions;
        uint256 successfulTransactions;
    }

    struct ReputationHistory {
        uint256 timestamp;
        uint256 score;
        string reason;
        address actor;
    }

    // State variables
    mapping(address => ReputationScore) public reputationScores;
    mapping(address => ReputationHistory[]) public reputationHistory;
    mapping(address => uint256) public referralCount;
    mapping(address => address[]) public referrals;
    
    OmniCoin public omniCoin;
    uint256 public minReputationForValidator;
    uint256 public reputationDecayPeriod;
    uint256 public reputationDecayFactor;

    // Events
    event ReputationUpdated(
        address indexed user,
        uint256 newOverallScore,
        uint256 newMarketplaceScore,
        uint256 newValidatorScore,
        uint256 newReferralScore
    );
    event ReferralAdded(address indexed referrer, address indexed referred);
    event MinReputationForValidatorUpdated(uint256 newMinReputation);
    event ReputationDecayUpdated(uint256 newPeriod, uint256 newFactor);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _omniCoin,
        uint256 _minReputationForValidator,
        uint256 _reputationDecayPeriod,
        uint256 _reputationDecayFactor
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        minReputationForValidator = _minReputationForValidator;
        reputationDecayPeriod = _reputationDecayPeriod;
        reputationDecayFactor = _reputationDecayFactor;
    }

    /**
     * @dev Update reputation scores for a user
     */
    function updateReputation(
        address _user,
        uint256 _marketplaceDelta,
        uint256 _validatorDelta,
        uint256 _referralDelta,
        string memory _reason
    ) internal {
        ReputationScore storage score = reputationScores[_user];
        
        // Apply decay if needed
        if (block.timestamp >= score.lastUpdate + reputationDecayPeriod) {
            uint256 decay = (block.timestamp - score.lastUpdate) / reputationDecayPeriod;
            score.marketplaceScore = score.marketplaceScore * (100 - (decay * reputationDecayFactor)) / 100;
            score.validatorScore = score.validatorScore * (100 - (decay * reputationDecayFactor)) / 100;
        }

        // Update scores
        score.marketplaceScore += _marketplaceDelta;
        score.validatorScore += _validatorDelta;
        score.referralScore += _referralDelta;
        score.overallScore = calculateOverallScore(score);
        score.lastUpdate = block.timestamp;

        // Add to history
        reputationHistory[_user].push(ReputationHistory({
            timestamp: block.timestamp,
            score: score.overallScore,
            reason: _reason,
            actor: msg.sender
        }));

        emit ReputationUpdated(
            _user,
            score.overallScore,
            score.marketplaceScore,
            score.validatorScore,
            score.referralScore
        );
    }

    /**
     * @dev Record a successful transaction
     */
    function recordSuccessfulTransaction(address _user) external onlyOwner {
        ReputationScore storage score = reputationScores[_user];
        score.totalTransactions++;
        score.successfulTransactions++;
        
        // Small reputation boost for successful transactions
        string memory reason = "Successful transaction";
        updateReputation(_user, 1, 0, 0, reason);
    }

    /**
     * @dev Record a failed transaction
     */
    function recordFailedTransaction(address _user) external onlyOwner {
        ReputationScore storage score = reputationScores[_user];
        score.totalTransactions++;
        
        // Small reputation penalty for failed transactions
        unchecked {
            string memory reason = "Failed transaction";
            updateReputation(_user, 1, 0, 0, reason);
        }
    }

    /**
     * @dev Add a referral
     */
    function addReferral(address _referrer, address _referred) external onlyOwner {
        require(_referrer != _referred, "Cannot refer self");
        require(referrals[_referrer].length < 100, "Too many referrals");
        
        referrals[_referrer].push(_referred);
        referralCount[_referrer]++;
        
        // Reputation boost for successful referral
        string memory reason = "New referral";
        updateReputation(_referrer, 0, 0, 5, reason);
        
        emit ReferralAdded(_referrer, _referred);
    }

    /**
     * @dev Calculate overall reputation score
     */
    function calculateOverallScore(ReputationScore memory score) public pure returns (uint256) {
        return (score.marketplaceScore * 40 + 
                score.validatorScore * 30 + 
                score.referralScore * 30) / 100;
    }

    /**
     * @dev Check if user qualifies as validator
     */
    function qualifiesAsValidator(address _user) external view returns (bool) {
        return reputationScores[_user].overallScore >= minReputationForValidator;
    }

    /**
     * @dev Get reputation history
     */
    function getReputationHistory(address _user) external view returns (ReputationHistory[] memory) {
        return reputationHistory[_user];
    }

    /**
     * @dev Get referrals
     */
    function getReferrals(address _user) external view returns (address[] memory) {
        return referrals[_user];
    }

    /**
     * @dev Update minimum reputation for validator
     */
    function updateMinReputationForValidator(uint256 _newMinReputation) external onlyOwner {
        minReputationForValidator = _newMinReputation;
        emit MinReputationForValidatorUpdated(_newMinReputation);
    }

    /**
     * @dev Update reputation decay parameters
     */
    function updateReputationDecay(uint256 _newPeriod, uint256 _newFactor) external onlyOwner {
        require(_newFactor <= 100, "Decay factor too high");
        reputationDecayPeriod = _newPeriod;
        reputationDecayFactor = _newFactor;
        emit ReputationDecayUpdated(_newPeriod, _newFactor);
    }
} 