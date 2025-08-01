// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinReputationCore - Avalanche Validator Integrated Version
 * @author OmniCoin Development Team
 * @notice Merkle-proof based reputation system integrated with AvalancheValidator
 * @dev Major changes from original:
 * - Removed all component storage - computed off-chain
 * - Removed user reputation mappings - only merkle roots
 * - Removed privacy features - handled at computation layer
 * - Events only for reputation updates
 * - Merkle proof verification for reputation queries
 * 
 * State Reduction: ~95% less storage
 * All reputation computation done by validator network
 */
contract OmniCoinReputationCore is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // MINIMAL STATE - ONLY MERKLE ROOTS
    // =============================================================================
    
    // Merkle roots for reputation data
    bytes32 public reputationRoot;      // Current reputation merkle root
    bytes32 public componentRoot;       // Component breakdown merkle root
    uint256 public lastRootUpdate;      // Block number of last update
    uint256 public currentEpoch;        // Current reputation epoch
    
    // Configuration (minimal)
    uint256 public minValidatorReputation = 5000;
    uint256 public minArbitratorReputation = 10000;
    
    // Component weights (kept for reference)
    uint256[11] public componentWeights;
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    // Component IDs
    uint8 public constant COMPONENT_TRANSACTION_SUCCESS = 0;
    uint8 public constant COMPONENT_TRANSACTION_DISPUTE = 1;
    uint8 public constant COMPONENT_ARBITRATION_PERFORMANCE = 2;
    uint8 public constant COMPONENT_GOVERNANCE_PARTICIPATION = 3;
    uint8 public constant COMPONENT_VALIDATOR_PERFORMANCE = 4;
    uint8 public constant COMPONENT_MARKETPLACE_BEHAVIOR = 5;
    uint8 public constant COMPONENT_COMMUNITY_ENGAGEMENT = 6;
    uint8 public constant COMPONENT_UPTIME_RELIABILITY = 7;
    uint8 public constant COMPONENT_TRUST_SCORE = 8;
    uint8 public constant COMPONENT_REFERRAL_ACTIVITY = 9;
    uint8 public constant COMPONENT_IDENTITY_VERIFICATION = 10;
    
    uint256 public constant BASIS_POINTS = 10000;
    
    // Tier thresholds (for reference)
    uint256 public constant TIER_BRONZE = 1000;
    uint256 public constant TIER_SILVER = 5000;
    uint256 public constant TIER_GOLD = 10000;
    uint256 public constant TIER_PLATINUM = 20000;
    uint256 public constant TIER_DIAMOND = 50000;
    
    // =============================================================================
    // EVENTS - VALIDATOR COMPATIBLE
    // =============================================================================
    
    /**
     * @notice Reputation update event for validator indexing
     */
    event ReputationUpdated(
        address indexed user,
        uint256 score,
        bytes32 componentsHash,
        uint256 timestamp
    );
    
    /**
     * @notice Reputation root updated by validator
     */
    event ReputationRootUpdated(
        bytes32 indexed newRoot,
        uint256 epoch,
        uint256 blockNumber,
        uint256 timestamp
    );
    
    /**
     * @notice Component root updated by validator
     */
    event ComponentRootUpdated(
        bytes32 indexed newRoot,
        uint256 epoch,
        uint256 blockNumber,
        uint256 timestamp
    );
    
    /**
     * @notice Component weight updated
     */
    event ComponentWeightUpdated(
        uint8 indexed componentId,
        uint256 oldWeight,
        uint256 newWeight,
        uint256 timestamp
    );
    
    /**
     * @notice Minimum reputation updated
     */
    event MinimumReputationUpdated(
        string role,
        uint256 newMinimum,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidProof();
    error InvalidComponentId();
    error WeightsSumIncorrect();
    error EpochMismatch();
    error NotAvalancheValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        require(
            hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) ||
            _isAvalancheValidator(msg.sender),
            "Only Avalanche validators"
        );
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _admin,
        address _registry
    ) RegistryAware(_registry) {
        require(_admin != address(0), "Invalid admin");
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(REPUTATION_UPDATER_ROLE, _admin);
        
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
    // REPUTATION UPDATES - EVENTS ONLY
    // =============================================================================
    
    /**
     * @notice Update reputation for a user
     * @dev Only emits event, actual computation done off-chain
     */
    function updateReputation(
        address user,
        uint8 componentId,
        int256 change,
        string calldata reason
    ) external nonReentrant whenNotPaused onlyRole(REPUTATION_UPDATER_ROLE) {
        require(componentId < 11, "Invalid component");
        
        // Emit event for validator indexing
        // Score and components hash will be computed by validator
        emit ReputationUpdated(
            user,
            0, // Actual score computed off-chain
            keccak256(abi.encodePacked(componentId, change, reason)),
            block.timestamp
        );
    }
    
    /**
     * @notice Batch update reputations
     * @dev More efficient for multiple updates
     */
    function batchUpdateReputation(
        address[] calldata users,
        uint8[] calldata componentIds,
        int256[] calldata changes,
        string[] calldata reasons
    ) external nonReentrant whenNotPaused onlyRole(REPUTATION_UPDATER_ROLE) {
        require(
            users.length == componentIds.length && 
            users.length == changes.length && 
            users.length == reasons.length,
            "Length mismatch"
        );
        
        for (uint256 i = 0; i < users.length; i++) {
            require(componentIds[i] < 11, "Invalid component");
            
            emit ReputationUpdated(
                users[i],
                0,
                keccak256(abi.encodePacked(componentIds[i], changes[i], reasons[i])),
                block.timestamp
            );
        }
    }
    
    // =============================================================================
    // VALIDATOR INTEGRATION - ROOT UPDATES
    // =============================================================================
    
    /**
     * @notice Update reputation merkle root
     * @dev Called by validator after computing all reputation scores
     */
    function updateReputationRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        require(epoch == currentEpoch + 1, "Invalid epoch");
        
        reputationRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit ReputationRootUpdated(
            newRoot,
            epoch,
            block.number,
            block.timestamp
        );
    }
    
    /**
     * @notice Update component breakdown merkle root
     * @dev Allows detailed component verification
     */
    function updateComponentRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        require(epoch == currentEpoch, "Epoch mismatch");
        
        componentRoot = newRoot;
        
        emit ComponentRootUpdated(
            newRoot,
            epoch,
            block.number,
            block.timestamp
        );
    }
    
    // =============================================================================
    // REPUTATION QUERIES - MERKLE VERIFICATION
    // =============================================================================
    
    /**
     * @notice Verify a user's reputation score
     * @dev Anyone can verify using public merkle root
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
     * @notice Verify a specific component score
     */
    function verifyComponent(
        address user,
        uint8 componentId,
        uint256 value,
        bytes32[] calldata proof
    ) external view returns (bool) {
        require(componentId < 11, "Invalid component");
        bytes32 leaf = keccak256(abi.encodePacked(user, componentId, value, currentEpoch));
        return _verifyProof(proof, componentRoot, leaf);
    }
    
    /**
     * @notice Check if user meets validator requirements
     * @dev Requires merkle proof of reputation
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
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get reputation score (must query validator)
     * @dev Returns 0 - actual score via GraphQL API
     */
    function getReputation(address) external pure returns (uint256) {
        return 0; // Computed by validator
    }
    
    /**
     * @notice Get total reputation score with components (must query validator)
     * @dev Returns empty data - actual data via GraphQL API
     */
    function getTotalReputationScore(address) external pure returns (
        uint256 totalScore,
        uint256 participationScore,
        uint256[11] memory components
    ) {
        return (0, 0, components); // All computed by validator
    }
    
    /**
     * @notice Get reputation tier
     * @dev Can compute locally from score
     */
    function getReputationTier(uint256 score) external pure returns (uint256) {
        if (score >= TIER_DIAMOND) return 5;
        if (score >= TIER_PLATINUM) return 4;
        if (score >= TIER_GOLD) return 3;
        if (score >= TIER_SILVER) return 2;
        if (score >= TIER_BRONZE) return 1;
        return 0;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update component weights
     * @dev Weights must sum to BASIS_POINTS (10000)
     */
    function updateComponentWeights(uint256[11] calldata newWeights) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        uint256 sum = 0;
        for (uint256 i = 0; i < 11; i++) {
            sum += newWeights[i];
        }
        require(sum == BASIS_POINTS, "Weights must sum to 10000");
        
        for (uint256 i = 0; i < 11; i++) {
            if (newWeights[i] != componentWeights[i]) {
                emit ComponentWeightUpdated(
                    uint8(i),
                    componentWeights[i],
                    newWeights[i],
                    block.timestamp
                );
                componentWeights[i] = newWeights[i];
            }
        }
    }
    
    /**
     * @notice Update minimum reputation requirements
     */
    function updateMinimumReputation(
        uint256 _minValidator,
        uint256 _minArbitrator
    ) external onlyRole(ADMIN_ROLE) {
        minValidatorReputation = _minValidator;
        minArbitratorReputation = _minArbitrator;
        
        emit MinimumReputationUpdated("validator", _minValidator, block.timestamp);
        emit MinimumReputationUpdated("arbitrator", _minArbitrator, block.timestamp);
    }
    
    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
    
    function _isAvalancheValidator(address account) internal view returns (bool) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
}