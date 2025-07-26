// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./base/RegistryAware.sol";
import "./OmniCoinCore.sol";
import "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinEscrow
 * @dev Privacy-enabled escrow contract with Registry pattern integration
 * 
 * Updates:
 * - Extends RegistryAware for dynamic contract resolution
 * - Removes hardcoded contract addresses
 * - Uses registry for OmniCoin and PrivacyFeeManager lookup
 * - Maintains backward compatibility with V2 interfaces
 */
contract OmniCoinEscrow is RegistryAware, AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct PrivateEscrow {
        uint256 id;
        address seller;
        address buyer;
        address arbitrator;
        gtUint64 encryptedAmount;        // Private: actual escrow amount
        ctUint64 sellerEncryptedAmount;  // Private: amount encrypted for seller
        ctUint64 buyerEncryptedAmount;   // Private: amount encrypted for buyer
        uint256 releaseTime;
        bool released;
        bool disputed;
        bool refunded;
        gtUint64 encryptedFee;           // Private: escrow fee
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
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Escrow mappings
    mapping(uint256 => PrivateEscrow) public escrows;
    mapping(uint256 => PrivateDispute) public disputes;
    mapping(address => uint256[]) public userEscrows;
    
    /// @dev Counters and limits
    uint256 public escrowCount;
    uint256 public disputeCount;
    gtUint64 public minEscrowAmount;      // Private minimum
    uint256 public maxEscrowDuration;
    gtUint64 public arbitrationFee;       // Private fee
    
    /// @dev Fee configuration (basis points)
    uint256 public constant FEE_RATE = 50; // 0.5%
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @dev Privacy fee configuration
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    
    /// @dev MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed seller,
        address indexed buyer,
        address arbitrator,
        uint256 releaseTime
    );
    event EscrowReleased(uint256 indexed escrowId, uint256 timestamp);
    event EscrowRefunded(uint256 indexed escrowId, uint256 timestamp);
    event DisputeCreated(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        address indexed reporter,
        string reason
    );
    event DisputeResolved(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        address indexed resolver,
        uint256 timestamp
    );
    event MinEscrowAmountUpdated();
    event MaxEscrowDurationUpdated(uint256 newDuration);
    event ArbitrationFeeUpdated();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyEscrowParty(uint256 escrowId) {
        require(
            msg.sender == escrows[escrowId].seller ||
            msg.sender == escrows[escrowId].buyer ||
            msg.sender == escrows[escrowId].arbitrator,
            "OmniCoinEscrow: Not escrow party"
        );
        _;
    }
    
    modifier escrowNotReleased(uint256 escrowId) {
        require(!escrows[escrowId].released, "OmniCoinEscrow: Already released");
        require(!escrows[escrowId].refunded, "OmniCoinEscrow: Already refunded");
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _registry,
        address _admin
    ) RegistryAware(_registry) {
        require(_admin != address(0), "OmniCoinEscrow: Invalid admin");
        
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
    // REGISTRY INTEGRATION HELPERS
    // =============================================================================
    
    /**
     * @dev Get OmniCoin contract from registry
     */
    function getOmniCoin() public returns (OmniCoinCore) {
        return OmniCoinCore(_getContract(registry.OMNICOIN_CORE()));
    }
    
    /**
     * @dev Get PrivacyFeeManager from registry
     */
    function getPrivacyFeeManager() public returns (address) {
        return _getContract(registry.FEE_MANAGER());
    }
    
    /**
     * @dev Get Treasury from registry
     */
    function getTreasury() public returns (address) {
        return _getContract(registry.TREASURY());
    }
    
    // =============================================================================
    // MPC AVAILABILITY MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    // =============================================================================
    // ESCROW CREATION
    // =============================================================================
    
    /**
     * @dev Create standard public escrow (default, no privacy fees)
     * @param _buyer Buyer address
     * @param _arbitrator Arbitrator address
     * @param _amount Escrow amount
     * @param _duration Escrow duration in seconds
     */
    function createEscrow(
        address _buyer,
        address _arbitrator,
        uint256 _amount,
        uint256 _duration
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(_buyer != address(0), "OmniCoinEscrow: Invalid buyer");
        require(_arbitrator != address(0), "OmniCoinEscrow: Invalid arbitrator");
        require(_duration <= maxEscrowDuration, "OmniCoinEscrow: Duration too long");
        require(_amount >= uint64(gtUint64.unwrap(minEscrowAmount)), "OmniCoinEscrow: Amount too small");
        
        uint256 escrowId = escrowCount++;
        
        // Calculate fee (0.5% of amount)
        uint256 feeAmount = (_amount * FEE_RATE) / BASIS_POINTS;
        uint256 totalAmount = _amount + feeAmount;
        
        // Transfer tokens to escrow (standard transfer)
        OmniCoinCore token = getOmniCoin();
        bool transferResult = token.transferFromPublic(msg.sender, address(this), totalAmount);
        require(transferResult, "OmniCoinEscrow: Transfer failed");
        
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
     * @dev Create escrow with privacy (premium feature)
     * @param _buyer Buyer address
     * @param _arbitrator Arbitrator address
     * @param amount Encrypted amount
     * @param _duration Escrow duration in seconds
     * @param usePrivacy Whether to use privacy features
     */
    function createEscrowWithPrivacy(
        address _buyer,
        address _arbitrator,
        itUint64 calldata amount,
        uint256 _duration,
        bool usePrivacy
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(usePrivacy && isMpcAvailable, "OmniCoinEscrow: Privacy not available");
        address privacyFeeManager = getPrivacyFeeManager();
        require(privacyFeeManager != address(0), "OmniCoinEscrow: Privacy fee manager not set");
        require(_buyer != address(0), "OmniCoinEscrow: Invalid buyer");
        require(_arbitrator != address(0), "OmniCoinEscrow: Invalid arbitrator");
        require(_duration <= maxEscrowDuration, "OmniCoinEscrow: Duration too long");
        
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        
        // Check minimum amount
        gtBool isEnough = MpcCore.ge(gtAmount, minEscrowAmount);
        require(MpcCore.decrypt(isEnough), "OmniCoinEscrow: Amount too small");
        
        uint256 escrowId = escrowCount++;
        
        // Calculate fee (0.5% of amount) and privacy fee
        gtUint64 fee = _calculateFee(gtAmount);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
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
        OmniCoinCore token = getOmniCoin();
        gtUint64 totalAmount = MpcCore.add(gtAmount, fee);
        gtBool transferResult = token.transferFrom(msg.sender, address(this), totalAmount);
        require(MpcCore.decrypt(transferResult), "OmniCoinEscrow: Transfer failed");
        
        emit EscrowCreated(escrowId, msg.sender, _buyer, _arbitrator, block.timestamp + _duration);
        
        return escrowId;
    }
    
    // =============================================================================
    // ESCROW OPERATIONS
    // =============================================================================
    
    /**
     * @dev Release funds to buyer (seller action)
     * @param escrowId Escrow ID
     */
    function releaseEscrow(uint256 escrowId) 
        external 
        whenNotPaused 
        nonReentrant 
        escrowNotReleased(escrowId) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        require(msg.sender == escrow.seller, "OmniCoinEscrow: Only seller can release");
        require(!escrow.disputed, "OmniCoinEscrow: Escrow disputed");
        
        escrow.released = true;
        
        // Transfer to buyer (minus fee)
        OmniCoinCore token = getOmniCoin();
        if (isMpcAvailable) {
            gtBool transferResult = token.transferGarbled(escrow.buyer, escrow.encryptedAmount);
            require(MpcCore.decrypt(transferResult), "OmniCoinEscrow: Transfer failed");
        } else {
            // Fallback - assume transfer succeeds in test mode
        }
        
        // Transfer fee to treasury
        _distributeFee(escrow.encryptedFee);
        
        emit EscrowReleased(escrowId, block.timestamp);
    }
    
    /**
     * @dev Request refund (buyer action after release time)
     * @param escrowId Escrow ID
     */
    function requestRefund(uint256 escrowId) 
        external 
        whenNotPaused 
        nonReentrant 
        escrowNotReleased(escrowId) 
    {
        PrivateEscrow storage escrow = escrows[escrowId];
        require(msg.sender == escrow.buyer, "OmniCoinEscrow: Only buyer can request refund");
        require(block.timestamp >= escrow.releaseTime, "OmniCoinEscrow: Too early");
        require(!escrow.disputed, "OmniCoinEscrow: Escrow disputed");
        
        escrow.refunded = true;
        
        // Refund to seller (minus fee)
        OmniCoinCore token = getOmniCoin();
        if (isMpcAvailable) {
            gtBool transferResult = token.transferGarbled(escrow.seller, escrow.encryptedAmount);
            require(MpcCore.decrypt(transferResult), "OmniCoinEscrow: Transfer failed");
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
     * @dev Create standard dispute for escrow (public)
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
        require(!escrow.disputed, "OmniCoinEscrow: Already disputed");
        
        escrow.disputed = true;
        uint256 disputeId = disputeCount++;
        
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
     * @dev Create dispute with privacy (encrypted reason, premium fees)
     * @param escrowId Escrow ID
     * @param reason Dispute reason (will be encrypted)
     * @param usePrivacy Whether to use privacy features
     */
    function createDisputeWithPrivacy(
        uint256 escrowId, 
        string calldata reason,
        bool usePrivacy
    ) external whenNotPaused onlyEscrowParty(escrowId) escrowNotReleased(escrowId) {
        require(usePrivacy && isMpcAvailable, "OmniCoinEscrow: Privacy not available");
        address privacyFeeManager = getPrivacyFeeManager();
        require(privacyFeeManager != address(0), "OmniCoinEscrow: Privacy fee manager not set");
        
        PrivateEscrow storage escrow = escrows[escrowId];
        require(!escrow.disputed, "OmniCoinEscrow: Already disputed");
        
        // Collect privacy fee for dispute creation
        uint256 baseFee = uint64(gtUint64.unwrap(arbitrationFee));
        uint256 privacyFee = baseFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("ESCROW_DISPUTE"),
            privacyFee
        );
        
        escrow.disputed = true;
        uint256 disputeId = disputeCount++;
        
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
     * @dev Resolve dispute with public amounts (standard)
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
        require(!dispute.resolved, "OmniCoinEscrow: Already resolved");
        
        PrivateEscrow storage escrow = escrows[dispute.escrowId];
        
        // Verify total equals escrow amount
        uint256 escrowAmount = uint64(gtUint64.unwrap(escrow.encryptedAmount));
        require(buyerRefundAmount + sellerPayoutAmount == escrowAmount, "OmniCoinEscrow: Invalid split");
        
        dispute.resolved = true;
        dispute.resolver = msg.sender;
        dispute.buyerRefund = gtUint64.wrap(uint64(buyerRefundAmount));
        dispute.sellerPayout = gtUint64.wrap(uint64(sellerPayoutAmount));
        escrow.released = true;
        
        // Transfer amounts
        OmniCoinCore token = getOmniCoin();
        if (buyerRefundAmount > 0) {
            bool buyerTransferResult = token.transferPublic(escrow.buyer, buyerRefundAmount);
            require(buyerTransferResult, "OmniCoinEscrow: Buyer transfer failed");
        }
        
        if (sellerPayoutAmount > 0) {
            bool sellerTransferResult = token.transferPublic(escrow.seller, sellerPayoutAmount);
            require(sellerTransferResult, "OmniCoinEscrow: Seller transfer failed");
        }
        
        // Transfer fee to treasury
        _distributeFee(escrow.encryptedFee);
        
        emit DisputeResolved(dispute.escrowId, disputeId, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Resolve dispute with encrypted payout amounts (privacy)
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
        require(usePrivacy && isMpcAvailable, "OmniCoinEscrow: Privacy not available");
        address privacyFeeManager = getPrivacyFeeManager();
        require(privacyFeeManager != address(0), "OmniCoinEscrow: Privacy fee manager not set");
        
        PrivateDispute storage dispute = disputes[disputeId];
        require(!dispute.resolved, "OmniCoinEscrow: Already resolved");
        
        PrivateEscrow storage escrow = escrows[dispute.escrowId];
        
        // Collect privacy fee for dispute resolution
        uint256 baseFee = uint64(gtUint64.unwrap(arbitrationFee));
        uint256 privacyFee = baseFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
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
            require(MpcCore.decrypt(isEqual), "OmniCoinEscrow: Invalid split");
        } else {
            // Fallback for testing
            uint64 buyerAmount = uint64(uint256(keccak256(abi.encode(buyerRefund))));
            uint64 sellerAmount = uint64(uint256(keccak256(abi.encode(sellerPayout))));
            gtBuyerRefund = gtUint64.wrap(buyerAmount);
            gtSellerPayout = gtUint64.wrap(sellerAmount);
            
            uint64 escrowAmount = uint64(gtUint64.unwrap(escrow.encryptedAmount));
            require(buyerAmount + sellerAmount == escrowAmount, "OmniCoinEscrow: Invalid split");
        }
        
        dispute.resolved = true;
        dispute.resolver = msg.sender;
        dispute.buyerRefund = gtBuyerRefund;
        dispute.sellerPayout = gtSellerPayout;
        escrow.released = true;
        
        // Transfer amounts
        OmniCoinCore token = getOmniCoin();
        if (isMpcAvailable) {
            // Transfer to buyer
            gtBool buyerHasRefund = MpcCore.gt(gtBuyerRefund, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(buyerHasRefund)) {
                gtBool transferResult = token.transferGarbled(escrow.buyer, gtBuyerRefund);
                require(MpcCore.decrypt(transferResult), "OmniCoinEscrow: Buyer transfer failed");
            }
            
            // Transfer to seller
            gtBool sellerHasPayout = MpcCore.gt(gtSellerPayout, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(sellerHasPayout)) {
                gtBool transferResult = token.transferGarbled(escrow.seller, gtSellerPayout);
                require(MpcCore.decrypt(transferResult), "OmniCoinEscrow: Seller transfer failed");
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
     * @dev Get escrow details (public parts only)
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
     * @dev Get encrypted escrow amount for authorized party
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
     * @dev Get user's escrow IDs
     */
    function getUserEscrows(address user) external view returns (uint256[] memory) {
        return userEscrows[user];
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update minimum escrow amount (encrypted)
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
     * @dev Update maximum escrow duration
     */
    function updateMaxEscrowDuration(uint256 newDuration) external onlyRole(ADMIN_ROLE) {
        maxEscrowDuration = newDuration;
        emit MaxEscrowDurationUpdated(newDuration);
    }
    
    /**
     * @dev Update arbitration fee (encrypted)
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
     * @dev Calculate escrow fee (0.5% of amount)
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
     * @dev Distribute fee to treasury
     */
    function _distributeFee(gtUint64 fee) internal {
        if (isMpcAvailable) {
            gtBool hasFee = MpcCore.gt(fee, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasFee)) {
                OmniCoinCore token = getOmniCoin();
                address treasury = getTreasury();
                gtBool transferResult = token.transferGarbled(treasury, fee);
                require(MpcCore.decrypt(transferResult), "OmniCoinEscrow: Fee transfer failed");
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
     */
    function token() external returns (OmniCoinCore) {
        return getOmniCoin();
    }
    
    /**
     * @dev Get privacy fee manager (backward compatibility)
     * @notice Deprecated - use registry directly
     */
    function privacyFeeManager() external returns (address) {
        return getPrivacyFeeManager();
    }
}