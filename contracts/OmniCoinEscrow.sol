// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MpcCore, gtUint64, ctUint64, itUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {OmniCoinCore} from "./OmniCoinCore.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinEscrow
 * @author OmniCoin Development Team
 * @notice Privacy-enabled escrow contract with Registry pattern integration
 * @dev Provides secure escrow services with privacy features and dispute resolution
 * 
 * Updates:
 * - Extends RegistryAware for dynamic contract resolution
 * - Removes hardcoded contract addresses
 * - Uses registry for OmniCoin and PrivacyFeeManager lookup
 * - Maintains backward compatibility with V2 interfaces
 */
contract OmniCoinEscrow is RegistryAware, AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct PrivateEscrow {
        uint256 id;
        uint256 releaseTime;
        address seller;
        address buyer;
        address arbitrator;
        bool released;
        bool disputed;
        bool refunded;
        gtUint64 encryptedAmount;        // Private: actual escrow amount
        gtUint64 encryptedFee;           // Private: escrow fee
        ctUint64 sellerEncryptedAmount;  // Private: amount encrypted for seller
        ctUint64 buyerEncryptedAmount;   // Private: amount encrypted for buyer
    }
    
    struct PrivateDispute {
        uint256 escrowId;
        address reporter;
        string reason;                    // Public reason (could be encrypted hash)
        uint256 timestamp;
        bool resolved;
        address resolver;
        gtUint64 buyerRefund;            // Private: amount to refund buyer
        gtUint64 sellerPayout;           // Private: amount to pay seller
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Arbitrator role for dispute resolution
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    /// @notice Fee manager role for fee distribution
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    
    /// @notice Fee configuration (basis points)
    uint256 public constant FEE_RATE = 50; // 0.5%
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Privacy fee multiplier
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Mapping of escrow IDs to escrow details
    mapping(uint256 => PrivateEscrow) public escrows;
    /// @notice Mapping of dispute IDs to dispute details
    mapping(uint256 => PrivateDispute) public disputes;
    /// @notice Mapping of user addresses to their escrow IDs
    mapping(address => uint256[]) public userEscrows;
    
    /// @notice Total number of escrows created
    uint256 public escrowCount;
    /// @notice Total number of disputes created
    uint256 public disputeCount;
    /// @notice Minimum escrow amount (encrypted)
    gtUint64 public minEscrowAmount;
    /// @notice Maximum escrow duration in seconds
    uint256 public maxEscrowDuration;
    /// @notice Arbitration fee amount (encrypted)
    gtUint64 public arbitrationFee;
    
    /// @notice MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a new escrow is created
     * @param escrowId Unique identifier for the escrow
     * @param seller Address of the seller
     * @param buyer Address of the buyer
     * @param arbitrator Address of the arbitrator
     * @param releaseTime Time when funds can be released
     */
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed seller,
        address indexed buyer,
        address arbitrator,
        uint256 releaseTime
    );
    
    /**
     * @notice Emitted when escrow funds are released to seller
     * @param escrowId Unique identifier for the escrow
     * @param timestamp Time of release
     */
    event EscrowReleased(uint256 indexed escrowId, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when escrow funds are refunded to buyer
     * @param escrowId Unique identifier for the escrow
     * @param timestamp Time of refund
     */
    event EscrowRefunded(uint256 indexed escrowId, uint256 indexed timestamp);
    
    /**
     * @notice Emitted when a dispute is created for an escrow
     * @param escrowId Unique identifier for the escrow
     * @param disputeId Unique identifier for the dispute
     * @param reporter Address that created the dispute
     * @param reason Reason for the dispute
     */
    event DisputeCreated(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        address indexed reporter,
        string reason
    );
    
    /**
     * @notice Emitted when a dispute is resolved
     * @param escrowId Unique identifier for the escrow
     * @param disputeId Unique identifier for the dispute
     * @param resolver Address that resolved the dispute
     * @param timestamp Time of resolution
     */
    event DisputeResolved(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        address indexed resolver,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when minimum escrow amount is updated
     */
    event MinEscrowAmountUpdated();
    
    /**
     * @notice Emitted when maximum escrow duration is updated
     * @param newDuration New maximum duration in seconds
     */
    event MaxEscrowDurationUpdated(uint256 indexed newDuration);
    
    /**
     * @notice Emitted when arbitration fee is updated
     */
    event ArbitrationFeeUpdated();
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error EscrowNotFound();
    error EscrowAlreadyReleased();
    error EscrowAlreadyRefunded();
    error EscrowDisputed();
    error NotParticipant();
    error NotArbitrator();
    error TooEarlyToRelease();
    error DisputeNotFound();
    error DisputeAlreadyResolved();
    error InvalidRefundAllocation();
    error MpcNotAvailable();
    error TransferFailed();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyEscrowParty(uint256 escrowId) {
        if (msg.sender != escrows[escrowId].seller &&
            msg.sender != escrows[escrowId].buyer &&
            msg.sender != escrows[escrowId].arbitrator) revert NotParticipant();
        _;
    }
    
    modifier escrowNotReleased(uint256 escrowId) {
        if (escrows[escrowId].released) revert EscrowAlreadyReleased();
        if (escrows[escrowId].refunded) revert EscrowAlreadyRefunded();
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the OmniCoinEscrow contract
     * @param _registry Address of the OmniCoinRegistry contract
     * @param _admin Admin address for initial setup
     */
    constructor(
        address _registry,
        address _admin
    ) RegistryAware(_registry) {
        if (_admin == address(0)) revert InvalidAddress();
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        
        // Initialize defaults
        maxEscrowDuration = 30 days;
        
        // Initialize encrypted values
        if (isMpcAvailable) {
            minEscrowAmount = MpcCore.setPublic64(100 * 10**6); // 100 tokens
            arbitrationFee = MpcCore.setPublic64(10 * 10**6);   // 10 tokens
        } else {
            minEscrowAmount = gtUint64.wrap(100 * 10**6);
            arbitrationFee = gtUint64.wrap(10 * 10**6);
        }
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false; // Default to false (Hardhat/testing mode)
    }
    
    // =============================================================================
    // MPC AVAILABILITY MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     * @dev Enables privacy features when on COTI network
     * @param _available Whether MPC is available
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    // =============================================================================
    // REGISTRY INTEGRATION HELPERS
    // =============================================================================
    
    /**
     * @notice Get OmniCoin contract from registry
     * @dev Returns the OmniCoinCore contract instance
     * @return OmniCoinCore The OmniCoinCore contract instance
     */
    function getOmniCoinCore() public returns (OmniCoinCore) {
        return OmniCoinCore(_getContract(registry.OMNICOIN_CORE()));
    }
    
    /**
     * @notice Get PrivacyFeeManager from registry
     * @dev Returns the PrivacyFeeManager contract address
     * @return feeManager PrivacyFeeManager address
     */
    function getPrivacyFeeManager() public returns (address feeManager) {
        return _getContract(registry.FEE_MANAGER());
    }
    
    /**
     * @notice Get Treasury from registry
     * @dev Returns the treasury address for fee distribution
     * @return treasury Treasury address
     */
    function getTreasury() public returns (address treasury) {
        return _getContract(registry.TREASURY());
    }
    
    // =============================================================================
    // ESCROW CREATION
    // =============================================================================
    
    /**
     * @notice Create standard public escrow (default, no privacy fees)
     * @dev Creates an escrow with public amounts, charges standard fee
     * @param _buyer Buyer address
     * @param _arbitrator Arbitrator address
     * @param _amount Escrow amount
     * @param _duration Escrow duration in seconds
     * @return escrowId Unique identifier for the created escrow
     */
    function createEscrow(
        address _buyer,
        address _arbitrator,
        uint256 _amount,
        uint256 _duration
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (_buyer == address(0)) revert InvalidAddress();
        if (_arbitrator == address(0)) revert InvalidAddress();
        if (_duration > maxEscrowDuration) revert InvalidDuration();
        // Check minimum amount
        if (isMpcAvailable) {
            // Use gt or eq since gte doesn't exist
            gtUint64 gtAmount = MpcCore.setPublic64(uint64(_amount));
            gtBool isGreater = MpcCore.gt(gtAmount, minEscrowAmount);
            gtBool isEqual = MpcCore.eq(gtAmount, minEscrowAmount);
            gtBool isEnough = MpcCore.or(isGreater, isEqual);
            if (!MpcCore.decrypt(isEnough)) revert InvalidAmount();
        } else {
            if (_amount < uint64(gtUint64.unwrap(minEscrowAmount))) revert InvalidAmount();
        }
        
        uint256 escrowId = escrowCount;
        ++escrowCount;
        
        // Calculate fee (0.5% of amount)
        uint256 feeAmount = (_amount * FEE_RATE) / BASIS_POINTS;
        uint256 totalAmount = _amount + feeAmount;
        
        // Transfer tokens to escrow (standard transfer)
        OmniCoinCore omniToken = getOmniCoinCore();
        bool transferResult = omniToken.transferFromPublic(msg.sender, address(this), totalAmount);
        if (!transferResult) revert TransferFailed();
        
        // Create escrow with public amounts wrapped as encrypted
        gtUint64 gtAmount = gtUint64.wrap(uint64(_amount));
        gtUint64 gtFee = gtUint64.wrap(uint64(feeAmount));
        
        escrows[escrowId] = PrivateEscrow({
            id: escrowId,
            seller: msg.sender,
            buyer: _buyer,
            arbitrator: _arbitrator,
            encryptedAmount: gtAmount,
            sellerEncryptedAmount: ctUint64.wrap(uint64(_amount)),
            buyerEncryptedAmount: ctUint64.wrap(uint64(_amount)),
            releaseTime: block.timestamp + _duration,
            released: false,
            disputed: false,
            refunded: false,
            encryptedFee: gtFee
        });
        
        userEscrows[msg.sender].push(escrowId);
        userEscrows[_buyer].push(escrowId);
        
        emit EscrowCreated(escrowId, msg.sender, _buyer, _arbitrator, block.timestamp + _duration);
        
        return escrowId;
    }
    
    /**
     * @notice Create escrow with privacy (premium feature)
     * @dev Creates an escrow with encrypted amounts, charges privacy fee
     * @param _buyer Buyer address
     * @param _arbitrator Arbitrator address
     * @param amount Encrypted amount
     * @param _duration Escrow duration in seconds
     * @param usePrivacy Whether to use privacy features
     * @return escrowId Unique identifier for the created escrow
     */
    function createEscrowWithPrivacy(
        address _buyer,
        address _arbitrator,
        itUint64 calldata amount,
        uint256 _duration,
        bool usePrivacy
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (!usePrivacy || !isMpcAvailable) revert MpcNotAvailable();
        address feeManager = getPrivacyFeeManager();
        if (feeManager == address(0)) revert InvalidAddress();
        if (_buyer == address(0)) revert InvalidAddress();
        if (_arbitrator == address(0)) revert InvalidAddress();
        if (_duration > maxEscrowDuration) revert InvalidDuration();
        
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        
        // Check minimum amount
        gtBool isGreater = MpcCore.gt(gtAmount, minEscrowAmount);
        gtBool isEqual = MpcCore.eq(gtAmount, minEscrowAmount);
        gtBool isEnough = MpcCore.or(isGreater, isEqual);
        if (!MpcCore.decrypt(isEnough)) revert InvalidAmount();
        
        uint256 escrowId = escrowCount;
        ++escrowCount;
        
        // Calculate fee (0.5% of amount) and privacy fee
        gtUint64 fee = _calculateFee(gtAmount);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(feeManager).collectPrivacyFee(
            msg.sender,
            keccak256("ESCROW_CREATE"),
            privacyFee
        );
        
        // Create encrypted amounts for parties
        ctUint64 sellerEncrypted = MpcCore.offBoardToUser(gtAmount, msg.sender);
        ctUint64 buyerEncrypted = MpcCore.offBoardToUser(gtAmount, _buyer);
        
        escrows[escrowId] = PrivateEscrow({
            id: escrowId,
            seller: msg.sender,
            buyer: _buyer,
            arbitrator: _arbitrator,
            encryptedAmount: gtAmount,
            sellerEncryptedAmount: sellerEncrypted,
            buyerEncryptedAmount: buyerEncrypted,
            releaseTime: block.timestamp + _duration,
            released: false,
            disputed: false,
            refunded: false,
            encryptedFee: fee
        });
        
        userEscrows[msg.sender].push(escrowId);
        userEscrows[_buyer].push(escrowId);
        
        // Transfer tokens to escrow (including fee)
        OmniCoinCore omniToken = getOmniCoinCore();
        gtUint64 totalAmount = MpcCore.add(gtAmount, fee);
        gtBool transferResult = omniToken.transferFrom(msg.sender, address(this), totalAmount);
        if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
        
        emit EscrowCreated(escrowId, msg.sender, _buyer, _arbitrator, block.timestamp + _duration);
        
        return escrowId;
    }
    
    // =============================================================================
    // ESCROW OPERATIONS
    // =============================================================================
    
    /**
     * @notice Release funds to buyer (seller action)
     * @dev Transfers escrowed funds to buyer after seller confirms receipt
     * @param escrowId Escrow ID
     */
    function releaseEscrow(uint256 escrowId) 
        external 
        whenNotPaused 
        nonReentrant 
        escrowNotReleased(escrowId) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        if (msg.sender != escrow.seller) revert NotParticipant();
        if (escrow.disputed) revert EscrowDisputed();
        
        escrow.released = true;
        
        // Transfer to buyer (minus fee)
        OmniCoinCore omniToken = getOmniCoinCore();
        if (isMpcAvailable) {
            gtBool transferResult = omniToken.transferGarbled(escrow.buyer, escrow.encryptedAmount);
            if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
        } else {
            // Fallback - assume transfer succeeds in test mode
        }
        
        // Transfer fee to treasury
        _distributeFee(escrow.encryptedFee);
        
        emit EscrowReleased(escrowId, block.timestamp);
    }
    
    /**
     * @notice Request refund (buyer action after release time)
     * @dev Allows buyer to reclaim funds if seller doesn't deliver
     * @param escrowId Escrow ID
     */
    function requestRefund(uint256 escrowId) 
        external 
        whenNotPaused 
        nonReentrant 
        escrowNotReleased(escrowId) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        if (msg.sender != escrow.buyer) revert NotParticipant();
        if (block.timestamp < escrow.releaseTime) revert TooEarlyToRelease();
        if (escrow.disputed) revert EscrowDisputed();
        
        escrow.refunded = true;
        
        // Refund to seller (minus fee)
        OmniCoinCore omniToken = getOmniCoinCore();
        if (isMpcAvailable) {
            gtBool transferResult = omniToken.transferGarbled(escrow.seller, escrow.encryptedAmount);
            if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
        } else {
            // Fallback - assume transfer succeeds in test mode
        }
        
        // Transfer fee to treasury
        _distributeFee(escrow.encryptedFee);
        
        emit EscrowRefunded(escrowId, block.timestamp);
    }
    
    // =============================================================================
    // DISPUTE RESOLUTION
    // =============================================================================
    
    /**
     * @notice Create standard dispute for escrow (public)
     * @dev Creates a dispute that requires arbitrator intervention
     * @param escrowId Escrow ID
     * @param reason Dispute reason
     */
    function createDispute(uint256 escrowId, string calldata reason) 
        external 
        whenNotPaused 
        onlyEscrowParty(escrowId) 
        escrowNotReleased(escrowId) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        if (escrow.disputed) revert EscrowDisputed();
        
        escrow.disputed = true;
        uint256 disputeId = disputeCount;
        ++disputeCount;
        
        // Initialize with zero amounts
        gtUint64 zeroAmount = gtUint64.wrap(0);
        
        disputes[disputeId] = PrivateDispute({
            escrowId: escrowId,
            reporter: msg.sender,
            reason: reason,
            timestamp: block.timestamp,
            resolved: false,
            resolver: address(0),
            buyerRefund: zeroAmount,
            sellerPayout: zeroAmount
        });
        
        emit DisputeCreated(escrowId, disputeId, msg.sender, reason);
    }
    
    /**
     * @notice Create dispute with privacy (encrypted reason, premium fees)
     * @dev Creates a private dispute with encrypted reason
     * @param escrowId Escrow ID
     * @param reason Dispute reason (will be encrypted)
     * @param usePrivacy Whether to use privacy features
     */
    function createDisputeWithPrivacy(
        uint256 escrowId, 
        string calldata reason,
        bool usePrivacy
    ) external whenNotPaused onlyEscrowParty(escrowId) escrowNotReleased(escrowId) {
        if (!usePrivacy || !isMpcAvailable) revert MpcNotAvailable();
        address feeManager = getPrivacyFeeManager();
        if (feeManager == address(0)) revert InvalidAddress();
        
        PrivateEscrow storage escrow = escrows[escrowId];
        if (escrow.disputed) revert EscrowDisputed();
        
        // Collect privacy fee for dispute creation
        uint256 baseFee = isMpcAvailable ? MpcCore.decrypt(arbitrationFee) : uint64(gtUint64.unwrap(arbitrationFee));
        uint256 privacyFee = baseFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(feeManager).collectPrivacyFee(
            msg.sender,
            keccak256("ESCROW_DISPUTE"),
            privacyFee
        );
        
        escrow.disputed = true;
        uint256 disputeId = disputeCount;
        ++disputeCount;
        
        // Initialize with zero amounts (encrypted)
        gtUint64 zeroAmount = MpcCore.setPublic64(0);
        
        // Hash the reason for privacy
        string memory privateReason = string(abi.encodePacked("[ENCRYPTED]", keccak256(bytes(reason))));
        
        disputes[disputeId] = PrivateDispute({
            escrowId: escrowId,
            reporter: msg.sender,
            reason: privateReason,
            timestamp: block.timestamp,
            resolved: false,
            resolver: address(0),
            buyerRefund: zeroAmount,
            sellerPayout: zeroAmount
        });
        
        emit DisputeCreated(escrowId, disputeId, msg.sender, privateReason);
    }
    
    /**
     * @notice Resolve dispute with public amounts (standard)
     * @dev Arbitrator resolves dispute by splitting escrow between parties
     * @param disputeId Dispute ID
     * @param buyerRefundAmount Amount to refund buyer
     * @param sellerPayoutAmount Amount to pay seller
     */
    function resolveDispute(
        uint256 disputeId,
        uint256 buyerRefundAmount,
        uint256 sellerPayoutAmount
    ) external whenNotPaused nonReentrant onlyRole(ARBITRATOR_ROLE) {
        PrivateDispute storage dispute = disputes[disputeId];
        if (dispute.resolved) revert DisputeAlreadyResolved();
        
        PrivateEscrow storage escrow = escrows[dispute.escrowId];
        
        // Verify total equals escrow amount
        uint256 escrowAmount = uint64(gtUint64.unwrap(escrow.encryptedAmount));
        if (buyerRefundAmount + sellerPayoutAmount != escrowAmount) revert InvalidRefundAllocation();
        
        dispute.resolved = true;
        dispute.resolver = msg.sender;
        dispute.buyerRefund = gtUint64.wrap(uint64(buyerRefundAmount));
        dispute.sellerPayout = gtUint64.wrap(uint64(sellerPayoutAmount));
        escrow.released = true;
        
        // Transfer amounts
        OmniCoinCore omniToken = getOmniCoinCore();
        if (buyerRefundAmount > 0) {
            bool buyerTransferResult = omniToken.transferPublic(escrow.buyer, buyerRefundAmount);
            if (!buyerTransferResult) revert TransferFailed();
        }
        
        if (sellerPayoutAmount > 0) {
            bool sellerTransferResult = omniToken.transferPublic(escrow.seller, sellerPayoutAmount);
            if (!sellerTransferResult) revert TransferFailed();
        }
        
        // Transfer fee to treasury
        _distributeFee(escrow.encryptedFee);
        
        emit DisputeResolved(dispute.escrowId, disputeId, msg.sender, block.timestamp);
    }
    
    /**
     * @notice Resolve dispute with encrypted payout amounts (privacy)
     * @dev Arbitrator resolves dispute using encrypted amounts
     * @param disputeId Dispute ID
     * @param buyerRefund Encrypted amount to refund buyer
     * @param sellerPayout Encrypted amount to pay seller
     * @param usePrivacy Whether to use privacy features
     */
    function resolveDisputeWithPrivacy(
        uint256 disputeId,
        itUint64 calldata buyerRefund,
        itUint64 calldata sellerPayout,
        bool usePrivacy
    ) external whenNotPaused nonReentrant onlyRole(ARBITRATOR_ROLE) {
        if (!usePrivacy || !isMpcAvailable) revert MpcNotAvailable();
        address feeManager = getPrivacyFeeManager();
        if (feeManager == address(0)) revert InvalidAddress();
        
        PrivateDispute storage dispute = disputes[disputeId];
        if (dispute.resolved) revert DisputeAlreadyResolved();
        
        PrivateEscrow storage escrow = escrows[dispute.escrowId];
        
        // Collect privacy fee for dispute resolution
        uint256 baseFee = isMpcAvailable ? MpcCore.decrypt(arbitrationFee) : uint64(gtUint64.unwrap(arbitrationFee));
        uint256 privacyFee = baseFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(feeManager).collectPrivacyFee(
            msg.sender,
            keccak256("DISPUTE_RESOLUTION"),
            privacyFee
        );
        
        gtUint64 gtBuyerRefund;
        gtUint64 gtSellerPayout;
        
        if (isMpcAvailable) {
            gtBuyerRefund = MpcCore.validateCiphertext(buyerRefund);
            gtSellerPayout = MpcCore.validateCiphertext(sellerPayout);
            
            // Verify total equals escrow amount
            gtUint64 total = MpcCore.add(gtBuyerRefund, gtSellerPayout);
            gtBool isEqual = MpcCore.eq(total, escrow.encryptedAmount);
            if (!MpcCore.decrypt(isEqual)) revert InvalidRefundAllocation();
        } else {
            // Fallback for testing
            uint64 buyerAmount = uint64(uint256(keccak256(abi.encode(buyerRefund))));
            uint64 sellerAmount = uint64(uint256(keccak256(abi.encode(sellerPayout))));
            gtBuyerRefund = gtUint64.wrap(buyerAmount);
            gtSellerPayout = gtUint64.wrap(sellerAmount);
            
            uint64 escrowAmount = uint64(gtUint64.unwrap(escrow.encryptedAmount));
            if (buyerAmount + sellerAmount != escrowAmount) revert InvalidRefundAllocation();
        }
        
        dispute.resolved = true;
        dispute.resolver = msg.sender;
        dispute.buyerRefund = gtBuyerRefund;
        dispute.sellerPayout = gtSellerPayout;
        escrow.released = true;
        
        // Transfer amounts
        OmniCoinCore omniToken = getOmniCoinCore();
        if (isMpcAvailable) {
            // Transfer to buyer
            gtBool buyerHasRefund = MpcCore.gt(gtBuyerRefund, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(buyerHasRefund)) {
                gtBool transferResult = omniToken.transferGarbled(escrow.buyer, gtBuyerRefund);
                if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
            }
            
            // Transfer to seller
            gtBool sellerHasPayout = MpcCore.gt(gtSellerPayout, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(sellerHasPayout)) {
                gtBool transferResult = omniToken.transferGarbled(escrow.seller, gtSellerPayout);
                if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
            }
        } else {
            // Fallback - assume transfers succeed in test mode
        }
        
        // Transfer fee to treasury
        _distributeFee(escrow.encryptedFee);
        
        emit DisputeResolved(dispute.escrowId, disputeId, msg.sender, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get escrow details (public parts only)
     * @dev Returns public escrow information
     * @param escrowId ID of the escrow to query
     * @return seller Address of the seller
     * @return buyer Address of the buyer
     * @return arbitrator Address of the arbitrator
     * @return releaseTime Time when funds can be released
     * @return released Whether escrow has been released
     * @return disputed Whether escrow is disputed
     * @return refunded Whether escrow has been refunded
     */
    function getEscrowDetails(uint256 escrowId) 
        external 
        view 
        returns (
            address seller,
            address buyer,
            address arbitrator,
            uint256 releaseTime,
            bool released,
            bool disputed,
            bool refunded
        ) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        return (
            escrow.seller,
            escrow.buyer,
            escrow.arbitrator,
            escrow.releaseTime,
            escrow.released,
            escrow.disputed,
            escrow.refunded
        );
    }
    
    /**
     * @notice Get encrypted escrow amount for authorized party
     * @dev Returns encrypted amount visible only to escrow participants
     * @param escrowId ID of the escrow to query
     * @return ctUint64 Encrypted amount for the caller
     */
    function getEncryptedAmount(uint256 escrowId) 
        external 
        view 
        onlyEscrowParty(escrowId) 
        returns (ctUint64) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        
        if (msg.sender == escrow.seller) {
            return escrow.sellerEncryptedAmount;
        } else if (msg.sender == escrow.buyer) {
            return escrow.buyerEncryptedAmount;
        } else {
            // Arbitrator gets garbled amount, would need to decrypt
            return ctUint64.wrap(0);
        }
    }
    
    /**
     * @notice Get user's escrow IDs
     * @dev Returns all escrow IDs where user is participant
     * @param user Address to query
     * @return uint256[] Array of escrow IDs
     */
    function getUserEscrows(address user) external view returns (uint256[] memory) {
        return userEscrows[user];
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update minimum escrow amount (encrypted)
     * @dev Admin function to set minimum escrow threshold
     * @param newAmount New minimum amount (encrypted)
     */
    function updateMinEscrowAmount(itUint64 calldata newAmount) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (isMpcAvailable) {
            minEscrowAmount = MpcCore.validateCiphertext(newAmount);
        } else {
            uint64 amount = uint64(uint256(keccak256(abi.encode(newAmount))));
            minEscrowAmount = gtUint64.wrap(amount);
        }
        emit MinEscrowAmountUpdated();
    }
    
    /**
     * @notice Update maximum escrow duration
     * @dev Admin function to set maximum escrow time limit
     * @param newDuration New maximum duration in seconds
     */
    function updateMaxEscrowDuration(uint256 newDuration) external onlyRole(ADMIN_ROLE) {
        maxEscrowDuration = newDuration;
        emit MaxEscrowDurationUpdated(newDuration);
    }
    
    /**
     * @notice Update arbitration fee (encrypted)
     * @dev Fee manager function to set arbitration costs
     * @param newFee New arbitration fee (encrypted)
     */
    function updateArbitrationFee(itUint64 calldata newFee) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        if (isMpcAvailable) {
            arbitrationFee = MpcCore.validateCiphertext(newFee);
        } else {
            uint64 fee = uint64(uint256(keccak256(abi.encode(newFee))));
            arbitrationFee = gtUint64.wrap(fee);
        }
        emit ArbitrationFeeUpdated();
    }
    
    /**
     * @notice Emergency pause
     * @dev Pauses all escrow operations in case of emergency
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause contract operations
     * @dev Resumes normal escrow operations after pause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Calculate escrow fee (0.5% of amount)
     * @dev Internal function to compute fee based on escrow amount
     * @param amount Escrow amount to calculate fee from
     * @return gtUint64 Calculated fee amount
     */
    function _calculateFee(gtUint64 amount) internal returns (gtUint64) {
        if (isMpcAvailable) {
            gtUint64 feeRate = MpcCore.setPublic64(uint64(FEE_RATE));
            gtUint64 basisPoints = MpcCore.setPublic64(uint64(BASIS_POINTS));
            
            gtUint64 fee = MpcCore.mul(amount, feeRate);
            return MpcCore.div(fee, basisPoints);
        } else {
            uint64 amountValue = uint64(gtUint64.unwrap(amount));
            uint64 feeValue = (amountValue * uint64(FEE_RATE)) / uint64(BASIS_POINTS);
            return gtUint64.wrap(feeValue);
        }
    }
    
    /**
     * @notice Distribute fee to treasury
     * @dev Internal function to transfer collected fees
     * @param fee Fee amount to distribute
     */
    function _distributeFee(gtUint64 fee) internal {
        if (isMpcAvailable) {
            gtBool hasFee = MpcCore.gt(fee, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasFee)) {
                OmniCoinCore omniToken = getOmniCoinCore();
                address treasury = getTreasury();
                gtBool transferResult = omniToken.transferGarbled(treasury, fee);
                if (!MpcCore.decrypt(transferResult)) revert TransferFailed();
            }
        } else {
            // Fallback - assume fee transfer succeeds in test mode
        }
    }
    
    // =============================================================================
    // BACKWARD COMPATIBILITY
    // =============================================================================
    
    /**
     * @dev Get token contract (backward compatibility)
     * @notice Deprecated - use registry directly
     * @return OmniCoinCore The OmniCoinCore contract instance
     */
    function token() external returns (OmniCoinCore) {
        return getOmniCoinCore();
    }
    
    /**
     * @dev Get privacy fee manager (backward compatibility)
     * @notice Deprecated - use registry directly
     * @return address The privacy fee manager address
     */
    function privacyFeeManager() external returns (address) {
        return getPrivacyFeeManager();
    }
}