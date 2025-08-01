// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title UnifiedReputationSystem
 * @author OmniCoin Development Team
 * @notice Consolidated reputation system with merkle proof verification
 * @dev Combines functionality from:
 * - OmniCoinReputationCore
 * - OmniCoinIdentityVerification  
 * - OmniCoinTrustSystem
 * - OmniCoinReferralSystem
 * 
 * This unified contract reduces deployment costs and simplifies integration
 * while maintaining all reputation functionality through event-based architecture
 */
contract UnifiedReputationSystem is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // TYPES & CONSTANTS
    // =============================================================================
    
    // KYC Tiers
    /// @notice KYC tier representing no verification
    uint8 public constant KYC_TIER_NONE = 0;
    /// @notice KYC tier for basic verification level
    uint8 public constant KYC_TIER_BASIC = 1;
    /// @notice KYC tier for verified user status
    uint8 public constant KYC_TIER_VERIFIED = 2;
    /// @notice KYC tier for premium verified users
    uint8 public constant KYC_TIER_PREMIUM = 3;
    
    // Reputation Components
    /// @notice Component ID for successful transaction tracking
    uint8 public constant COMPONENT_TRANSACTION_SUCCESS = 0;
    /// @notice Component ID for transaction dispute resolution
    uint8 public constant COMPONENT_TRANSACTION_DISPUTE = 1;
    /// @notice Component ID for arbitration performance metrics
    uint8 public constant COMPONENT_ARBITRATION_PERFORMANCE = 2;
    /// @notice Component ID for governance participation scoring
    uint8 public constant COMPONENT_GOVERNANCE_PARTICIPATION = 3;
    /// @notice Component ID for validator performance metrics
    uint8 public constant COMPONENT_VALIDATOR_PERFORMANCE = 4;
    /// @notice Component ID for marketplace behavior tracking
    uint8 public constant COMPONENT_MARKETPLACE_BEHAVIOR = 5;
    /// @notice Component ID for community engagement metrics
    uint8 public constant COMPONENT_COMMUNITY_ENGAGEMENT = 6;
    /// @notice Component ID for system uptime reliability
    uint8 public constant COMPONENT_UPTIME_RELIABILITY = 7;
    /// @notice Component ID for trust score calculation
    uint8 public constant COMPONENT_TRUST_SCORE = 8;
    /// @notice Component ID for referral activity tracking
    uint8 public constant COMPONENT_REFERRAL_ACTIVITY = 9;
    /// @notice Component ID for identity verification status
    uint8 public constant COMPONENT_IDENTITY_VERIFICATION = 10;
    
    /// @notice Basis points constant for percentage calculations (100%)
    uint256 public constant BASIS_POINTS = 10000;
    
    // Tier thresholds
    /// @notice Bronze tier reputation threshold
    uint256 public constant TIER_BRONZE = 1000;
    /// @notice Silver tier reputation threshold
    uint256 public constant TIER_SILVER = 5000;
    /// @notice Gold tier reputation threshold
    uint256 public constant TIER_GOLD = 10000;
    /// @notice Platinum tier reputation threshold
    uint256 public constant TIER_PLATINUM = 20000;
    /// @notice Diamond tier reputation threshold
    uint256 public constant TIER_DIAMOND = 50000;
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Role identifier for system administrators
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role identifier for reputation score updaters
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    /// @notice Role identifier for KYC verification providers
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");
    /// @notice Role identifier for trust score updaters
    bytes32 public constant TRUST_UPDATER_ROLE = keccak256("TRUST_UPDATER_ROLE");
    /// @notice Role identifier for referral system managers
    bytes32 public constant REFERRAL_MANAGER_ROLE = keccak256("REFERRAL_MANAGER_ROLE");
    /// @notice Role identifier for Avalanche validator nodes
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    // =============================================================================
    // STATE (Minimal - Merkle Roots Only)
    // =============================================================================
    
    // Reputation merkle roots
    /// @notice Merkle root for user reputation scores
    bytes32 public reputationRoot;
    /// @notice Merkle root for reputation component breakdowns
    bytes32 public componentRoot;
    /// @notice Merkle root for identity verification data
    bytes32 public identityRoot;
    /// @notice Merkle root for trust delegation data
    bytes32 public trustRoot;
    /// @notice Merkle root for referral relationship tree
    bytes32 public referralRoot;
    
    // Epochs and updates
    /// @notice Current epoch number for reputation calculations
    uint256 public currentEpoch;
    /// @notice Block number of last merkle root update
    uint256 public lastRootUpdate;
    
    // Component weights
    /// @notice Array of weights for each reputation component (basis points)
    uint256[11] public componentWeights;
    
    // Configuration
    /// @notice Minimum reputation score required to become a validator
    uint256 public minValidatorReputation = 5000;
    /// @notice Minimum reputation score required to become an arbitrator
    uint256 public minArbitratorReputation = 10000;
    /// @notice Referral bonus percentage in basis points (100 = 1%)
    uint256 public referralBonus = 100;
    /// @notice Maximum depth for referral chain calculation
    uint256 public maxReferralDepth = 3;
    
    // =============================================================================
    // EVENTS - Validator Compatible
    // =============================================================================
    
    // Core Reputation Events
    /// @notice Emitted when a user's reputation is updated
    /// @param user Address of the user whose reputation changed
    /// @param score New reputation score (0 for event-only updates)
    /// @param componentsHash Hash of the component change data
    /// @param timestamp Block timestamp of the update
    event ReputationUpdated(
        address indexed user,
        uint256 indexed score,
        bytes32 componentsHash,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when the reputation merkle root is updated
    /// @param newRoot New merkle root hash
    /// @param epoch Epoch number for this update
    /// @param blockNumber Block number when update occurred
    /// @param timestamp Block timestamp of the update
    event ReputationRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    
    // Identity/KYC Events
    /// @notice Emitted when a user's identity is verified
    /// @param user Address of the verified user
    /// @param tier KYC verification tier achieved
    /// @param dataHash Hash of the verification data
    /// @param timestamp Block timestamp of verification
    event IdentityVerified(
        address indexed user,
        uint8 indexed tier,
        bytes32 dataHash,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a user's identity verification is revoked
    /// @param user Address of the user whose identity was revoked
    /// @param reason Reason for identity revocation
    /// @param timestamp Block timestamp of revocation
    event IdentityRevoked(
        address indexed user,
        string reason,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when the identity verification merkle root is updated
    /// @param newRoot New merkle root hash for identity data
    /// @param epoch Epoch number for this update
    /// @param blockNumber Block number when update occurred
    /// @param timestamp Block timestamp of the update
    event IdentityRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    
    // Trust Events
    /// @notice Emitted when a user's trust score is updated
    /// @param user Address of the user whose trust score changed
    /// @param score New trust score value
    /// @param reason Reason for the trust score update
    /// @param timestamp Block timestamp of the update
    event TrustScoreUpdated(
        address indexed user,
        uint256 indexed score,
        string reason,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when trust is delegated from one user to another
    /// @param delegator Address delegating trust
    /// @param delegate Address receiving delegated trust
    /// @param amount Amount of trust delegated
    /// @param timestamp Block timestamp of delegation
    event TrustDelegated(
        address indexed delegator,
        address indexed delegate,
        uint256 indexed amount,
        uint256 timestamp
    );
    
    /// @notice Emitted when trust delegation is revoked
    /// @param delegator Address revoking trust delegation
    /// @param delegate Address losing delegated trust
    /// @param timestamp Block timestamp of revocation
    event TrustRevoked(
        address indexed delegator,
        address indexed delegate,
        uint256 indexed timestamp
    );
    
    // Referral Events
    /// @notice Emitted when a new referral relationship is created
    /// @param referrer Address of the referring user
    /// @param referee Address of the referred user
    /// @param timestamp Block timestamp of referral creation
    event ReferralCreated(
        address indexed referrer,
        address indexed referee,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when referral rewards are claimed
    /// @param referrer Address claiming the referral reward
    /// @param amount Amount of reward claimed
    /// @param timestamp Block timestamp of reward claim
    event ReferralRewardClaimed(
        address indexed referrer,
        uint256 indexed amount,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when the referral tree merkle root is updated
    /// @param newRoot New merkle root hash for referral tree
    /// @param totalReferrals Total number of referrals in the system
    /// @param timestamp Block timestamp of the update
    event ReferralTreeUpdated(
        bytes32 indexed newRoot,
        uint256 indexed totalReferrals,
        uint256 indexed timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidProof();
    error InvalidComponentId();
    error InvalidTier();
    error AlreadyVerified();
    error NotVerified();
    error InvalidReferrer();
    error SelfReferral();
    error CircularReferral();
    error MaxDepthExceeded();
    error AlreadyReferred();
    error NotAvalancheValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        if (!hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) && !_isAvalancheValidator(msg.sender)) {
            revert NotAvalancheValidator();
        }
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /// @notice Initialize the unified reputation system
    /// @param _admin Address to receive admin roles
    /// @param _registry Address of the registry contract
    constructor(address _admin, address _registry) RegistryAware(_registry) {
        if (_admin == address(0)) revert InvalidReferrer();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REPUTATION_UPDATER_ROLE, _admin);
        _grantRole(KYC_PROVIDER_ROLE, _admin);
        _grantRole(TRUST_UPDATER_ROLE, _admin);
        _grantRole(REFERRAL_MANAGER_ROLE, _admin);
        
        // Initialize default weights
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
    }
    
    // =============================================================================
    // REPUTATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update reputation component
     * @dev Emits event for validator indexing
     * @param user Address of user whose reputation is being updated
     * @param componentId ID of the reputation component (0-10)
     * @param change Positive or negative change to apply
     * @param reason Description of why the reputation is being updated
     */
    function updateReputation(
        address user,
        uint8 componentId,
        int256 change,
        string calldata reason
    ) external nonReentrant whenNotPaused onlyRole(REPUTATION_UPDATER_ROLE) {
        if (componentId > 10) revert InvalidComponentId();
        
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(
            user,
            0, // Score computed off-chain
            keccak256(abi.encodePacked(componentId, change, reason)),
            block.timestamp
        );
    }
    
    /**
     * @notice Batch update reputations for multiple users
     * @param users Array of user addresses to update
     * @param componentIds Array of component IDs for each update
     * @param changes Array of reputation changes to apply
     * @param reasons Array of reasons for each reputation update
     */
    function batchUpdateReputation(
        address[] calldata users,
        uint8[] calldata componentIds,
        int256[] calldata changes,
        string[] calldata reasons
    ) external nonReentrant whenNotPaused onlyRole(REPUTATION_UPDATER_ROLE) {
        if (users.length != componentIds.length || 
            users.length != changes.length || 
            users.length != reasons.length) {
            revert InvalidProof();
        }
        
        for (uint256 i = 0; i < users.length; ++i) {
            if (componentIds[i] > 10) revert InvalidComponentId();
            // solhint-disable-next-line not-rely-on-time
            emit ReputationUpdated(
                users[i],
                0,
                keccak256(abi.encodePacked(componentIds[i], changes[i], reasons[i])),
                block.timestamp
            );
        }
    }
    
    // =============================================================================
    // IDENTITY/KYC FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify user identity
     * @dev Only emits event, actual verification off-chain
     * @param user Address of user to verify
     * @param tier KYC tier level to assign (1-3)
     * @param dataHash Hash of the verification data
     */
    function verifyIdentity(
        address user,
        uint8 tier,
        bytes32 dataHash
    ) external nonReentrant whenNotPaused onlyRole(KYC_PROVIDER_ROLE) {
        if (tier < KYC_TIER_BASIC || tier > KYC_TIER_PREMIUM) revert InvalidTier();
        
        // solhint-disable-next-line not-rely-on-time
        emit IdentityVerified(user, tier, dataHash, block.timestamp);
        
        // Update identity component
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(
            user,
            0,
            keccak256(abi.encodePacked(COMPONENT_IDENTITY_VERIFICATION, tier)),
            block.timestamp
        );
    }
    
    /**
     * @notice Revoke user identity verification
     * @param user Address of user whose identity is being revoked
     * @param reason Reason for identity revocation
     */
    function revokeIdentity(
        address user,
        string calldata reason
    ) external nonReentrant whenNotPaused onlyRole(KYC_PROVIDER_ROLE) {
        // solhint-disable-next-line not-rely-on-time
        emit IdentityRevoked(user, reason, block.timestamp);
        
        // Update identity component to 0
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(
            user,
            0,
            keccak256(abi.encodePacked(COMPONENT_IDENTITY_VERIFICATION, int256(0))),
            block.timestamp
        );
    }
    
    // =============================================================================
    // TRUST FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update trust score
     * @dev Part of DPoS/COTI PoT integration
     * @param user Address of user whose trust score is being updated
     * @param score New trust score value
     * @param reason Reason for the trust score update
     */
    function updateTrustScore(
        address user,
        uint256 score,
        string calldata reason
    ) external nonReentrant whenNotPaused onlyRole(TRUST_UPDATER_ROLE) {
        // solhint-disable-next-line not-rely-on-time
        emit TrustScoreUpdated(user, score, reason, block.timestamp);
        
        // Update trust component
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(
            user,
            0,
            keccak256(abi.encodePacked(COMPONENT_TRUST_SCORE, int256(score))),
            block.timestamp
        );
    }
    
    /**
     * @notice Delegate trust (for DPoS consensus mechanism)
     * @param delegate Address to delegate trust to
     * @param amount Amount of trust to delegate
     */
    function delegateTrust(
        address delegate,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        // solhint-disable-next-line not-rely-on-time
        emit TrustDelegated(msg.sender, delegate, amount, block.timestamp);
    }
    
    /**
     * @notice Revoke trust delegation
     * @param delegate Address to revoke trust delegation from
     */
    function revokeTrust(address delegate) external nonReentrant whenNotPaused {
        // solhint-disable-next-line not-rely-on-time
        emit TrustRevoked(msg.sender, delegate, block.timestamp);
    }
    
    // =============================================================================
    // REFERRAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create referral relationship
     * @dev Only emits event, tracking done off-chain
     * @param referrer Address of the user who referred this caller
     */
    function createReferral(
        address referrer
    ) external nonReentrant whenNotPaused {
        if (referrer == address(0)) revert InvalidReferrer();
        if (referrer == msg.sender) revert SelfReferral();
        
        // solhint-disable-next-line not-rely-on-time
        emit ReferralCreated(referrer, msg.sender, block.timestamp);
        
        // Update referral component for referrer
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(
            referrer,
            0,
            keccak256(abi.encodePacked(COMPONENT_REFERRAL_ACTIVITY, int256(1))),
            block.timestamp
        );
    }
    
    /**
     * @notice Claim referral rewards
     * @dev Requires merkle proof from validator
     * @param amount Amount of referral reward to claim
     * @param proof Merkle proof for reward eligibility
     */
    function claimReferralReward(
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, currentEpoch));
        if (!_verifyProof(proof, referralRoot, leaf)) revert InvalidProof();
        
        // Transfer handled by treasury/fee contract
        // solhint-disable-next-line not-rely-on-time
        emit ReferralRewardClaimed(msg.sender, amount, block.timestamp);
    }
    
    // =============================================================================
    // MERKLE ROOT UPDATES (Validator Only)
    // =============================================================================
    
    /**
     * @notice Update reputation merkle root
     * @param newRoot New merkle root hash for reputation data
     * @param epoch New epoch number (must be currentEpoch + 1)
     */
    function updateReputationRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        if (epoch != currentEpoch + 1) revert InvalidProof();
        
        reputationRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        // solhint-disable-next-line not-rely-on-time
        emit ReputationRootUpdated(newRoot, epoch, block.number, block.timestamp);
    }
    
    /**
     * @notice Update component breakdown root
     * @param newRoot New merkle root hash for component breakdown data
     */
    function updateComponentRoot(bytes32 newRoot) external onlyAvalancheValidator {
        componentRoot = newRoot;
    }
    
    /**
     * @notice Update identity verification root
     * @param newRoot New merkle root hash for identity verification data
     * @param epoch Epoch number for this update
     */
    function updateIdentityRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        identityRoot = newRoot;
        // solhint-disable-next-line not-rely-on-time
        emit IdentityRootUpdated(newRoot, epoch, block.number, block.timestamp);
    }
    
    /**
     * @notice Update trust delegation root
     * @param newRoot New merkle root hash for trust delegation data
     */
    function updateTrustRoot(bytes32 newRoot) external onlyAvalancheValidator {
        trustRoot = newRoot;
    }
    
    /**
     * @notice Update referral tree root
     * @param newRoot New merkle root hash for referral tree data
     * @param totalReferrals Total number of referrals in the system
     */
    function updateReferralRoot(
        bytes32 newRoot,
        uint256 totalReferrals
    ) external onlyAvalancheValidator {
        referralRoot = newRoot;
        // solhint-disable-next-line not-rely-on-time
        emit ReferralTreeUpdated(newRoot, totalReferrals, block.timestamp);
    }
    
    // =============================================================================
    // VERIFICATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify reputation score using merkle proof
     * @param user Address of the user to verify
     * @param score Reputation score to verify
     * @param participationScore Participation score to verify
     * @param proof Merkle proof for verification
     * @return True if the reputation data is valid, false otherwise
     */
    function verifyReputation(
        address user,
        uint256 score,
        uint256 participationScore,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user, score, participationScore, currentEpoch));
        return _verifyProof(proof, reputationRoot, leaf);
    }
    
    /**
     * @notice Verify identity/KYC status using merkle proof
     * @param user Address of the user to verify
     * @param tier KYC tier to verify
     * @param proof Merkle proof for verification
     * @return True if the identity verification is valid, false otherwise
     */
    function verifyIdentity(
        address user,
        uint8 tier,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user, tier, currentEpoch));
        return _verifyProof(proof, identityRoot, leaf);
    }
    
    /**
     * @notice Verify trust delegation using merkle proof
     * @param delegator Address that delegated trust
     * @param delegate Address that received delegated trust
     * @param amount Amount of trust delegated
     * @param proof Merkle proof for verification
     * @return True if the trust delegation is valid, false otherwise
     */
    function verifyTrustDelegation(
        address delegator,
        address delegate,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(delegator, delegate, amount, currentEpoch));
        return _verifyProof(proof, trustRoot, leaf);
    }
    
    /**
     * @notice Verify referral relationship using merkle proof
     * @param referrer Address of the referrer
     * @param referee Address of the referred user
     * @param depth Depth in the referral chain
     * @param proof Merkle proof for verification
     * @return True if the referral relationship is valid, false otherwise
     */
    function verifyReferral(
        address referrer,
        address referee,
        uint256 depth,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(referrer, referee, depth, currentEpoch));
        return _verifyProof(proof, referralRoot, leaf);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if user meets validator requirements
     * @param user Address of the user to check
     * @param score User's reputation score
     * @param proof Merkle proof for score verification
     * @return True if user meets validator requirements, false otherwise
     */
    function meetsValidatorRequirements(
        address user,
        uint256 score,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (score < minValidatorReputation) return false;
        bytes32 leaf = keccak256(abi.encodePacked(user, score, uint256(0), currentEpoch));
        return _verifyProof(proof, reputationRoot, leaf);
    }
    
    /**
     * @notice Check if user meets arbitrator requirements
     * @param user Address of the user to check
     * @param score User's reputation score
     * @param proof Merkle proof for score verification
     * @return True if user meets arbitrator requirements, false otherwise
     */
    function meetsArbitratorRequirements(
        address user,
        uint256 score,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (score < minArbitratorReputation) return false;
        bytes32 leaf = keccak256(abi.encodePacked(user, score, uint256(0), currentEpoch));
        return _verifyProof(proof, reputationRoot, leaf);
    }
    
    // =============================================================================
    // PURE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get reputation tier from score
     * @param score Reputation score to evaluate
     * @return Tier number (0-5, where 5 is Diamond tier)
     */
    function getReputationTier(uint256 score) external pure returns (uint256) {
        if (score > TIER_DIAMOND - 1) return 5;
        if (score > TIER_PLATINUM - 1) return 4;
        if (score > TIER_GOLD - 1) return 3;
        if (score > TIER_SILVER - 1) return 2;
        if (score > TIER_BRONZE - 1) return 1;
        return 0;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update component weights for reputation calculation
     * @param newWeights Array of 11 weights in basis points (must sum to 10000)
     */
    function updateComponentWeights(uint256[11] calldata newWeights) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        uint256 sum = 0;
        for (uint256 i = 0; i < 11; ++i) {
            sum += newWeights[i];
        }
        if (sum != BASIS_POINTS) revert InvalidProof();
        componentWeights = newWeights;
    }
    
    /**
     * @notice Update system configuration parameters
     * @param _minValidator Minimum reputation required for validators
     * @param _minArbitrator Minimum reputation required for arbitrators
     * @param _referralBonus Referral bonus percentage in basis points
     * @param _maxReferralDepth Maximum depth for referral chain calculations
     */
    function updateConfiguration(
        uint256 _minValidator,
        uint256 _minArbitrator,
        uint256 _referralBonus,
        uint256 _maxReferralDepth
    ) external onlyRole(ADMIN_ROLE) {
        minValidatorReputation = _minValidator;
        minArbitratorReputation = _minArbitrator;
        referralBonus = _referralBonus;
        maxReferralDepth = _maxReferralDepth;
    }
    
    /**
     * @notice Emergency pause all system functions
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Resume system operations after pause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify merkle proof for given leaf against root
     * @param proof Array of proof hashes
     * @param root Merkle root to verify against
     * @param leaf Leaf node to verify
     * @return True if proof is valid, false otherwise
     */
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement || computedHash == proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
    
    /**
     * @notice Check if account is registered as Avalanche validator
     * @param account Address to check
     * @return True if account is an Avalanche validator, false otherwise
     */
    function _isAvalancheValidator(address account) internal view returns (bool) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
}