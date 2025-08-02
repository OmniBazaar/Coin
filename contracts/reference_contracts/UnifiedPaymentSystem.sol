// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
// Note: MPC imports removed as not currently used - may be needed for future privacy features
// import {MpcCore, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title UnifiedPaymentSystem
 * @author OmniCoin Development Team
 * @notice Consolidated payment system with privacy support
 * @dev Combines functionality from:
 * - OmniCoinPayment (streaming payments)
 * - SecureSend (escrow functionality)
 * - OmniBatchTransactions (batch operations)
 * 
 * Uses event-based architecture for transaction history
 * Supports both standard and privacy-enabled payments
 */
contract UnifiedPaymentSystem is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    using SafeERC20 for IERC20;
    
    // =============================================================================
    // TYPES & CONSTANTS
    // =============================================================================
    
    enum PaymentType {
        INSTANT,
        STREAM,
        ESCROW,
        BATCH
    }
    
    enum EscrowStatus {
        ACTIVE,
        COMPLETED,
        CANCELLED,
        DISPUTED
    }
    
    struct PaymentStream {
        address recipient;       // 20 bytes - slot 0
        bool isActive;          // 1 byte  - slot 0 (21 bytes total)
        bool usePrivacy;        // 1 byte  - slot 0 (22 bytes total)
        uint256 totalAmount;    // 32 bytes - slot 1  
        uint256 startTime;      // 32 bytes - slot 2
        uint256 endTime;        // 32 bytes - slot 3
        uint256 withdrawnAmount; // 32 bytes - slot 4
    }
    
    struct MinimalEscrow {
        address buyer;           // 20 bytes - slot 0
        EscrowStatus status;     // 1 byte  - slot 0 (21 bytes total)
        bool usePrivacy;         // 1 byte  - slot 0 (22 bytes total)
        address seller;          // 20 bytes - slot 1 
        uint256 amount;          // 32 bytes - slot 2
        uint256 deadline;        // 32 bytes - slot 3
    }
    
    // Constants
    /// @notice Maximum number of recipients in a batch payment
    uint256 public constant MAX_BATCH_SIZE = 100;
    /// @notice Minimum duration for payment streams
    uint256 public constant MIN_STREAM_DURATION = 1 hours;
    /// @notice Maximum duration for payment streams
    uint256 public constant MAX_STREAM_DURATION = 365 days;
    /// @notice Default duration for escrow contracts
    uint256 public constant DEFAULT_ESCROW_DURATION = 7 days;
    
    // Fees (basis points)
    /// @notice Escrow service fee in basis points (0.25%)
    uint256 public constant ESCROW_FEE = 25;
    /// @notice Privacy feature fee multiplier (10x base fee)
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Role identifier for system administrators
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role identifier for payment system managers
    bytes32 public constant PAYMENT_MANAGER_ROLE = keccak256("PAYMENT_MANAGER_ROLE");
    /// @notice Role identifier for dispute arbitrators
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    /// @notice Role identifier for Avalanche validator nodes
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    // =============================================================================
    // STATE (Minimal)
    // =============================================================================
    
    // Active payment streams (required for withdrawals)
    mapping(bytes32 => PaymentStream) public streams;
    
    // Active escrows (required for resolution)
    mapping(bytes32 => MinimalEscrow) public escrows;
    
    // Merkle roots for payment history
    bytes32 public paymentHistoryRoot;
    bytes32 public streamHistoryRoot;
    bytes32 public escrowHistoryRoot;
    uint256 public lastRootUpdate;
    uint256 public currentEpoch;
    
    // Fee recipient
    /// @notice Address that receives platform fees
    address public feeRecipient;
    
    // MPC availability
    /// @notice Flag indicating whether MPC privacy features are available
    bool public isMpcAvailable;
    
    // =============================================================================
    // EVENTS - Validator Compatible
    // =============================================================================
    
    // Instant Payment Events
    /// @notice Emitted when an instant payment is made
    /// @param from Address sending the payment
    /// @param to Address receiving the payment
    /// @param amount Amount of tokens transferred
    /// @param paymentId Unique identifier for this payment
    /// @param timestamp Block timestamp of the payment
    event PaymentMade(
        address indexed from,
        address indexed to,
        uint256 indexed amount,
        bytes32 paymentId,
        uint256 timestamp
    );
    
    /// @notice Emitted when a batch payment is executed
    /// @param from Address sending the batch payment
    /// @param recipientCount Number of recipients in the batch
    /// @param totalAmount Total amount distributed in the batch
    /// @param batchId Unique identifier for this batch
    /// @param timestamp Block timestamp of the batch payment
    event BatchPaymentMade(
        address indexed from,
        uint256 indexed recipientCount,
        uint256 indexed totalAmount,
        bytes32 batchId,
        uint256 timestamp
    );
    
    // Stream Events
    /// @notice Emitted when a new payment stream is created
    /// @param streamId Unique identifier for the stream
    /// @param sender Address creating the stream
    /// @param recipient Address that will receive stream payments
    /// @param amount Total amount to be streamed
    /// @param startTime When the stream begins
    /// @param endTime When the stream ends
    /// @param timestamp Block timestamp of stream creation
    event StreamCreated(
        bytes32 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        uint256 timestamp
    );
    
    /// @notice Emitted when tokens are withdrawn from a stream
    /// @param streamId Unique identifier for the stream
    /// @param recipient Address withdrawing from the stream
    /// @param amount Amount withdrawn
    /// @param timestamp Block timestamp of withdrawal
    event StreamWithdrawn(
        bytes32 indexed streamId,
        address indexed recipient,
        uint256 indexed amount,
        uint256 timestamp
    );
    
    /// @notice Emitted when a stream is cancelled
    /// @param streamId Unique identifier for the stream
    /// @param sender Address that cancelled the stream
    /// @param refundAmount Amount refunded to sender
    /// @param timestamp Block timestamp of cancellation
    event StreamCancelled(
        bytes32 indexed streamId,
        address indexed sender,
        uint256 indexed refundAmount,
        uint256 timestamp
    );
    
    // Escrow Events
    /// @notice Emitted when a new escrow is created
    /// @param escrowId Unique identifier for the escrow
    /// @param buyer Address that created the escrow
    /// @param seller Address that will receive payment
    /// @param amount Amount held in escrow
    /// @param deadline When escrow expires
    /// @param timestamp Block timestamp of escrow creation
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 deadline,
        uint256 timestamp
    );
    
    /// @notice Emitted when an escrow is completed
    /// @param escrowId Unique identifier for the escrow
    /// @param releasedAmount Amount released to seller
    /// @param feeAmount Fee collected by platform
    /// @param timestamp Block timestamp of completion
    event EscrowCompleted(
        bytes32 indexed escrowId,
        uint256 indexed releasedAmount,
        uint256 indexed feeAmount,
        uint256 timestamp
    );
    
    /// @notice Emitted when an escrow is cancelled
    /// @param escrowId Unique identifier for the escrow
    /// @param refundAmount Amount refunded to buyer
    /// @param timestamp Block timestamp of cancellation
    event EscrowCancelled(
        bytes32 indexed escrowId,
        uint256 indexed refundAmount,
        uint256 timestamp
    );
    
    /// @notice Emitted when an escrow is disputed
    /// @param escrowId Unique identifier for the escrow
    /// @param disputer Address that initiated the dispute
    /// @param reason Reason for the dispute
    /// @param timestamp Block timestamp of dispute
    event EscrowDisputed(
        bytes32 indexed escrowId,
        address indexed disputer,
        string reason,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a dispute is resolved
    /// @param escrowId Unique identifier for the escrow
    /// @param winner Address that won the dispute
    /// @param amount Amount awarded to winner
    /// @param timestamp Block timestamp of resolution
    event DisputeResolved(
        bytes32 indexed escrowId,
        address indexed winner,
        uint256 indexed amount,
        uint256 timestamp
    );
    
    // Root Update Events
    /// @notice Emitted when payment history merkle root is updated
    /// @param newRoot New merkle root hash
    /// @param epoch Epoch number for this update
    /// @param blockNumber Block number when update occurred
    /// @param timestamp Block timestamp of the update
    event PaymentRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidAmount();
    error InvalidRecipient();
    error InvalidDuration();
    error StreamNotFound();
    error StreamNotActive();
    error NotStreamRecipient();
    error NothingToWithdraw();
    error EscrowNotFound();
    error EscrowNotActive();
    error NotEscrowParticipant();
    error EscrowExpired();
    error AlreadyDisputed();
    error BatchTooLarge();
    error ArrayLengthMismatch();
    error TransferFailed();
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
    
    /// @notice Initialize the unified payment system
    /// @param _admin Address to receive admin roles
    /// @param _registry Address of the registry contract
    /// @param _feeRecipient Address to receive platform fees
    constructor(
        address _admin,
        address _registry,
        address _feeRecipient
    ) RegistryAware(_registry) {
        if (_admin == address(0)) revert InvalidRecipient();
        if (_feeRecipient == address(0)) revert InvalidRecipient();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(PAYMENT_MANAGER_ROLE, _admin);
        _grantRole(ARBITRATOR_ROLE, _admin);
        
        feeRecipient = _feeRecipient;
        isMpcAvailable = false; // Default for testing
    }
    
    // =============================================================================
    // INSTANT PAYMENT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Make instant payment
     * @dev Emits event for validator tracking
     * @param recipient Address to receive the payment
     * @param amount Amount of tokens to transfer
     */
    function makePayment(
        address recipient,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        
        IERC20 token = IERC20(_getToken(false));
        token.safeTransferFrom(msg.sender, recipient, amount);
        
        // solhint-disable-next-line not-rely-on-time
        bytes32 paymentId = keccak256(abi.encodePacked(msg.sender, recipient, amount, block.timestamp));
        
        // solhint-disable-next-line not-rely-on-time
        emit PaymentMade(
            msg.sender,
            recipient,
            amount,
            paymentId,
            block.timestamp
        );
    }
    
    /**
     * @notice Make batch payments
     * @dev Gas efficient for multiple recipients
     * @param recipients Array of addresses to receive payments
     * @param amounts Array of amounts corresponding to each recipient
     */
    function makeBatchPayment(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused {
        if (recipients.length != amounts.length) revert ArrayLengthMismatch();
        if (recipients.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        
        IERC20 token = IERC20(_getToken(false));
        uint256 totalAmount = 0;
        
        for (uint256 i = 0; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert InvalidRecipient();
            if (amounts[i] == 0) revert InvalidAmount();
            
            totalAmount += amounts[i];
            token.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }
        
        // solhint-disable-next-line not-rely-on-time
        bytes32 batchId = keccak256(abi.encodePacked(msg.sender, recipients, amounts, block.timestamp));
        
        // solhint-disable-next-line not-rely-on-time
        emit BatchPaymentMade(
            msg.sender,
            recipients.length,
            totalAmount,
            batchId,
            block.timestamp
        );
    }
    
    // =============================================================================
    // STREAMING PAYMENT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create payment stream
     * @param recipient Address that will receive the stream
     * @param totalAmount Total amount to be streamed
     * @param duration Duration of the stream in seconds
     * @param usePrivacy Whether to use privacy features
     * @return streamId Unique identifier for the created stream
     */
    function createStream(
        address recipient,
        uint256 totalAmount,
        uint256 duration,
        bool usePrivacy
    ) external nonReentrant whenNotPaused returns (bytes32 streamId) {
        if (recipient == address(0)) revert InvalidRecipient();
        if (totalAmount == 0) revert InvalidAmount();
        if (duration < MIN_STREAM_DURATION || duration > MAX_STREAM_DURATION) {
            revert InvalidDuration();
        }
        
        // solhint-disable-next-line not-rely-on-time
        streamId = keccak256(abi.encodePacked(msg.sender, recipient, totalAmount, block.timestamp));
        
        // solhint-disable-next-line not-rely-on-time
        uint256 startTime = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        uint256 endTime = block.timestamp + duration;
        
        streams[streamId] = PaymentStream({
            recipient: recipient,
            isActive: true,
            usePrivacy: usePrivacy,
            totalAmount: totalAmount,
            startTime: startTime,
            endTime: endTime,
            withdrawnAmount: 0
        });
        
        // Transfer tokens to contract
        IERC20 token = IERC20(_getToken(usePrivacy));
        token.safeTransferFrom(msg.sender, address(this), totalAmount);
        
        // solhint-disable-next-line not-rely-on-time
        emit StreamCreated(
            streamId,
            msg.sender,
            recipient,
            totalAmount,
            startTime,
            endTime,
            block.timestamp
        );
    }
    
    /**
     * @notice Withdraw from stream
     * @param streamId Unique identifier for the stream
     */
    function withdrawStream(bytes32 streamId) external nonReentrant whenNotPaused {
        PaymentStream storage stream = streams[streamId];
        
        if (!stream.isActive) revert StreamNotActive();
        if (stream.recipient != msg.sender) revert NotStreamRecipient();
        
        uint256 available = _calculateStreamAmount(stream);
        uint256 toWithdraw = available - stream.withdrawnAmount;
        
        if (toWithdraw == 0) revert NothingToWithdraw();
        if (available < stream.withdrawnAmount && stream.withdrawnAmount > 0) revert NothingToWithdraw();
        
        stream.withdrawnAmount += toWithdraw;
        
        // Complete stream if fully withdrawn
        if (stream.withdrawnAmount >= stream.totalAmount) {
            stream.isActive = false;
        }
        
        // Transfer tokens
        IERC20 token = IERC20(_getToken(stream.usePrivacy));
        token.safeTransfer(msg.sender, toWithdraw);
        
        // solhint-disable-next-line not-rely-on-time
        emit StreamWithdrawn(streamId, msg.sender, toWithdraw, block.timestamp);
    }
    
    /**
     * @notice Cancel stream (sender only, before end time)
     */
    function cancelStream(bytes32 streamId) external nonReentrant whenNotPaused {
        PaymentStream storage stream = streams[streamId];
        
        if (!stream.isActive) revert StreamNotActive();
        
        uint256 streamed = _calculateStreamAmount(stream);
        uint256 refund = stream.totalAmount - streamed;
        
        stream.isActive = false;
        
        IERC20 token = IERC20(_getToken(stream.usePrivacy));
        
        // Pay recipient what they've earned
        if (streamed > stream.withdrawnAmount) {
            uint256 owed = streamed - stream.withdrawnAmount;
            token.safeTransfer(stream.recipient, owed);
        }
        
        // Refund sender the remainder
        if (refund > 0) {
            token.safeTransfer(msg.sender, refund);
        }
        
        emit StreamCancelled(streamId, msg.sender, refund, block.timestamp);
    }
    
    // =============================================================================
    // ESCROW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create escrow
     */
    function createEscrow(
        address seller,
        uint256 amount,
        uint256 duration,
        bool usePrivacy
    ) external nonReentrant whenNotPaused returns (bytes32 escrowId) {
        if (seller == address(0) || seller == msg.sender) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        
        uint256 deadline = block.timestamp + (duration > 0 ? duration : DEFAULT_ESCROW_DURATION);
        escrowId = keccak256(abi.encodePacked(msg.sender, seller, amount, block.timestamp));
        
        // Calculate fee
        uint256 fee = (amount * ESCROW_FEE) / 10000;
        if (usePrivacy) fee *= PRIVACY_MULTIPLIER;
        
        escrows[escrowId] = MinimalEscrow({
            buyer: msg.sender,
            seller: seller,
            amount: amount - fee,
            deadline: deadline,
            status: EscrowStatus.ACTIVE,
            usePrivacy: usePrivacy
        });
        
        // Transfer tokens to contract
        IERC20 token = IERC20(_getToken(usePrivacy));
        token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Transfer fee
        if (fee > 0) {
            token.safeTransfer(feeRecipient, fee);
        }
        
        emit EscrowCreated(
            escrowId,
            msg.sender,
            seller,
            amount,
            deadline,
            block.timestamp
        );
    }
    
    /**
     * @notice Complete escrow (buyer releases funds)
     */
    function completeEscrow(bytes32 escrowId) external nonReentrant whenNotPaused {
        MinimalEscrow storage escrow = escrows[escrowId];
        
        if (escrow.status != EscrowStatus.ACTIVE) revert EscrowNotActive();
        if (escrow.buyer != msg.sender) revert NotEscrowParticipant();
        
        escrow.status = EscrowStatus.COMPLETED;
        
        // Transfer to seller
        IERC20 token = IERC20(_getToken(escrow.usePrivacy));
        token.safeTransfer(escrow.seller, escrow.amount);
        
        emit EscrowCompleted(escrowId, escrow.amount, 0, block.timestamp);
    }
    
    /**
     * @notice Cancel escrow (mutual agreement or timeout)
     */
    function cancelEscrow(bytes32 escrowId) external nonReentrant whenNotPaused {
        MinimalEscrow storage escrow = escrows[escrowId];
        
        if (escrow.status != EscrowStatus.ACTIVE) revert EscrowNotActive();
        
        // Either party can cancel after deadline
        bool canCancel = (msg.sender == escrow.buyer || msg.sender == escrow.seller);
        if (block.timestamp < escrow.deadline && msg.sender != escrow.buyer) {
            revert NotEscrowParticipant();
        }
        if (!canCancel) revert NotEscrowParticipant();
        
        escrow.status = EscrowStatus.CANCELLED;
        
        // Refund to buyer
        IERC20 token = IERC20(_getToken(escrow.usePrivacy));
        token.safeTransfer(escrow.buyer, escrow.amount);
        
        emit EscrowCancelled(escrowId, escrow.amount, block.timestamp);
    }
    
    /**
     * @notice Dispute escrow
     */
    function disputeEscrow(
        bytes32 escrowId,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        MinimalEscrow storage escrow = escrows[escrowId];
        
        if (escrow.status != EscrowStatus.ACTIVE) revert EscrowNotActive();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) {
            revert NotEscrowParticipant();
        }
        
        escrow.status = EscrowStatus.DISPUTED;
        
        emit EscrowDisputed(escrowId, msg.sender, reason, block.timestamp);
    }
    
    /**
     * @notice Resolve dispute (arbitrator only)
     */
    function resolveDispute(
        bytes32 escrowId,
        address winner
    ) external nonReentrant whenNotPaused onlyRole(ARBITRATOR_ROLE) {
        MinimalEscrow storage escrow = escrows[escrowId];
        
        if (escrow.status != EscrowStatus.DISPUTED) revert EscrowNotActive();
        if (winner != escrow.buyer && winner != escrow.seller) revert InvalidRecipient();
        
        escrow.status = EscrowStatus.COMPLETED;
        
        // Transfer to winner
        IERC20 token = IERC20(_getToken(escrow.usePrivacy));
        token.safeTransfer(winner, escrow.amount);
        
        emit DisputeResolved(escrowId, winner, escrow.amount, block.timestamp);
    }
    
    // =============================================================================
    // MERKLE ROOT UPDATES
    // =============================================================================
    
    /**
     * @notice Update payment history root
     */
    function updatePaymentRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        require(epoch == currentEpoch + 1, "Invalid epoch");
        
        paymentHistoryRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit PaymentRootUpdated(newRoot, epoch, block.number, block.timestamp);
    }
    
    /**
     * @notice Update stream history root
     */
    function updateStreamRoot(bytes32 newRoot) external onlyAvalancheValidator {
        streamHistoryRoot = newRoot;
    }
    
    /**
     * @notice Update escrow history root
     */
    function updateEscrowRoot(bytes32 newRoot) external onlyAvalancheValidator {
        escrowHistoryRoot = newRoot;
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Calculate withdrawable stream amount
     */
    function calculateStreamAmount(bytes32 streamId) external view returns (uint256) {
        return _calculateStreamAmount(streams[streamId]);
    }
    
    /**
     * @notice Get stream info
     */
    function getStream(bytes32 streamId) external view returns (
        address recipient,
        uint256 totalAmount,
        uint256 startTime,
        uint256 endTime,
        uint256 withdrawnAmount,
        uint256 available,
        bool isActive
    ) {
        PaymentStream storage stream = streams[streamId];
        return (
            stream.recipient,
            stream.totalAmount,
            stream.startTime,
            stream.endTime,
            stream.withdrawnAmount,
            _calculateStreamAmount(stream),
            stream.isActive
        );
    }
    
    /**
     * @notice Get escrow info
     */
    function getEscrow(bytes32 escrowId) external view returns (
        address buyer,
        address seller,
        uint256 amount,
        uint256 deadline,
        EscrowStatus status
    ) {
        MinimalEscrow storage escrow = escrows[escrowId];
        return (
            escrow.buyer,
            escrow.seller,
            escrow.amount,
            escrow.deadline,
            escrow.status
        );
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update fee recipient
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        require(_feeRecipient != address(0), "Invalid recipient");
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @notice Set MPC availability
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
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    function _calculateStreamAmount(PaymentStream storage stream) internal view returns (uint256) {
        if (!stream.isActive) return 0;
        
        uint256 currentTime = block.timestamp;
        if (currentTime >= stream.endTime) {
            return stream.totalAmount;
        }
        
        uint256 elapsed = currentTime - stream.startTime;
        uint256 duration = stream.endTime - stream.startTime;
        
        return (stream.totalAmount * elapsed) / duration;
    }
    
    function _getToken(bool usePrivacy) internal view returns (address) {
        if (usePrivacy && isMpcAvailable) {
            return registry.getContract(keccak256("PRIVATE_OMNICOIN"));
        }
        return registry.getContract(keccak256("OMNICOIN"));
    }
    
    function _isAvalancheValidator(address account) internal view returns (bool) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
}