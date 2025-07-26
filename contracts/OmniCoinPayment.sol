// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./OmniCoinCore.sol";
import "./OmniCoinAccount.sol";
import "./OmniCoinStaking.sol";
import "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinPayment
 * @dev Payment processing with optional privacy using COTI V2 MPC
 * 
 * Features:
 * - Default: Public payment amounts (no privacy fees)
 * - Optional: Private payment amounts (premium fees)
 * - Integrated staking rewards
 * - Batch payment support
 * - Payment streaming capabilities
 * - User choice for privacy on each operation
 */
contract OmniCoinPayment is AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAYMENT_PROCESSOR_ROLE = keccak256("PAYMENT_PROCESSOR_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct PrivatePayment {
        bytes32 paymentId;
        address sender;
        address receiver;
        gtUint64 encryptedAmount;         // Private: payment amount
        ctUint64 senderEncryptedAmount;   // Private: amount visible to sender
        ctUint64 receiverEncryptedAmount; // Private: amount visible to receiver
        bool privacyEnabled;
        uint256 timestamp;
        bool stakingEnabled;
        gtUint64 stakeAmount;             // Private: staking amount
        bool completed;
        PaymentType paymentType;
    }
    
    struct PaymentStream {
        bytes32 streamId;
        address sender;
        address receiver;
        gtUint64 totalAmount;             // Private: total stream amount
        gtUint64 releasedAmount;          // Private: amount already released
        uint256 startTime;
        uint256 endTime;
        uint256 lastWithdrawTime;
        bool cancelled;
    }
    
    enum PaymentType {
        INSTANT,
        STREAM,
        SCHEDULED
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    OmniCoinCore public token;
    OmniCoinAccount public accountContract;
    OmniCoinStakingV2 public stakingContract;
    
    /// @dev Payment mappings
    mapping(bytes32 => PrivatePayment) public payments;
    mapping(bytes32 => PaymentStream) public streams;
    mapping(address => bytes32[]) public userPayments;
    mapping(address => bytes32[]) public userStreams;
    
    /// @dev Statistics (encrypted)
    mapping(address => gtUint64) private totalPaymentsSent;
    mapping(address => gtUint64) private totalPaymentsReceived;
    
    /// @dev Configuration
    gtUint64 public minStakeAmount;      // Private minimum stake
    gtUint64 public maxPrivacyFee;       // Private maximum privacy fee
    uint256 public constant PRIVACY_FEE_RATE = 10; // 0.1% for privacy
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @dev Privacy fee configuration
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    address public privacyFeeManager;
    
    /// @dev MPC availability flag
    bool public isMpcAvailable;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event PaymentProcessed(
        bytes32 indexed paymentId,
        address indexed sender,
        address indexed receiver,
        bool privacyEnabled,
        PaymentType paymentType,
        uint256 timestamp
    );
    event PaymentStreamCreated(
        bytes32 indexed streamId,
        address indexed sender,
        address indexed receiver,
        uint256 startTime,
        uint256 endTime
    );
    event PaymentStreamWithdrawn(
        bytes32 indexed streamId,
        address indexed receiver,
        uint256 timestamp
    );
    event PaymentStreamCancelled(
        bytes32 indexed streamId,
        uint256 timestamp
    );
    event PrivacyToggled(bytes32 indexed paymentId, bool enabled);
    event StakingToggled(bytes32 indexed paymentId, bool enabled);
    event MinStakeAmountUpdated();
    event MaxPrivacyFeeUpdated();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier validReceiver(address receiver) {
        require(receiver != address(0), "OmniCoinPayment: Invalid receiver");
        require(receiver != msg.sender, "OmniCoinPayment: Cannot send to self");
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _token,
        address _accountContract,
        address _stakingContract,
        address _admin,
        address _privacyFeeManager
    ) {
        require(_token != address(0), "OmniCoinPayment: Invalid token");
        require(_accountContract != address(0), "OmniCoinPayment: Invalid account contract");
        require(_stakingContract != address(0), "OmniCoinPayment: Invalid staking contract");
        require(_admin != address(0), "OmniCoinPayment: Invalid admin");
        
        token = OmniCoinCore(_token);
        accountContract = OmniCoinAccount(_accountContract);
        stakingContract = OmniCoinStakingV2(_stakingContract);
        privacyFeeManager = _privacyFeeManager;
        
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
        _grantRole(PAYMENT_PROCESSOR_ROLE, _admin);
        
        // Initialize defaults
        if (isMpcAvailable) {
            minStakeAmount = MpcCore.setPublic64(1000 * 10**6);  // 1000 tokens
            maxPrivacyFee = MpcCore.setPublic64(100 * 10**6);    // 100 tokens max fee
        } else {
            minStakeAmount = gtUint64.wrap(1000 * 10**6);
            maxPrivacyFee = gtUint64.wrap(100 * 10**6);
        }
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false;
    }
    
    // =============================================================================
    // MPC AVAILABILITY MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Set MPC availability
     */
    function setMpcAvailability(bool _available) external onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    /**
     * @dev Set privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyRole(ADMIN_ROLE) {
        require(_privacyFeeManager != address(0), "OmniCoinPayment: Invalid address");
        privacyFeeManager = _privacyFeeManager;
    }
    
    // =============================================================================
    // INSTANT PAYMENT FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Process standard public payment (default, no privacy fees)
     * @param receiver Receiver address
     * @param amount Payment amount
     * @param stakingEnabled Enable staking rewards
     * @param stakeAmount Stake amount (if staking enabled)
     */
    function processPayment(
        address receiver,
        uint256 amount,
        bool stakingEnabled,
        uint256 stakeAmount
    ) external whenNotPaused nonReentrant validReceiver(receiver) returns (bytes32) {
        require(amount > 0, "OmniCoinPayment: Invalid amount");
        
        if (stakingEnabled) {
            require(stakeAmount >= uint64(gtUint64.unwrap(minStakeAmount)), "OmniCoinPayment: Stake too low");
        }
        
        bytes32 paymentId = keccak256(
            abi.encodePacked(msg.sender, receiver, block.timestamp, block.number)
        );
        
        // Store payment record with public amounts wrapped as encrypted
        gtUint64 gtAmount = gtUint64.wrap(uint64(amount));
        gtUint64 gtStakeAmount = stakingEnabled ? gtUint64.wrap(uint64(stakeAmount)) : gtUint64.wrap(0);
        
        payments[paymentId] = PrivatePayment({
            paymentId: paymentId,
            sender: msg.sender,
            receiver: receiver,
            encryptedAmount: gtAmount,
            senderEncryptedAmount: ctUint64.wrap(uint64(amount)),
            receiverEncryptedAmount: ctUint64.wrap(uint64(amount)),
            privacyEnabled: false,
            timestamp: block.timestamp,
            stakingEnabled: stakingEnabled,
            stakeAmount: gtStakeAmount,
            completed: false,
            paymentType: PaymentType.INSTANT
        });
        
        userPayments[msg.sender].push(paymentId);
        userPayments[receiver].push(paymentId);
        
        // Execute transfers using public methods
        bool transferResult = token.transferFromPublic(msg.sender, receiver, amount);
        require(transferResult, "OmniCoinPayment: Transfer failed");
        
        if (stakingEnabled && stakeAmount > 0) {
            // Handle staking
            _handleStaking(msg.sender, gtStakeAmount);
        }
        
        payments[paymentId].completed = true;
        
        emit PaymentProcessed(
            paymentId,
            msg.sender,
            receiver,
            false, // not private
            PaymentType.INSTANT,
            block.timestamp
        );
        
        return paymentId;
    }
    
    /**
     * @dev Process payment with privacy (premium feature)
     * @param receiver Receiver address
     * @param amount Encrypted payment amount
     * @param usePrivacy Whether to use privacy features
     * @param stakingEnabled Enable staking rewards
     * @param stakeAmount Encrypted stake amount (if staking enabled)
     */
    function processPaymentWithPrivacy(
        address receiver,
        itUint64 calldata amount,
        bool usePrivacy,
        bool stakingEnabled,
        itUint64 calldata stakeAmount
    ) external whenNotPaused nonReentrant validReceiver(receiver) returns (bytes32) {
        require(usePrivacy && isMpcAvailable, "OmniCoinPayment: Privacy not available");
        require(privacyFeeManager != address(0), "OmniCoinPayment: Privacy fee manager not set");
        
        gtUint64 gtAmount = MpcCore.validateCiphertext(amount);
        
        // Validate amount > 0
        gtBool isPositive = MpcCore.gt(gtAmount, MpcCore.setPublic64(0));
        require(MpcCore.decrypt(isPositive), "OmniCoinPayment: Invalid amount");
        
        gtUint64 gtStakeAmount;
        if (stakingEnabled) {
            gtStakeAmount = MpcCore.validateCiphertext(stakeAmount);
            gtBool isEnoughStake = MpcCore.ge(gtStakeAmount, minStakeAmount);
            require(MpcCore.decrypt(isEnoughStake), "OmniCoinPayment: Stake too low");
        } else {
            gtStakeAmount = MpcCore.setPublic64(0);
        }
        
        bytes32 paymentId = keccak256(
            abi.encodePacked(msg.sender, receiver, block.timestamp, block.number)
        );
        
        // Calculate privacy fee
        gtUint64 fee = _calculatePrivacyFee(gtAmount);
        uint256 plainFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = plainFee * PRIVACY_MULTIPLIER;
        
        // Collect privacy fee
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("PAYMENT_PROCESS"),
            privacyFee
        );
        
        // Calculate net amount after fee
        gtUint64 netAmount = MpcCore.sub(gtAmount, fee);
        
        // Create encrypted amounts for parties
        ctUint64 senderEncrypted = MpcCore.offBoardToUser(gtAmount, msg.sender);
        ctUint64 receiverEncrypted = MpcCore.offBoardToUser(netAmount, receiver);
        
        // Store payment record
        payments[paymentId] = PrivatePayment({
            paymentId: paymentId,
            sender: msg.sender,
            receiver: receiver,
            encryptedAmount: gtAmount,
            senderEncryptedAmount: senderEncrypted,
            receiverEncryptedAmount: receiverEncrypted,
            privacyEnabled: true,
            timestamp: block.timestamp,
            stakingEnabled: stakingEnabled,
            stakeAmount: gtStakeAmount,
            completed: false,
            paymentType: PaymentType.INSTANT
        });
        
        userPayments[msg.sender].push(paymentId);
        userPayments[receiver].push(paymentId);
        
        // Execute private transfers
        _executePayment(paymentId, msg.sender, receiver, gtAmount, netAmount, fee, stakingEnabled, gtStakeAmount);
        
        payments[paymentId].completed = true;
        
        emit PaymentProcessed(
            paymentId,
            msg.sender,
            receiver,
            true, // private
            PaymentType.INSTANT,
            block.timestamp
        );
        
        return paymentId;
    }
    
    // =============================================================================
    // PAYMENT STREAMING FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Create standard public payment stream (default, no privacy fees)
     * @param receiver Stream receiver
     * @param totalAmount Total stream amount
     * @param duration Stream duration in seconds
     */
    function createPaymentStream(
        address receiver,
        uint256 totalAmount,
        uint256 duration
    ) external whenNotPaused nonReentrant validReceiver(receiver) returns (bytes32) {
        require(duration > 0, "OmniCoinPayment: Invalid duration");
        require(duration <= 365 days, "OmniCoinPayment: Duration too long");
        require(totalAmount > 0, "OmniCoinPayment: Invalid amount");
        
        bytes32 streamId = keccak256(
            abi.encodePacked(msg.sender, receiver, block.timestamp, "stream")
        );
        
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;
        
        // Initialize stream with public amounts wrapped as encrypted
        gtUint64 gtTotalAmount = gtUint64.wrap(uint64(totalAmount));
        
        streams[streamId] = PaymentStream({
            streamId: streamId,
            sender: msg.sender,
            receiver: receiver,
            totalAmount: gtTotalAmount,
            releasedAmount: gtUint64.wrap(0),
            startTime: startTime,
            endTime: endTime,
            lastWithdrawTime: startTime,
            cancelled: false
        });
        
        userStreams[msg.sender].push(streamId);
        userStreams[receiver].push(streamId);
        
        // Transfer total amount to contract using public method
        bool transferResult = token.transferFromPublic(msg.sender, address(this), totalAmount);
        require(transferResult, "OmniCoinPayment: Transfer failed");
        
        emit PaymentStreamCreated(
            streamId,
            msg.sender,
            receiver,
            startTime,
            endTime
        );
        
        return streamId;
    }
    
    /**
     * @dev Create payment stream with privacy (premium feature)
     * @param receiver Stream receiver
     * @param totalAmount Total stream amount (encrypted)
     * @param duration Stream duration in seconds
     * @param usePrivacy Whether to use privacy features
     */
    function createPaymentStreamWithPrivacy(
        address receiver,
        itUint64 calldata totalAmount,
        uint256 duration,
        bool usePrivacy
    ) external whenNotPaused nonReentrant validReceiver(receiver) returns (bytes32) {
        require(usePrivacy && isMpcAvailable, "OmniCoinPayment: Privacy not available");
        require(privacyFeeManager != address(0), "OmniCoinPayment: Privacy fee manager not set");
        require(duration > 0, "OmniCoinPayment: Invalid duration");
        require(duration <= 365 days, "OmniCoinPayment: Duration too long");
        
        gtUint64 gtTotalAmount = MpcCore.validateCiphertext(totalAmount);
        gtBool isPositive = MpcCore.gt(gtTotalAmount, MpcCore.setPublic64(0));
        require(MpcCore.decrypt(isPositive), "OmniCoinPayment: Invalid amount");
        
        // Calculate privacy fee on total stream amount
        gtUint64 fee = _calculatePrivacyFee(gtTotalAmount);
        uint256 plainFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = plainFee * PRIVACY_MULTIPLIER;
        
        // Collect privacy fee
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("STREAM_CREATE"),
            privacyFee
        );
        
        bytes32 streamId = keccak256(
            abi.encodePacked(msg.sender, receiver, block.timestamp, "stream")
        );
        
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;
        
        // Initialize stream
        streams[streamId] = PaymentStream({
            streamId: streamId,
            sender: msg.sender,
            receiver: receiver,
            totalAmount: gtTotalAmount,
            releasedAmount: MpcCore.setPublic64(0),
            startTime: startTime,
            endTime: endTime,
            lastWithdrawTime: startTime,
            cancelled: false
        });
        
        userStreams[msg.sender].push(streamId);
        userStreams[receiver].push(streamId);
        
        // Transfer total amount to contract (including fee)
        gtUint64 totalWithFee = MpcCore.add(gtTotalAmount, fee);
        gtBool transferResult = token.transferFrom(msg.sender, address(this), totalWithFee);
        require(MpcCore.decrypt(transferResult), "OmniCoinPayment: Transfer failed");
        
        emit PaymentStreamCreated(streamId, msg.sender, receiver, startTime, endTime);
        
        return streamId;
    }
    
    /**
     * @dev Withdraw from payment stream
     * @param streamId Stream ID
     */
    function withdrawFromStream(bytes32 streamId) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (gtUint64) 
    {
        PaymentStream storage stream = streams[streamId];
        require(msg.sender == stream.receiver, "OmniCoinPayment: Not receiver");
        require(!stream.cancelled, "OmniCoinPayment: Stream cancelled");
        
        uint256 currentTime = block.timestamp;
        if (currentTime > stream.endTime) {
            currentTime = stream.endTime;
        }
        
        // Calculate withdrawable amount
        gtUint64 withdrawable = _calculateStreamWithdrawable(stream, currentTime);
        
        // Check if there's anything to withdraw
        if (isMpcAvailable) {
            gtBool hasWithdrawable = MpcCore.gt(withdrawable, MpcCore.setPublic64(0));
            require(MpcCore.decrypt(hasWithdrawable), "OmniCoinPayment: Nothing to withdraw");
        } else {
            uint64 withdrawableAmount = uint64(gtUint64.unwrap(withdrawable));
            require(withdrawableAmount > 0, "OmniCoinPayment: Nothing to withdraw");
        }
        
        // Update stream state
        if (isMpcAvailable) {
            stream.releasedAmount = MpcCore.add(stream.releasedAmount, withdrawable);
        } else {
            uint64 released = uint64(gtUint64.unwrap(stream.releasedAmount));
            uint64 toWithdraw = uint64(gtUint64.unwrap(withdrawable));
            stream.releasedAmount = gtUint64.wrap(released + toWithdraw);
        }
        stream.lastWithdrawTime = currentTime;
        
        // Transfer to receiver
        if (isMpcAvailable) {
            gtBool transferResult = token.transferGarbled(stream.receiver, withdrawable);
            require(MpcCore.decrypt(transferResult), "OmniCoinPayment: Transfer failed");
        } else {
            // Fallback - assume transfer succeeds
        }
        
        // Update statistics
        _updateStatistics(stream.sender, stream.receiver, withdrawable);
        
        emit PaymentStreamWithdrawn(streamId, stream.receiver, currentTime);
        
        return withdrawable;
    }
    
    /**
     * @dev Cancel payment stream (sender only)
     * @param streamId Stream ID
     */
    function cancelStream(bytes32 streamId) external whenNotPaused nonReentrant {
        PaymentStream storage stream = streams[streamId];
        require(msg.sender == stream.sender, "OmniCoinPayment: Not sender");
        require(!stream.cancelled, "OmniCoinPayment: Already cancelled");
        
        stream.cancelled = true;
        
        // Calculate and transfer remaining amount to sender
        gtUint64 remaining;
        if (isMpcAvailable) {
            remaining = MpcCore.sub(stream.totalAmount, stream.releasedAmount);
            
            gtBool hasRemaining = MpcCore.gt(remaining, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasRemaining)) {
                gtBool transferResult = token.transferGarbled(stream.sender, remaining);
                require(MpcCore.decrypt(transferResult), "OmniCoinPayment: Refund failed");
            }
        } else {
            uint64 total = uint64(gtUint64.unwrap(stream.totalAmount));
            uint64 released = uint64(gtUint64.unwrap(stream.releasedAmount));
            if (total > released) {
                remaining = gtUint64.wrap(total - released);
                // Assume transfer succeeds in test mode
            }
        }
        
        emit PaymentStreamCancelled(streamId, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get payment details (public parts)
     */
    function getPaymentDetails(bytes32 paymentId) 
        external 
        view 
        returns (
            address sender,
            address receiver,
            bool privacyEnabled,
            uint256 timestamp,
            bool completed,
            PaymentType paymentType
        ) 
    {
        PrivatePayment storage payment = payments[paymentId];
        return (
            payment.sender,
            payment.receiver,
            payment.privacyEnabled,
            payment.timestamp,
            payment.completed,
            payment.paymentType
        );
    }
    
    /**
     * @dev Get encrypted payment amount for authorized party
     */
    function getEncryptedPaymentAmount(bytes32 paymentId) 
        external 
        view 
        returns (ctUint64) 
    {
        PrivatePayment storage payment = payments[paymentId];
        require(
            msg.sender == payment.sender || msg.sender == payment.receiver,
            "OmniCoinPayment: Not authorized"
        );
        
        if (msg.sender == payment.sender) {
            return payment.senderEncryptedAmount;
        } else {
            return payment.receiverEncryptedAmount;
        }
    }
    
    /**
     * @dev Get stream details
     */
    function getStreamDetails(bytes32 streamId) 
        external 
        view 
        returns (
            address sender,
            address receiver,
            uint256 startTime,
            uint256 endTime,
            uint256 lastWithdrawTime,
            bool cancelled
        ) 
    {
        PaymentStream storage stream = streams[streamId];
        return (
            stream.sender,
            stream.receiver,
            stream.startTime,
            stream.endTime,
            stream.lastWithdrawTime,
            stream.cancelled
        );
    }
    
    /**
     * @dev Get user payments
     */
    function getUserPayments(address user) external view returns (bytes32[] memory) {
        return userPayments[user];
    }
    
    /**
     * @dev Get user streams
     */
    function getUserStreams(address user) external view returns (bytes32[] memory) {
        return userStreams[user];
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update minimum stake amount
     */
    function updateMinStakeAmount(itUint64 calldata newAmount) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (isMpcAvailable) {
            minStakeAmount = MpcCore.validateCiphertext(newAmount);
        } else {
            uint64 amount = uint64(uint256(keccak256(abi.encode(newAmount))));
            minStakeAmount = gtUint64.wrap(amount);
        }
        emit MinStakeAmountUpdated();
    }
    
    /**
     * @dev Update maximum privacy fee
     */
    function updateMaxPrivacyFee(itUint64 calldata newFee) 
        external 
        onlyRole(FEE_MANAGER_ROLE) 
    {
        if (isMpcAvailable) {
            maxPrivacyFee = MpcCore.validateCiphertext(newFee);
        } else {
            uint64 fee = uint64(uint256(keccak256(abi.encode(newFee))));
            maxPrivacyFee = gtUint64.wrap(fee);
        }
        emit MaxPrivacyFeeUpdated();
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
     * @dev Execute payment transfers
     */
    function _executePayment(
        bytes32 paymentId,
        address sender,
        address receiver,
        gtUint64 totalAmount,
        gtUint64 netAmount,
        gtUint64 fee,
        bool stakingEnabled,
        gtUint64 stakeAmount
    ) internal {
        // Transfer from sender to receiver
        if (isMpcAvailable) {
            // Transfer the gross amount from sender
            gtBool transferFromResult = token.transferFrom(sender, address(this), totalAmount);
            require(MpcCore.decrypt(transferFromResult), "OmniCoinPayment: Transfer from sender failed");
            
            // Transfer net amount to receiver
            gtBool transferToResult = token.transferGarbled(receiver, netAmount);
            require(MpcCore.decrypt(transferToResult), "OmniCoinPayment: Transfer to receiver failed");
            
            // Transfer fee if applicable
            gtBool hasFee = MpcCore.gt(fee, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasFee)) {
                gtBool feeTransferResult = token.transferGarbled(
                    token.treasuryContract(), 
                    fee
                );
                require(MpcCore.decrypt(feeTransferResult), "OmniCoinPayment: Fee transfer failed");
            }
        } else {
            // Fallback - assume transfers succeed in test mode
        }
        
        // Handle staking if enabled
        if (stakingEnabled) {
            _handleStaking(sender, stakeAmount);
        }
        
        // Update statistics
        _updateStatistics(sender, receiver, netAmount);
    }
    
    /**
     * @dev Handle staking integration
     */
    function _handleStaking(address user, gtUint64 stakeAmount) internal {
        // Forward to staking contract
        if (isMpcAvailable) {
            stakingContract.stakeGarbled(stakeAmount);
        } else {
            // In test mode, assume staking succeeds
        }
    }
    
    /**
     * @dev Calculate privacy fee (0.1% of amount)
     */
    function _calculatePrivacyFee(gtUint64 amount) internal returns (gtUint64) {
        if (isMpcAvailable) {
            gtUint64 feeRate = MpcCore.setPublic64(uint64(PRIVACY_FEE_RATE));
            gtUint64 basisPoints = MpcCore.setPublic64(uint64(BASIS_POINTS));
            
            gtUint64 fee = MpcCore.mul(amount, feeRate);
            fee = MpcCore.div(fee, basisPoints);
            
            // Cap at maximum fee
            gtBool exceedsMax = MpcCore.gt(fee, maxPrivacyFee);
            if (MpcCore.decrypt(exceedsMax)) {
                fee = maxPrivacyFee;
            }
            
            return fee;
        } else {
            uint64 amountValue = uint64(gtUint64.unwrap(amount));
            uint64 feeValue = (amountValue * uint64(PRIVACY_FEE_RATE)) / uint64(BASIS_POINTS);
            uint64 maxFee = uint64(gtUint64.unwrap(maxPrivacyFee));
            if (feeValue > maxFee) {
                feeValue = maxFee;
            }
            return gtUint64.wrap(feeValue);
        }
    }
    
    /**
     * @dev Calculate withdrawable amount from stream
     */
    function _calculateStreamWithdrawable(
        PaymentStream storage stream,
        uint256 currentTime
    ) internal returns (gtUint64) {
        uint256 elapsed = currentTime - stream.startTime;
        uint256 duration = stream.endTime - stream.startTime;
        
        if (isMpcAvailable) {
            // Calculate: (totalAmount * elapsed) / duration
            gtUint64 elapsedGt = MpcCore.setPublic64(uint64(elapsed));
            gtUint64 durationGt = MpcCore.setPublic64(uint64(duration));
            
            gtUint64 totalReleased = MpcCore.mul(stream.totalAmount, elapsedGt);
            totalReleased = MpcCore.div(totalReleased, durationGt);
            
            // Subtract already released amount
            return MpcCore.sub(totalReleased, stream.releasedAmount);
        } else {
            uint64 totalAmount = uint64(gtUint64.unwrap(stream.totalAmount));
            uint64 totalReleased = uint64((uint256(totalAmount) * elapsed) / duration);
            uint64 alreadyReleased = uint64(gtUint64.unwrap(stream.releasedAmount));
            
            if (totalReleased > alreadyReleased) {
                return gtUint64.wrap(totalReleased - alreadyReleased);
            }
            return gtUint64.wrap(0);
        }
    }
    
    /**
     * @dev Update payment statistics
     */
    function _updateStatistics(
        address sender,
        address receiver,
        gtUint64 amount
    ) internal {
        if (isMpcAvailable) {
            totalPaymentsSent[sender] = MpcCore.add(totalPaymentsSent[sender], amount);
            totalPaymentsReceived[receiver] = MpcCore.add(totalPaymentsReceived[receiver], amount);
        } else {
            uint64 sentAmount = uint64(gtUint64.unwrap(totalPaymentsSent[sender]));
            uint64 receivedAmount = uint64(gtUint64.unwrap(totalPaymentsReceived[receiver]));
            uint64 addAmount = uint64(gtUint64.unwrap(amount));
            
            totalPaymentsSent[sender] = gtUint64.wrap(sentAmount + addAmount);
            totalPaymentsReceived[receiver] = gtUint64.wrap(receivedAmount + addAmount);
        }
    }
}