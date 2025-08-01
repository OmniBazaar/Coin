// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title UnifiedArbitrationSystem
 * @author OmniCoin Development Team
 * @notice Simplified arbitration system with event-based architecture
 * @dev Replaces OmniCoinArbitration with 90% state reduction
 * 
 * Features:
 * - Event-based dispute tracking (no arrays)
 * - Merkle proof arbitrator verification
 * - Privacy-optional dispute resolution
 * - Simplified fee structure
 * - Integration with UnifiedReputationSystem
 * 
 * State Reduction Strategy:
 * - Remove all arbitrator arrays -> merkle roots
 * - Remove dispute arrays -> event queries
 * - Remove participant tracking -> events
 * - Keep only active dispute state
 */
contract UnifiedArbitrationSystem is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    using SafeERC20 for IERC20;
    
    // =============================================================================
    // TYPES & CONSTANTS
    // =============================================================================
    
    enum DisputeStatus {
        PENDING,
        IN_PROGRESS,
        RESOLVED,
        ESCALATED,
        CANCELLED
    }
    
    enum DisputeCategory {
        PRODUCT_QUALITY,
        NON_DELIVERY,
        SERVICE_DISPUTE,
        FRAUD_CLAIM,
        OTHER
    }
    
    /// @notice Minimal dispute data structure optimized for gas efficiency
    /// @dev Packed to use 3 storage slots instead of 4 (80 bytes total)
    struct MinimalDispute {
        uint256 amount;            // 32 bytes (slot 1)
        address claimant;          // 20 bytes (slot 2)
        address respondent;        // 20 bytes (slot 3)
        uint32 deadline;           // 4 bytes (slot 3)
        DisputeStatus status;      // 1 byte (slot 3)
        DisputeCategory category;  // 1 byte (slot 3)
        bool usePrivacy;           // 1 byte (slot 3)
        bool isPanelDispute;       // 1 byte (slot 3)
        // Total: 80 bytes optimally packed into 3 slots
    }
    
    // Constants
    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;
    /// @notice Fee charged for arbitration services (1% = 100 basis points)
    uint256 public constant ARBITRATION_FEE = 100; // 1%
    /// @notice Multiplier for privacy-enabled dispute fees
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    /// @notice Minimum stake required to become an arbitrator (100k XOM)
    uint256 public constant MIN_ARBITRATOR_STAKE = 100000 * 1e6; // 100k XOM
    /// @notice Default timeout period for dispute resolution
    uint256 public constant DISPUTE_TIMEOUT = 7 days;
    /// @notice Number of arbitrators required for panel disputes
    uint256 public constant PANEL_SIZE = 3;
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Administrator role for system configuration
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Arbitrator role for dispute resolution
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    /// @notice Escalation handler role for complex disputes
    bytes32 public constant ESCALATION_ROLE = keccak256("ESCALATION_ROLE");
    /// @notice Avalanche validator role for merkle root updates
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    // =============================================================================
    // STATE (Minimal)
    // =============================================================================
    
    // Active disputes only
    /// @notice Mapping of dispute ID to dispute data (only active disputes stored)
    mapping(bytes32 => MinimalDispute) public disputes;
    
    // Merkle roots for verification
    /// @notice Merkle root of all qualified arbitrators
    bytes32 public arbitratorRoot;
    /// @notice Merkle root of specialized arbitrators by category
    bytes32 public specializedArbitratorRoot;
    /// @notice Merkle root of historical dispute resolutions
    bytes32 public disputeHistoryRoot;
    /// @notice Block number of last merkle root update
    uint256 public lastRootUpdate;
    /// @notice Current epoch for merkle tree versioning
    uint256 public currentEpoch;
    
    // Fee distribution
    /// @notice Treasury address for fee collection
    address public treasuryAddress;
    /// @notice Pool address for arbitrator rewards
    address public arbitratorPoolAddress;
    
    // Privacy support
    /// @notice Flag indicating if MPC privacy is available
    bool public isMpcAvailable;
    
    // =============================================================================
    // EVENTS - Validator Compatible
    // =============================================================================
    
    /// @notice Emitted when a new dispute is created
    /// @param disputeId Unique identifier for the dispute
    /// @param claimant Address initiating the dispute
    /// @param respondent Address defending against the claim
    /// @param amount Value at stake in the dispute
    /// @param category Type of dispute
    /// @param evidenceHash IPFS hash of initial evidence
    /// @param timestamp Block timestamp of creation
    event DisputeCreated(
        bytes32 indexed disputeId,
        address indexed claimant,
        address indexed respondent,
        uint256 amount,
        DisputeCategory category,
        string evidenceHash,
        uint256 timestamp
    );
    
    /// @notice Emitted when an arbitrator is assigned to a dispute
    /// @param disputeId Unique identifier for the dispute
    /// @param arbitrator Address of assigned arbitrator (lead if panel)
    /// @param isPanel Whether this is a panel arbitration
    /// @param timestamp Block timestamp of assignment
    event DisputeAssigned(
        bytes32 indexed disputeId,
        address indexed arbitrator,
        bool indexed isPanel,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when evidence is submitted for a dispute
    /// @param disputeId Unique identifier for the dispute
    /// @param submitter Address submitting the evidence
    /// @param evidenceHash IPFS hash of submitted evidence
    /// @param timestamp Block timestamp of submission
    event EvidenceSubmitted(
        bytes32 indexed disputeId,
        address indexed submitter,
        string evidenceHash,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a dispute is resolved
    /// @param disputeId Unique identifier for the dispute
    /// @param winner Address of the winning party
    /// @param claimantAmount Amount awarded to claimant
    /// @param respondentAmount Amount returned to respondent
    /// @param arbitratorFee Fee paid to arbitrator(s)
    /// @param ruling Text description of the ruling
    /// @param timestamp Block timestamp of resolution
    event DisputeResolved(
        bytes32 indexed disputeId,
        address indexed winner,
        uint256 indexed claimantAmount,
        uint256 indexed respondentAmount,
        uint256 arbitratorFee,
        string ruling,
        uint256 timestamp
    );
    
    /// @notice Emitted when a dispute is escalated
    /// @param disputeId Unique identifier for the dispute
    /// @param reason Reason for escalation
    /// @param timestamp Block timestamp of escalation
    event DisputeEscalated(
        bytes32 indexed disputeId,
        string reason,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a dispute is cancelled
    /// @param disputeId Unique identifier for the dispute
    /// @param reason Reason for cancellation
    /// @param timestamp Block timestamp of cancellation
    event DisputeCancelled(
        bytes32 indexed disputeId,
        string reason,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when arbitrator merkle root is updated
    /// @param newRoot New merkle root hash
    /// @param epoch Epoch number for this update
    /// @param blockNumber Block number of update
    /// @param timestamp Block timestamp of update
    event ArbitratorRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed blockNumber,
        uint256 indexed timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidAmount();
    error DisputeNotFound();
    error DisputeNotPending();
    error NotDisputeParticipant();
    error InvalidArbitratorProof();
    error DisputeExpired();
    error AlreadyResolved();
    error InvalidResolution();
    error NotAvalancheValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        if (!hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) &&
            !_isAvalancheValidator(msg.sender)) {
            revert NotAvalancheValidator();
        }
        _;
    }
    
    modifier disputeExists(bytes32 disputeId) {
        if (disputes[disputeId].claimant == address(0)) revert DisputeNotFound();
        _;
    }
    
    modifier onlyParticipant(bytes32 disputeId) {
        MinimalDispute storage dispute = disputes[disputeId];
        if (msg.sender != dispute.claimant && msg.sender != dispute.respondent) {
            revert NotDisputeParticipant();
        }
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the unified arbitration system
     * @param _admin Address to grant admin roles
     * @param _registry Address of the OmniCoin registry
     * @param _treasury Address for fee collection
     * @param _arbitratorPool Address for arbitrator rewards
     */
    constructor(
        address _admin,
        address _registry,
        address _treasury,
        address _arbitratorPool
    ) RegistryAware(_registry) {
        if (_admin == address(0)) revert InvalidAmount();
        if (_treasury == address(0)) revert InvalidAmount();
        if (_arbitratorPool == address(0)) revert InvalidAmount();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        
        treasuryAddress = _treasury;
        arbitratorPoolAddress = _arbitratorPool;
        isMpcAvailable = false; // Default for testing
    }
    
    // =============================================================================
    // DISPUTE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create a new dispute
     * @dev Emits event for validator indexing
     * @param respondent Address of the party being disputed
     * @param amount Value at stake in the dispute
     * @param category Type of dispute
     * @param evidenceHash IPFS hash of initial evidence
     * @param usePrivacy Whether to use privacy features
     * @return disputeId Unique identifier for the created dispute
     */
    function createDispute(
        address respondent,
        uint256 amount,
        DisputeCategory category,
        string calldata evidenceHash,
        bool usePrivacy
    ) external nonReentrant whenNotPaused returns (bytes32 disputeId) {
        if (respondent == address(0) || respondent == msg.sender) revert InvalidAmount();
        if (amount == 0) revert InvalidAmount();
        
        disputeId = keccak256(abi.encodePacked(
            msg.sender,
            respondent,
            amount,
            block.timestamp, // solhint-disable-line not-rely-on-time
            block.number
        ));
        
        disputes[disputeId] = MinimalDispute({
            claimant: msg.sender,
            respondent: respondent,
            amount: amount,
            deadline: uint32(block.timestamp + DISPUTE_TIMEOUT), // solhint-disable-line not-rely-on-time
            status: DisputeStatus.PENDING,
            category: category,
            usePrivacy: usePrivacy,
            isPanelDispute: false
        });
        
        // Calculate and collect arbitration fee
        uint256 fee = (amount * ARBITRATION_FEE) / BASIS_POINTS;
        if (usePrivacy) fee *= PRIVACY_MULTIPLIER;
        
        IERC20 token = IERC20(_getToken(usePrivacy));
        token.safeTransferFrom(msg.sender, address(this), amount + fee);
        
        emit DisputeCreated(
            disputeId,
            msg.sender,
            respondent,
            amount,
            category,
            evidenceHash,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Submit evidence for a dispute
     * @param disputeId Unique identifier of the dispute
     * @param evidenceHash IPFS hash of the evidence
     */
    function submitEvidence(
        bytes32 disputeId,
        string calldata evidenceHash
    ) external nonReentrant disputeExists(disputeId) onlyParticipant(disputeId) {
        MinimalDispute storage dispute = disputes[disputeId];
        
        if (dispute.status != DisputeStatus.PENDING && 
            dispute.status != DisputeStatus.IN_PROGRESS) {
            revert DisputeNotPending();
        }
        if (block.timestamp > dispute.deadline) revert DisputeExpired(); // solhint-disable-line not-rely-on-time
        
        emit EvidenceSubmitted(
            disputeId,
            msg.sender,
            evidenceHash,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Assign arbitrator to dispute (validator operation)
     * @dev Requires merkle proof of arbitrator eligibility
     * @param disputeId Unique identifier of the dispute
     * @param arbitrator Address of the arbitrator to assign
     * @param proof Merkle proof of arbitrator eligibility
     */
    function assignArbitrator(
        bytes32 disputeId,
        address arbitrator,
        bytes32[] calldata proof
    ) external onlyAvalancheValidator disputeExists(disputeId) {
        MinimalDispute storage dispute = disputes[disputeId];
        if (dispute.status != DisputeStatus.PENDING) revert DisputeNotPending();
        
        // Verify arbitrator eligibility via merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(
            arbitrator,
            dispute.category,
            currentEpoch
        ));
        
        if (!_verifyProof(proof, arbitratorRoot, leaf)) revert InvalidArbitratorProof();
        
        dispute.status = DisputeStatus.IN_PROGRESS;
        
        emit DisputeAssigned(
            disputeId,
            arbitrator,
            false,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Escalate dispute to panel
     * @dev Requires participant role and changes dispute to panel mode
     * @param disputeId Unique identifier of the dispute
     * @param reason Explanation for why escalation is needed
     */
    function escalateToPanel(
        bytes32 disputeId,
        string calldata reason
    ) external nonReentrant disputeExists(disputeId) onlyParticipant(disputeId) {
        MinimalDispute storage dispute = disputes[disputeId];
        if (dispute.status != DisputeStatus.IN_PROGRESS) revert DisputeNotPending();
        
        dispute.status = DisputeStatus.ESCALATED;
        dispute.isPanelDispute = true;
        dispute.deadline = uint32(block.timestamp + DISPUTE_TIMEOUT); // solhint-disable-line not-rely-on-time
        
        emit DisputeEscalated(disputeId, reason, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Resolve dispute (arbitrator only)
     * @dev Requires merkle proof of arbitrator assignment and distributes funds based on ruling
     * @param disputeId Unique identifier of the dispute
     * @param winner Address of the winning party (claimant or respondent)
     * @param claimantPercentage Percentage awarded to claimant in basis points (0-10000)
     * @param ruling Text description of the arbitrator's decision
     * @param proof Merkle proof of arbitrator assignment to this dispute
     */
    function resolveDispute(
        bytes32 disputeId,
        address winner,
        uint256 claimantPercentage, // Basis points (0-10000)
        string calldata ruling,
        bytes32[] calldata proof
    ) external nonReentrant disputeExists(disputeId) {
        MinimalDispute storage dispute = disputes[disputeId];
        _validateResolution(dispute, winner, claimantPercentage);
        _verifyArbitratorAssignment(disputeId, proof);
        
        dispute.status = DisputeStatus.RESOLVED;
        
        // Calculate and distribute funds
        (
            uint256 claimantAmount,
            uint256 respondentAmount,
            uint256 arbitratorFee
        ) = _calculateDistribution(dispute, claimantPercentage);
        
        _distributeFunds(dispute, claimantAmount, respondentAmount, arbitratorFee);
        
        emit DisputeResolved(
            disputeId,
            winner,
            claimantAmount,
            respondentAmount,
            arbitratorFee,
            ruling,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Cancel expired dispute
     * @dev Refunds the claimant if dispute deadline has passed without resolution
     * @param disputeId Unique identifier of the dispute to cancel
     */
    function cancelExpiredDispute(bytes32 disputeId) external nonReentrant disputeExists(disputeId) {
        MinimalDispute storage dispute = disputes[disputeId];
        if (block.timestamp < dispute.deadline) revert DisputeExpired(); // solhint-disable-line not-rely-on-time
        if (dispute.status != DisputeStatus.PENDING &&
            dispute.status != DisputeStatus.IN_PROGRESS) {
            revert AlreadyResolved();
        }
        
        dispute.status = DisputeStatus.CANCELLED;
        
        // Refund to claimant
        uint256 refundAmount = dispute.amount;
        uint256 fee = (dispute.amount * ARBITRATION_FEE) / BASIS_POINTS;
        if (dispute.usePrivacy) fee *= PRIVACY_MULTIPLIER;
        
        IERC20 token = IERC20(_getToken(dispute.usePrivacy));
        token.safeTransfer(dispute.claimant, refundAmount + fee);
        
        emit DisputeCancelled(disputeId, "Expired", block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // MERKLE ROOT UPDATES
    // =============================================================================
    
    /**
     * @notice Update arbitrator eligibility root
     * @dev Only Avalanche validators can update the merkle root for arbitrator verification
     * @param newRoot New merkle root hash for arbitrator eligibility
     * @param epoch Epoch number for versioning (must be currentEpoch + 1)
     */
    function updateArbitratorRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        if (epoch != currentEpoch + 1) revert InvalidAmount();
        
        arbitratorRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit ArbitratorRootUpdated(
            newRoot,
            epoch,
            block.number,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Update specialized arbitrator root
     * @dev Updates merkle root for arbitrators with specific category specializations
     * @param newRoot New merkle root hash for specialized arbitrators
     */
    function updateSpecializedRoot(bytes32 newRoot) external onlyAvalancheValidator {
        specializedArbitratorRoot = newRoot;
    }
    
    /**
     * @notice Update dispute history root
     * @dev Updates merkle root for historical dispute resolution verification
     * @param newRoot New merkle root hash for dispute history
     */
    function updateDisputeHistoryRoot(bytes32 newRoot) external onlyAvalancheValidator {
        disputeHistoryRoot = newRoot;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update fee recipients
     * @dev Changes the addresses that receive arbitration fees
     * @param _treasury New treasury address for fee collection
     * @param _arbitratorPool New arbitrator pool address for rewards
     */
    function updateFeeRecipients(
        address _treasury,
        address _arbitratorPool
    ) external onlyRole(ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidAmount();
        if (_arbitratorPool == address(0)) revert InvalidAmount();
        
        treasuryAddress = _treasury;
        arbitratorPoolAddress = _arbitratorPool;
    }
    
    /**
     * @notice Set MPC availability
     * @dev Controls whether Multi-Party Computation privacy features are available
     * @param _available True to enable MPC privacy features
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
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
    // VERIFICATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify arbitrator eligibility
     * @dev Checks if an arbitrator is qualified for a specific dispute category
     * @param arbitrator Address of the arbitrator to verify
     * @param category Dispute category to check eligibility for
     * @param proof Merkle proof of arbitrator eligibility
     * @return isEligible True if arbitrator is eligible for the category
     */
    function verifyArbitrator(
        address arbitrator,
        DisputeCategory category,
        bytes32[] calldata proof
    ) external view returns (bool isEligible) {
        bytes32 leaf = keccak256(abi.encodePacked(arbitrator, category, currentEpoch));
        return _verifyProof(proof, arbitratorRoot, leaf);
    }
    
    /**
     * @notice Verify arbitrator specialization
     * @dev Checks if an arbitrator has specific specializations using bitmask
     * @param arbitrator Address of the arbitrator to verify
     * @param specializationMask Bitmask representing required specializations
     * @param proof Merkle proof of arbitrator specializations
     * @return hasSpecialization True if arbitrator has the required specializations
     */
    function verifySpecialization(
        address arbitrator,
        uint256 specializationMask,
        bytes32[] calldata proof
    ) external view returns (bool hasSpecialization) {
        bytes32 leaf = keccak256(abi.encodePacked(arbitrator, specializationMask, currentEpoch));
        return _verifyProof(proof, specializedArbitratorRoot, leaf);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get dispute details
     * @dev Returns all stored information about a specific dispute
     * @param disputeId Unique identifier of the dispute
     * @return claimant Address that initiated the dispute
     * @return respondent Address being disputed against
     * @return amount Value at stake in the dispute
     * @return status Current status of the dispute
     * @return category Type/category of the dispute
     * @return deadline Timestamp when dispute expires
     * @return usePrivacy Whether privacy features are enabled
     * @return isPanelDispute Whether this requires panel arbitration
     */
    function getDispute(bytes32 disputeId) external view returns (
        address claimant,
        address respondent,
        uint256 amount,
        DisputeStatus status,
        DisputeCategory category,
        uint32 deadline,
        bool usePrivacy,
        bool isPanelDispute
    ) {
        MinimalDispute storage dispute = disputes[disputeId];
        return (
            dispute.claimant,
            dispute.respondent,
            dispute.amount,
            dispute.status,
            dispute.category,
            dispute.deadline,
            dispute.usePrivacy,
            dispute.isPanelDispute
        );
    }
    
    /**
     * @notice Calculate arbitration fee
     * @dev Computes the fee based on dispute amount and privacy requirements
     * @param amount Value at stake in the dispute
     * @param usePrivacy Whether privacy features will be used
     * @return fee Total arbitration fee in token units
     */
    function calculateArbitrationFee(
        uint256 amount,
        bool usePrivacy
    ) external pure returns (uint256 fee) {
        fee = (amount * ARBITRATION_FEE) / BASIS_POINTS;
        if (usePrivacy) fee *= PRIVACY_MULTIPLIER;
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get token contract address
     * @dev Returns appropriate token contract based on privacy requirements
     * @param usePrivacy Whether privacy features are requested
     * @return tokenAddress Address of the token contract to use
     */
    function _getToken(bool usePrivacy) internal view returns (address tokenAddress) {
        if (usePrivacy && isMpcAvailable) {
            return registry.getContract(keccak256("PRIVATE_OMNICOIN"));
        }
        return registry.getContract(keccak256("OMNICOIN"));
    }
    
    /**
     * @notice Validate resolution parameters
     * @dev Internal function to validate dispute resolution inputs
     * @param dispute The dispute being resolved
     * @param winner Address of the winning party
     * @param claimantPercentage Percentage for claimant in basis points
     */
    function _validateResolution(
        MinimalDispute storage dispute,
        address winner,
        uint256 claimantPercentage
    ) internal view {
        if (dispute.status != DisputeStatus.IN_PROGRESS) revert DisputeNotPending();
        if (winner != dispute.claimant && winner != dispute.respondent) {
            revert InvalidResolution();
        }
        if (claimantPercentage > BASIS_POINTS) revert InvalidAmount();
    }
    
    /**
     * @notice Verify arbitrator assignment proof
     * @dev Internal function to validate arbitrator's right to resolve dispute
     * @param disputeId Unique identifier of the dispute
     * @param proof Merkle proof of arbitrator assignment
     */
    function _verifyArbitratorAssignment(
        bytes32 disputeId,
        bytes32[] calldata proof
    ) internal view {
        bytes32 leaf = keccak256(abi.encodePacked(
            disputeId,
            msg.sender,
            currentEpoch
        ));
        if (!_verifyProof(proof, disputeHistoryRoot, leaf)) revert InvalidArbitratorProof();
    }
    
    /**
     * @notice Calculate fund distribution amounts
     * @dev Internal function to compute distribution based on resolution percentage
     * @param dispute The dispute being resolved
     * @param claimantPercentage Percentage for claimant in basis points
     * @return claimantAmount Amount to award claimant
     * @return respondentAmount Amount to return to respondent
     * @return arbitratorFee Total fee for arbitration
     */
    function _calculateDistribution(
        MinimalDispute storage dispute,
        uint256 claimantPercentage
    ) internal view returns (
        uint256 claimantAmount,
        uint256 respondentAmount,
        uint256 arbitratorFee
    ) {
        claimantAmount = (dispute.amount * claimantPercentage) / BASIS_POINTS;
        respondentAmount = dispute.amount - claimantAmount;
        
        uint256 baseFee = (dispute.amount * ARBITRATION_FEE) / BASIS_POINTS;
        arbitratorFee = dispute.usePrivacy ? baseFee * PRIVACY_MULTIPLIER : baseFee;
    }
    
    /**
     * @notice Check if account is Avalanche validator
     * @dev Verifies if an address is registered as an Avalanche validator
     * @param account Address to check
     * @return isValidator True if account is an Avalanche validator
     */
    function _isAvalancheValidator(address account) internal view returns (bool isValidator) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
    
    /**
     * @notice Distribute funds to parties and collect fees
     * @dev Internal function to handle all fund transfers
     * @param dispute The dispute being resolved
     * @param claimantAmount Amount to transfer to claimant
     * @param respondentAmount Amount to transfer to respondent
     * @param arbitratorFee Total arbitration fee to distribute
     */
    function _distributeFunds(
        MinimalDispute storage dispute,
        uint256 claimantAmount,
        uint256 respondentAmount,
        uint256 arbitratorFee
    ) internal {
        IERC20 token = IERC20(_getToken(dispute.usePrivacy));
        
        // Transfer dispute amounts
        if (claimantAmount > 0) {
            token.safeTransfer(dispute.claimant, claimantAmount);
        }
        if (respondentAmount > 0) {
            token.safeTransfer(dispute.respondent, respondentAmount);
        }
        
        // Distribute fees (70% arbitrators, 30% treasury)
        uint256 arbitratorShare = (arbitratorFee * 7000) / BASIS_POINTS;
        uint256 treasuryShare = arbitratorFee - arbitratorShare;
        
        if (arbitratorShare > 0) {
            token.safeTransfer(arbitratorPoolAddress, arbitratorShare);
        }
        if (treasuryShare > 0) {
            token.safeTransfer(treasuryAddress, treasuryShare);
        }
    }
    
    /**
     * @notice Verify merkle proof
     * @dev Internal function to validate merkle tree proofs
     * @param proof Array of merkle proof elements
     * @param root Merkle root to verify against
     * @param leaf Leaf node being verified
     * @return isValid True if proof is valid
     */
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool isValid) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
}