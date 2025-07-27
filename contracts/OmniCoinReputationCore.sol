// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {OmniCoinConfig} from "./OmniCoinConfig.sol";
import {IReputationCore, IIdentityVerification, ITrustSystem, IReferralSystem} from "./interfaces/IReputationSystem.sol";

/**
 * @title OmniCoinReputationCore
 * @dev Core reputation aggregation contract that coordinates all reputation modules
 * 
 * This is the main entry point for reputation queries and updates.
 * It aggregates scores from:
 * - Identity Verification System
 * - Trust System (DPoS/COTI PoT)
 * - Referral System
 * - Standard reputation components
 */
contract OmniCoinReputationCore is IReputationCore, AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct PrivateReputation {
        gtUint64 encryptedTotalScore;       // Private: total reputation score
        ctUint64 userEncryptedScore;        // Private: score encrypted for user viewing
        uint256 publicTier;                 // Public: reputation tier for validator selection
        uint256 lastUpdate;                 // Public: timestamp of last update
        uint256 totalInteractions;          // Public: number of interactions
        bool isPrivacyEnabled;              // Public: user's privacy preference
        bool isActive;                      // Public: whether reputation is active
    }
    
    struct ReputationComponent {
        gtUint64 encryptedValue;            // Private: component value
        ctUint64 userEncryptedValue;        // Private: value encrypted for user viewing
        uint256 interactionCount;           // Public: number of interactions
        uint256 lastUpdate;                 // Public: last update timestamp
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    bytes32 public constant MODULE_ROLE = keccak256("MODULE_ROLE");
    
    // Component IDs (inherited from interface)
    uint8 public constant override COMPONENT_TRANSACTION_SUCCESS = 0;
    uint8 public constant override COMPONENT_TRANSACTION_DISPUTE = 1;
    uint8 public constant override COMPONENT_ARBITRATION_PERFORMANCE = 2;
    uint8 public constant override COMPONENT_GOVERNANCE_PARTICIPATION = 3;
    uint8 public constant override COMPONENT_VALIDATOR_PERFORMANCE = 4;
    uint8 public constant override COMPONENT_MARKETPLACE_BEHAVIOR = 5;
    uint8 public constant override COMPONENT_COMMUNITY_ENGAGEMENT = 6;
    uint8 public constant override COMPONENT_UPTIME_RELIABILITY = 7;
    uint8 public constant override COMPONENT_TRUST_SCORE = 8;
    uint8 public constant override COMPONENT_REFERRAL_ACTIVITY = 9;
    uint8 public constant override COMPONENT_IDENTITY_VERIFICATION = 10;
    
    uint8 public constant MAX_COMPONENTS = 11;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Reputation tier thresholds
    uint256 public constant TIER_BRONZE = 1000;
    uint256 public constant TIER_SILVER = 5000;
    uint256 public constant TIER_GOLD = 10000;
    uint256 public constant TIER_PLATINUM = 20000;
    uint256 public constant TIER_DIAMOND = 50000;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error UnauthorizedModule();
    error ComponentNotEnabled();
    error InvalidComponentId();
    error WeightExceedsLimit();
    error InvalidBasisPoints();
    error ReputationInactive();
    error BatchLengthMismatch();
    error ComponentAlreadyRegistered();
    error ComponentNotRegistered();
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev MPC availability flag
    bool public override isMpcAvailable;
    
    /// @dev User reputations
    mapping(address => PrivateReputation) public userReputations;
    
    /// @dev Component data: user => component => data
    mapping(address => mapping(uint8 => ReputationComponent)) public componentData;
    
    /// @dev Component weights (basis points, must sum to 10000)
    uint256[11] public componentWeights;
    
    /// @dev Module addresses
    IIdentityVerification public identityModule;
    ITrustSystem public trustModule;
    IReferralSystem public referralModule;
    
    /// @dev Config contract
    OmniCoinConfig public config;
    
    /// @dev Minimum reputation for validators
    uint256 public minValidatorReputation = 5000;
    
    /// @dev Minimum reputation for arbitrators
    uint256 public minArbitratorReputation = 10000;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event ModuleUpdated(string moduleType, address indexed newModule);
    event MinimumReputationUpdated(string role, uint256 newMinimum);
    event PrivacyPreferenceUpdated(address indexed user, bool privacyEnabled);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _admin,
        address _config,
        address _identityModule,
        address _trustModule,
        address _referralModule
    ) {
        if (_admin == address(0)) revert InvalidAddress();
        if (_config == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REPUTATION_UPDATER_ROLE, _admin);
        
        config = OmniCoinConfig(_config);
        
        // Set modules (can be zero initially)
        identityModule = IIdentityVerification(_identityModule);
        trustModule = ITrustSystem(_trustModule);
        referralModule = IReferralSystem(_referralModule);
        
        // Grant module role if addresses provided
        if (_identityModule != address(0)) _grantRole(MODULE_ROLE, _identityModule);
        if (_trustModule != address(0)) _grantRole(MODULE_ROLE, _trustModule);
        if (_referralModule != address(0)) _grantRole(MODULE_ROLE, _referralModule);
        
        // Initialize default weights (must sum to 10000)
        componentWeights[0] = 1500;  // Transaction success: 15%
        componentWeights[1] = 500;   // Transaction dispute: 5%
        componentWeights[2] = 1000;  // Arbitration: 10%
        componentWeights[3] = 500;   // Governance: 5%
        componentWeights[4] = 1000;  // Validator: 10%
        componentWeights[5] = 1000;  // Marketplace: 10%
        componentWeights[6] = 500;   // Community: 5%
        componentWeights[7] = 1000;  // Uptime: 10%
        componentWeights[8] = 1500;  // Trust: 15%
        componentWeights[9] = 500;   // Referral: 5%
        componentWeights[10] = 1000; // Identity: 10%
        
        // MPC starts disabled for testing
        isMpcAvailable = false;
    }
    
    // =============================================================================
    // MPC AVAILABILITY
    // =============================================================================
    
    /**
     * @dev Set MPC availability
     */
    function setMpcAvailability(bool _available) external override onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    // =============================================================================
    // REPUTATION UPDATES
    // =============================================================================
    
    /**
     * @dev Update reputation component (called by modules or authorized updaters)
     */
    function updateReputationComponent(
        address user,
        uint8 componentId,
        itUint64 calldata value
    ) external override whenNotPaused nonReentrant {
        if (!hasRole(MODULE_ROLE, msg.sender) && 
            !hasRole(REPUTATION_UPDATER_ROLE, msg.sender)) revert UnauthorizedModule();
        if (componentId >= MAX_COMPONENTS) revert InvalidComponentId();
        
        // Validate and convert input
        gtUint64 gtValue;
        if (isMpcAvailable) {
            gtValue = MpcCore.validateCiphertext(value);
        } else {
            uint64 plainValue = uint64(uint256(keccak256(abi.encode(value))));
            gtValue = gtUint64.wrap(plainValue);
        }
        
        // Update component
        ReputationComponent storage component = componentData[user][componentId];
        component.encryptedValue = gtValue;
        component.interactionCount++;
        component.lastUpdate = block.timestamp;
        
        // Encrypt for user viewing
        if (isMpcAvailable) {
            component.userEncryptedValue = MpcCore.offBoardToUser(gtValue, user);
        } else {
            component.userEncryptedValue = ctUint64.wrap(uint64(gtUint64.unwrap(gtValue)));
        }
        
        // Recalculate total reputation
        _recalculateTotalReputation(user);
        
        emit ReputationUpdated(user, componentId, block.timestamp);
    }
    
    // =============================================================================
    // REPUTATION QUERIES
    // =============================================================================
    
    /**
     * @dev Get user's public reputation tier
     */
    function getPublicReputationTier(address user) external view override returns (uint256) {
        return userReputations[user].publicTier;
    }
    
    /**
     * @dev Check if user is eligible to be a validator
     */
    function isEligibleValidator(address user) external view override returns (bool) {
        // Check testnet mode first
        if (config.isTestnetMode()) {
            return true;
        }
        
        PrivateReputation storage reputation = userReputations[user];
        return reputation.isActive && 
               reputation.publicTier >= minValidatorReputation &&
               reputation.totalInteractions >= 10;
    }
    
    /**
     * @dev Check if user is eligible to be an arbitrator
     */
    function isEligibleArbitrator(address user) external view override returns (bool) {
        // Check testnet mode first
        if (config.isTestnetMode()) {
            return true;
        }
        
        PrivateReputation storage reputation = userReputations[user];
        return reputation.isActive && 
               reputation.publicTier >= minArbitratorReputation &&
               reputation.totalInteractions >= 50;
    }
    
    /**
     * @dev Get total interactions
     */
    function getTotalInteractions(address user) external view override returns (uint256) {
        return userReputations[user].totalInteractions;
    }
    
    /**
     * @dev Calculate total reputation (aggregates all components)
     */
    function calculateTotalReputation(address user) external override returns (gtUint64) {
        return _calculateWeightedTotal(user);
    }
    
    /**
     * @dev Get user's encrypted total score (for user viewing)
     */
    function getUserEncryptedScore(address user) external view returns (ctUint64) {
        if (msg.sender != user && userReputations[user].isPrivacyEnabled) 
            revert UnauthorizedModule();
        return userReputations[user].userEncryptedScore;
    }
    
    // =============================================================================
    // PRIVACY SETTINGS
    // =============================================================================
    
    /**
     * @dev Set privacy preference
     */
    function setPrivacyEnabled(address user, bool enabled) external override {
        if (msg.sender != user && !hasRole(ADMIN_ROLE, msg.sender)) 
            revert UnauthorizedModule();
        
        userReputations[user].isPrivacyEnabled = enabled;
        emit PrivacyPreferenceUpdated(user, enabled);
    }
    
    /**
     * @dev Check if privacy is enabled
     */
    function isPrivacyEnabled(address user) external view override returns (bool) {
        return userReputations[user].isPrivacyEnabled;
    }
    
    // =============================================================================
    // WEIGHT MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Get component weight
     */
    function getComponentWeight(uint8 componentId) external view override returns (uint256) {
        if (componentId >= MAX_COMPONENTS) revert InvalidComponentId();
        return componentWeights[componentId];
    }
    
    /**
     * @dev Set component weight
     */
    function setComponentWeight(uint8 componentId, uint256 weight) external override onlyRole(ADMIN_ROLE) {
        if (componentId >= MAX_COMPONENTS) revert InvalidComponentId();
        if (weight > BASIS_POINTS) revert WeightExceedsLimit();
        
        componentWeights[componentId] = weight;
        
        // Verify total still equals BASIS_POINTS
        uint256 total = 0;
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            total += componentWeights[i];
        }
        if (total != BASIS_POINTS) revert InvalidBasisPoints();
        
        emit ComponentWeightUpdated(componentId, weight, block.timestamp);
    }
    
    /**
     * @dev Batch update weights
     */
    function batchUpdateWeights(uint256[11] calldata newWeights) external onlyRole(ADMIN_ROLE) {
        uint256 total = 0;
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            if (newWeights[i] > BASIS_POINTS) revert WeightExceedsLimit();
            total += newWeights[i];
        }
        if (total != BASIS_POINTS) revert InvalidBasisPoints();
        
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            componentWeights[i] = newWeights[i];
            emit ComponentWeightUpdated(i, newWeights[i], block.timestamp);
        }
    }
    
    // =============================================================================
    // MODULE MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Update identity module
     */
    function updateIdentityModule(address newModule) external onlyRole(ADMIN_ROLE) {
        if (address(identityModule) != address(0)) {
            _revokeRole(MODULE_ROLE, address(identityModule));
        }
        
        identityModule = IIdentityVerification(newModule);
        
        if (newModule != address(0)) {
            _grantRole(MODULE_ROLE, newModule);
        }
        
        emit ModuleUpdated("identity", newModule);
    }
    
    /**
     * @dev Update trust module
     */
    function updateTrustModule(address newModule) external onlyRole(ADMIN_ROLE) {
        if (address(trustModule) != address(0)) {
            _revokeRole(MODULE_ROLE, address(trustModule));
        }
        
        trustModule = ITrustSystem(newModule);
        
        if (newModule != address(0)) {
            _grantRole(MODULE_ROLE, newModule);
        }
        
        emit ModuleUpdated("trust", newModule);
    }
    
    /**
     * @dev Update referral module
     */
    function updateReferralModule(address newModule) external onlyRole(ADMIN_ROLE) {
        if (address(referralModule) != address(0)) {
            _revokeRole(MODULE_ROLE, address(referralModule));
        }
        
        referralModule = IReferralSystem(newModule);
        
        if (newModule != address(0)) {
            _grantRole(MODULE_ROLE, newModule);
        }
        
        emit ModuleUpdated("referral", newModule);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update minimum reputation requirements
     */
    function updateMinValidatorReputation(uint256 newMin) external onlyRole(ADMIN_ROLE) {
        minValidatorReputation = newMin;
        emit MinimumReputationUpdated("validator", newMin);
    }
    
    function updateMinArbitratorReputation(uint256 newMin) external onlyRole(ADMIN_ROLE) {
        minArbitratorReputation = newMin;
        emit MinimumReputationUpdated("arbitrator", newMin);
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Recalculate total reputation after component update
     */
    function _recalculateTotalReputation(address user) internal {
        gtUint64 weightedTotal = _calculateWeightedTotal(user);
        
        PrivateReputation storage reputation = userReputations[user];
        reputation.encryptedTotalScore = weightedTotal;
        reputation.lastUpdate = block.timestamp;
        reputation.totalInteractions++;
        reputation.isActive = true;
        
        // Encrypt for user viewing
        if (isMpcAvailable) {
            reputation.userEncryptedScore = MpcCore.offBoardToUser(weightedTotal, user);
            
            // Calculate public tier (requires decryption for now)
            uint64 score = MpcCore.decrypt(weightedTotal);
            reputation.publicTier = _calculateTier(score);
        } else {
            uint64 score = uint64(gtUint64.unwrap(weightedTotal));
            reputation.userEncryptedScore = ctUint64.wrap(score);
            reputation.publicTier = _calculateTier(score);
        }
    }
    
    /**
     * @dev Calculate weighted total of all components
     */
    function _calculateWeightedTotal(address user) internal returns (gtUint64) {
        if (isMpcAvailable) {
            return _calculateWeightedTotalMPC(user);
        } else {
            return _calculateWeightedTotalFallback(user);
        }
    }
    
    /**
     * @dev Calculate weighted total using MPC
     */
    function _calculateWeightedTotalMPC(address user) internal returns (gtUint64) {
        gtUint64 total = MpcCore.setPublic64(0);
        
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            if (componentWeights[i] == 0) continue;
            
            gtUint64 componentValue = _getComponentValue(user, i);
            gtUint64 weighted = _applyWeight(componentValue, componentWeights[i]);
            total = MpcCore.add(total, weighted);
        }
        
        return total;
    }
    
    /**
     * @dev Calculate weighted total without MPC
     */
    function _calculateWeightedTotalFallback(address user) internal returns (gtUint64) {
        uint64 totalValue = 0;
        
        for (uint8 i = 0; i < MAX_COMPONENTS; i++) {
            if (componentWeights[i] == 0) continue;
            
            uint64 componentValue = _getComponentValueFallback(user, i);
            
            unchecked {
                uint256 temp = uint256(componentValue) * uint256(componentWeights[i]);
                uint64 weighted = uint64(temp / BASIS_POINTS);
                totalValue += weighted;
            }
        }
        
        return gtUint64.wrap(totalValue);
    }
    
    /**
     * @dev Get component value from appropriate source
     */
    function _getComponentValue(address user, uint8 componentId) internal returns (gtUint64) {
        if (componentId == COMPONENT_IDENTITY_VERIFICATION && address(identityModule) != address(0)) {
            return identityModule.getIdentityScore(user);
        } else if (componentId == COMPONENT_TRUST_SCORE && address(trustModule) != address(0)) {
            return trustModule.getTrustScore(user);
        } else if (componentId == COMPONENT_REFERRAL_ACTIVITY && address(referralModule) != address(0)) {
            return referralModule.getReferralScore(user);
        } else {
            gtUint64 value = componentData[user][componentId].encryptedValue;
            // Initialize if zero
            if (uint64(gtUint64.unwrap(value)) == 0) {
                value = gtUint64.wrap(0);
            }
            return value;
        }
    }
    
    /**
     * @dev Get component value without MPC
     */
    function _getComponentValueFallback(address user, uint8 componentId) internal returns (uint64) {
        if (componentId == COMPONENT_IDENTITY_VERIFICATION && address(identityModule) != address(0)) {
            return uint64(gtUint64.unwrap(identityModule.getIdentityScore(user)));
        } else if (componentId == COMPONENT_TRUST_SCORE && address(trustModule) != address(0)) {
            return uint64(gtUint64.unwrap(trustModule.getTrustScore(user)));
        } else if (componentId == COMPONENT_REFERRAL_ACTIVITY && address(referralModule) != address(0)) {
            return uint64(gtUint64.unwrap(referralModule.getReferralScore(user)));
        } else {
            return uint64(gtUint64.unwrap(componentData[user][componentId].encryptedValue));
        }
    }
    
    /**
     * @dev Apply weight to component value
     */
    function _applyWeight(gtUint64 value, uint256 weight) internal returns (gtUint64) {
        gtUint64 weightEncrypted = MpcCore.setPublic64(uint64(weight));
        gtUint64 weighted = MpcCore.mul(value, weightEncrypted);
        return MpcCore.div(weighted, MpcCore.setPublic64(uint64(BASIS_POINTS)));
    }
    
    /**
     * @dev Calculate reputation tier from score
     */
    function _calculateTier(uint64 score) internal pure returns (uint256) {
        if (score >= TIER_DIAMOND) return 5;
        if (score >= TIER_PLATINUM) return 4;
        if (score >= TIER_GOLD) return 3;
        if (score >= TIER_SILVER) return 2;
        if (score >= TIER_BRONZE) return 1;
        return 0;
    }
}