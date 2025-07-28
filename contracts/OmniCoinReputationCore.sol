// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable not-rely-on-time */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {OmniCoinConfig} from "./OmniCoinConfig.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {
    IReputationCore,
    IIdentityVerification,
    ITrustSystem,
    IReferralSystem
} from "./interfaces/IReputationSystem.sol";

/**
 * @title OmniCoinReputationCore
 * @author OmniCoin Development Team
 * @notice Core reputation aggregation contract that coordinates all reputation modules
 * @dev Core reputation aggregation contract that coordinates all reputation modules
 * 
 * This is the main entry point for reputation queries and updates.
 * It aggregates scores from:
 * - Identity Verification System
 * - Trust System (DPoS/COTI PoT)
 * - Referral System
 * - Standard reputation components
 */
contract OmniCoinReputationCore is IReputationCore, AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /// @notice Private reputation data structure
    struct PrivateReputation {
        gtUint64 encryptedTotalScore;       // Private: total reputation score
        ctUint64 userEncryptedScore;        // Private: score encrypted for user viewing
        uint256 publicTier;                 // Public: reputation tier for validator selection
        uint256 lastUpdate;                 // Public: timestamp of last update
        uint256 totalInteractions;          // Public: number of interactions
        bool isPrivacyEnabled;              // Public: user's privacy preference
        bool isActive;                      // Public: whether reputation is active
    }
    
    /// @notice Reputation component data structure
    struct ReputationComponent {
        gtUint64 encryptedValue;            // Private: component value
        ctUint64 userEncryptedValue;        // Private: value encrypted for user viewing
        uint256 interactionCount;           // Public: number of interactions
        uint256 lastUpdate;                 // Public: last update timestamp
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Admin role identifier for privileged operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Reputation updater role for updating reputation components
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    /// @notice Module role for integrated reputation modules
    bytes32 public constant MODULE_ROLE = keccak256("MODULE_ROLE");
    
    // Component IDs (inherited from interface)
    /// @notice Component ID for transaction success score
    uint8 public constant override COMPONENT_TRANSACTION_SUCCESS = 0;
    /// @notice Component ID for transaction dispute score
    uint8 public constant override COMPONENT_TRANSACTION_DISPUTE = 1;
    /// @notice Component ID for arbitration performance score
    uint8 public constant override COMPONENT_ARBITRATION_PERFORMANCE = 2;
    /// @notice Component ID for governance participation score
    uint8 public constant override COMPONENT_GOVERNANCE_PARTICIPATION = 3;
    /// @notice Component ID for validator performance score
    uint8 public constant override COMPONENT_VALIDATOR_PERFORMANCE = 4;
    /// @notice Component ID for marketplace behavior score
    uint8 public constant override COMPONENT_MARKETPLACE_BEHAVIOR = 5;
    /// @notice Component ID for community engagement score
    uint8 public constant override COMPONENT_COMMUNITY_ENGAGEMENT = 6;
    /// @notice Component ID for uptime reliability score
    uint8 public constant override COMPONENT_UPTIME_RELIABILITY = 7;
    /// @notice Component ID for trust score
    uint8 public constant override COMPONENT_TRUST_SCORE = 8;
    /// @notice Component ID for referral activity score
    uint8 public constant override COMPONENT_REFERRAL_ACTIVITY = 9;
    /// @notice Component ID for identity verification score
    uint8 public constant override COMPONENT_IDENTITY_VERIFICATION = 10;
    
    /// @notice Maximum number of reputation components
    uint8 public constant MAX_COMPONENTS = 11;
    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;
    
    // Reputation tier thresholds
    /// @notice Bronze tier threshold
    uint256 public constant TIER_BRONZE = 1000;
    /// @notice Silver tier threshold
    uint256 public constant TIER_SILVER = 5000;
    /// @notice Gold tier threshold
    uint256 public constant TIER_GOLD = 10000;
    /// @notice Platinum tier threshold
    uint256 public constant TIER_PLATINUM = 20000;
    /// @notice Diamond tier threshold
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
    
    /// @notice MPC availability flag
    bool public override isMpcAvailable;
    
    /// @notice User reputations mapping
    mapping(address => PrivateReputation) public userReputations;
    
    /// @notice Component data: user => component => data
    mapping(address => mapping(uint8 => ReputationComponent)) public componentData;
    
    /// @notice Component weights (basis points, must sum to 10000)
    uint256[11] public componentWeights;
    
    /// @notice Identity verification module address
    IIdentityVerification public identityModule;
    /// @notice Trust system module address
    ITrustSystem public trustModule;
    /// @notice Referral system module address
    IReferralSystem public referralModule;
    
    /// @notice Configuration contract instance (deprecated, use registry)
    OmniCoinConfig public config;
    
    /// @notice Minimum reputation score required for validators
    uint256 public minValidatorReputation = 5000;
    
    /// @notice Minimum reputation score required for arbitrators
    uint256 public minArbitratorReputation = 10000;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when a reputation module is updated
    /// @param moduleType Type of module being updated
    /// @param newModule Address of the new module
    event ModuleUpdated(string moduleType, address indexed newModule);
    
    /// @notice Emitted when minimum reputation requirements are updated
    /// @param role The role affected (validator or arbitrator)
    /// @param newMinimum New minimum reputation required
    event MinimumReputationUpdated(string role, uint256 indexed newMinimum);
    
    /// @notice Emitted when a user's privacy preference is updated
    /// @param user Address of the user
    /// @param privacyEnabled Whether privacy is enabled
    event PrivacyPreferenceUpdated(address indexed user, bool indexed privacyEnabled);
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /// @notice Initializes the reputation core contract
    /// @param _admin Address to receive admin privileges
    /// @param _registry Address of the registry contract
    /// @param _config Address of the configuration contract (deprecated, use registry)
    /// @param _identityModule Address of identity verification module (can be zero)
    /// @param _trustModule Address of trust system module (can be zero)
    /// @param _referralModule Address of referral system module (can be zero)
    constructor(
        address _admin,
        address _registry,
        address _config,
        address _identityModule,
        address _trustModule,
        address _referralModule
    ) RegistryAware(_registry) {
        if (_admin == address(0)) {
            revert InvalidAddress();
        }
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REPUTATION_UPDATER_ROLE, _admin);
        
        // Keep config for backwards compatibility
        if (_config != address(0)) {
            config = OmniCoinConfig(_config);
        }
        
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
     * @notice Set MPC availability status
     * @dev Set MPC availability
     * @param _available Whether MPC is available
     */
    function setMpcAvailability(bool _available) external override onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    // =============================================================================
    // REPUTATION UPDATES
    // =============================================================================
    
    /**
     * @notice Update a specific reputation component for a user
     * @dev Update reputation component (called by modules or authorized updaters)
     * @param user Address of the user whose reputation is being updated
     * @param componentId ID of the component to update
     * @param value Encrypted value to set for the component
     */
    function updateReputationComponent(
        address user,
        uint8 componentId,
        itUint64 calldata value
    ) external override whenNotPaused nonReentrant {
        if (!hasRole(MODULE_ROLE, msg.sender) && 
            !hasRole(REPUTATION_UPDATER_ROLE, msg.sender)) {
            revert UnauthorizedModule();
        }
        if (componentId > MAX_COMPONENTS - 1) {
            revert InvalidComponentId();
        }
        
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
        ++component.interactionCount;
        component.lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        
        // Encrypt for user viewing
        if (isMpcAvailable) {
            component.userEncryptedValue = MpcCore.offBoardToUser(gtValue, user);
        } else {
            component.userEncryptedValue = ctUint64.wrap(uint64(gtUint64.unwrap(gtValue)));
        }
        
        // Recalculate total reputation
        _recalculateTotalReputation(user);
        
        emit ReputationUpdated(user, componentId, block.timestamp); // solhint-disable-line
    }
    
    // =============================================================================
    // REPUTATION QUERIES
    // =============================================================================
    
    /**
     * @notice Get user's public reputation tier
     * @dev Get user's public reputation tier
     * @param user Address to query
     * @return User's reputation tier (0-5)
     */
    function getPublicReputationTier(address user) external view override returns (uint256) {
        return userReputations[user].publicTier;
    }
    
    /**
     * @notice Check if user is eligible to be a validator
     * @dev Check if user is eligible to be a validator
     * @param user Address to check
     * @return True if eligible, false otherwise
     */
    function isEligibleValidator(address user) external view override returns (bool) {
        // Check testnet mode first
        if (_getConfig().isTestnetMode()) {
            return true;
        }
        
        PrivateReputation storage reputation = userReputations[user];
        return reputation.isActive && 
               reputation.publicTier > minValidatorReputation - 1 &&
               reputation.totalInteractions > 9;
    }
    
    /**
     * @notice Check if user is eligible to be an arbitrator
     * @dev Check if user is eligible to be an arbitrator
     * @param user Address to check
     * @return True if eligible, false otherwise
     */
    function isEligibleArbitrator(address user) external view override returns (bool) {
        // Check testnet mode first
        if (_getConfig().isTestnetMode()) {
            return true;
        }
        
        PrivateReputation storage reputation = userReputations[user];
        return reputation.isActive && 
               reputation.publicTier > minArbitratorReputation - 1 &&
               reputation.totalInteractions > 49;
    }
    
    /**
     * @notice Get total number of interactions for a user
     * @dev Get total interactions
     * @param user Address to query
     * @return Total number of interactions
     */
    function getTotalInteractions(address user) external view override returns (uint256) {
        return userReputations[user].totalInteractions;
    }
    
    /**
     * @notice Calculate total reputation score by aggregating all components
     * @dev Calculate total reputation (aggregates all components)
     * @param user Address to calculate reputation for
     * @return Encrypted total reputation score
     */
    function calculateTotalReputation(address user) external override returns (gtUint64) {
        return _calculateWeightedTotal(user);
    }
    
    /**
     * @notice Get user's encrypted total score (for user viewing)
     * @dev Get user's encrypted total score (for user viewing)
     * @param user Address to query
     * @return User's encrypted score
     */
    function getUserEncryptedScore(address user) external view returns (ctUint64) {
        if (msg.sender != user && userReputations[user].isPrivacyEnabled) {
            revert UnauthorizedModule();
        }
        return userReputations[user].userEncryptedScore;
    }
    
    // =============================================================================
    // PRIVACY SETTINGS
    // =============================================================================
    
    /**
     * @notice Set privacy preference for a user
     * @dev Set privacy preference
     * @param user Address to set preference for
     * @param enabled Whether to enable privacy
     */
    function setPrivacyEnabled(address user, bool enabled) external override {
        if (msg.sender != user && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedModule();
        }
        
        userReputations[user].isPrivacyEnabled = enabled;
        emit PrivacyPreferenceUpdated(user, enabled);
    }
    
    /**
     * @notice Check if privacy is enabled for a user
     * @dev Check if privacy is enabled
     * @param user Address to check
     * @return True if privacy is enabled, false otherwise
     */
    function isPrivacyEnabled(address user) external view override returns (bool) {
        return userReputations[user].isPrivacyEnabled;
    }
    
    // =============================================================================
    // WEIGHT MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Get the weight of a specific component
     * @dev Get component weight
     * @param componentId ID of the component
     * @return Weight in basis points
     */
    function getComponentWeight(uint8 componentId) external view override returns (uint256) {
        if (componentId > MAX_COMPONENTS - 1) {
            revert InvalidComponentId();
        }
        return componentWeights[componentId];
    }
    
    /**
     * @notice Set the weight of a specific component
     * @dev Set component weight
     * @param componentId ID of the component
     * @param weight New weight in basis points
     */
    function setComponentWeight(uint8 componentId, uint256 weight) external override onlyRole(ADMIN_ROLE) {
        if (componentId > MAX_COMPONENTS - 1) {
            revert InvalidComponentId();
        }
        if (weight > BASIS_POINTS) {
            revert WeightExceedsLimit();
        }
        
        componentWeights[componentId] = weight;
        
        // Verify total still equals BASIS_POINTS
        uint256 total = 0;
        for (uint8 i = 0; i < MAX_COMPONENTS; ++i) {
            total += componentWeights[i];
        }
        if (total != BASIS_POINTS) {
            revert InvalidBasisPoints();
        }
        
        emit ComponentWeightUpdated(componentId, weight, block.timestamp); // solhint-disable-line
    }
    
    /**
     * @notice Batch update multiple component weights
     * @dev Batch update weights
     * @param newWeights Array of new weights (must sum to BASIS_POINTS)
     */
    function batchUpdateWeights(uint256[11] calldata newWeights) external onlyRole(ADMIN_ROLE) {
        uint256 total = 0;
        for (uint8 i = 0; i < MAX_COMPONENTS; ++i) {
            if (newWeights[i] > BASIS_POINTS) {
                revert WeightExceedsLimit();
            }
            total += newWeights[i];
        }
        if (total != BASIS_POINTS) {
            revert InvalidBasisPoints();
        }
        
        for (uint8 i = 0; i < MAX_COMPONENTS; ++i) {
            componentWeights[i] = newWeights[i];
            emit ComponentWeightUpdated(i, newWeights[i], block.timestamp); // solhint-disable-line
        }
    }
    
    // =============================================================================
    // MODULE MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Update the identity verification module
     * @dev Update identity module
     * @param newModule Address of the new identity module
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
     * @notice Update the trust system module
     * @dev Update trust module
     * @param newModule Address of the new trust module
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
     * @notice Update the referral system module
     * @dev Update referral module
     * @param newModule Address of the new referral module
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
     * @notice Update minimum reputation requirement for validators
     * @dev Update minimum reputation requirements
     * @param newMin New minimum reputation score
     */
    function updateMinValidatorReputation(uint256 newMin) external onlyRole(ADMIN_ROLE) {
        minValidatorReputation = newMin;
        emit MinimumReputationUpdated("validator", newMin);
    }
    
    /**
     * @notice Update minimum reputation requirement for arbitrators
     * @param newMin New minimum reputation score
     */
    function updateMinArbitratorReputation(uint256 newMin) external onlyRole(ADMIN_ROLE) {
        minArbitratorReputation = newMin;
        emit MinimumReputationUpdated("arbitrator", newMin);
    }
    
    /**
     * @notice Emergency pause the contract
     * @dev Emergency pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause the contract
     * @dev Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get config contract from registry
     * @dev Helper to get config contract
     * @return Configuration contract instance
     */
    function _getConfig() internal returns (OmniCoinConfig) {
        if (address(config) != address(0)) {
            return config; // Backwards compatibility
        }
        address configAddr = _getContract(registry.OMNICOIN_CONFIG());
        return OmniCoinConfig(configAddr);
    }
    
    /**
     * @notice Recalculate total reputation after component update
     * @dev Recalculate total reputation after component update
     * @param user Address to recalculate reputation for
     */
    function _recalculateTotalReputation(address user) internal {
        gtUint64 weightedTotal = _calculateWeightedTotal(user);
        
        PrivateReputation storage reputation = userReputations[user];
        reputation.encryptedTotalScore = weightedTotal;
        reputation.lastUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        ++reputation.totalInteractions;
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
     * @notice Calculate weighted total of all components
     * @dev Calculate weighted total of all components
     * @param user Address to calculate for
     * @return Weighted total reputation score
     */
    function _calculateWeightedTotal(address user) internal returns (gtUint64) {
        if (isMpcAvailable) {
            return _calculateWeightedTotalMPC(user);
        } else {
            return _calculateWeightedTotalFallback(user);
        }
    }
    
    /**
     * @notice Calculate weighted total using MPC
     * @dev Calculate weighted total using MPC
     * @param user Address to calculate for
     * @return Weighted total reputation score
     */
    function _calculateWeightedTotalMPC(address user) internal returns (gtUint64) {
        gtUint64 total = MpcCore.setPublic64(0);
        
        for (uint8 i = 0; i < MAX_COMPONENTS; ++i) {
            if (componentWeights[i] == 0) {
                continue;
            }
            
            gtUint64 componentValue = _getComponentValue(user, i);
            gtUint64 weighted = _applyWeight(componentValue, componentWeights[i]);
            total = MpcCore.add(total, weighted);
        }
        
        return total;
    }
    
    /**
     * @notice Calculate weighted total without MPC
     * @dev Calculate weighted total without MPC
     * @param user Address to calculate for
     * @return Weighted total reputation score
     */
    function _calculateWeightedTotalFallback(address user) internal returns (gtUint64) {
        uint64 totalValue = 0;
        
        for (uint8 i = 0; i < MAX_COMPONENTS; ++i) {
            if (componentWeights[i] == 0) {
                continue;
            }
            
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
     * @notice Get component value from appropriate source
     * @dev Get component value from appropriate source
     * @param user Address to get value for
     * @param componentId Component ID to retrieve
     * @return Component value
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
     * @notice Get component value without MPC
     * @dev Get component value without MPC
     * @param user Address to get value for
     * @param componentId Component ID to retrieve
     * @return Component value
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
     * @notice Apply weight to component value
     * @dev Apply weight to component value
     * @param value Component value to weight
     * @param weight Weight to apply (in basis points)
     * @return Weighted value
     */
    function _applyWeight(gtUint64 value, uint256 weight) internal returns (gtUint64) {
        gtUint64 weightEncrypted = MpcCore.setPublic64(uint64(weight));
        gtUint64 weighted = MpcCore.mul(value, weightEncrypted);
        return MpcCore.div(weighted, MpcCore.setPublic64(uint64(BASIS_POINTS)));
    }
    
    /**
     * @notice Calculate reputation tier from score
     * @dev Calculate reputation tier from score
     * @param score Reputation score
     * @return Tier level (0-5)
     */
    function _calculateTier(uint64 score) internal pure returns (uint256) {
        if (score > TIER_DIAMOND - 1) {
            return 5;
        }
        if (score > TIER_PLATINUM - 1) {
            return 4;
        }
        if (score > TIER_GOLD - 1) {
            return 3;
        }
        if (score > TIER_SILVER - 1) {
            return 2;
        }
        if (score > TIER_BRONZE - 1) {
            return 1;
        }
        return 0;
    }
}