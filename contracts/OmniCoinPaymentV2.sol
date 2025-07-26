// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./OmniCoinCore.sol";
import "./OmniCoinAccount.sol";
import "./OmniCoinStakingV2.sol";

/**
 * @title OmniCoinPaymentV2
 * @dev Privacy-enabled payment processing using COTI V2 MPC
 * 
 * Features:
 * - Private payment amounts
 * - Optional privacy mode per payment
 * - Integrated staking rewards
 * - Batch payment support
 * - Payment streaming capabilities
 */
contract OmniCoinPaymentV2 is AccessControl, ReentrancyGuard, Pausable {
    
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
        require(receiver != address(0), "OmniCoinPaymentV2: Invalid receiver");
        require(receiver != msg.sender, "OmniCoinPaymentV2: Cannot send to self");
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _token,
        address _accountContract,
        address _stakingContract,
        address _admin
    ) {
        require(_token != address(0), "OmniCoinPaymentV2: Invalid token");
        require(_accountContract != address(0), "OmniCoinPaymentV2: Invalid account contract");
        require(_stakingContract != address(0), "OmniCoinPaymentV2: Invalid staking contract");
        require(_admin != address(0), "OmniCoinPaymentV2: Invalid admin");
        
        token = OmniCoinCore(_token);
        accountContract = OmniCoinAccount(_accountContract);
        stakingContract = OmniCoinStakingV2(_stakingContract);
        
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
    
    // =============================================================================
    // INSTANT PAYMENT FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Process private payment
     * @param receiver Receiver address
     * @param amount Encrypted payment amount
     * @param privacyEnabled Enable privacy features
     * @param stakingEnabled Enable staking rewards
     * @param stakeAmount Encrypted stake amount (if staking enabled)
     */
    function processPrivatePayment(
        address receiver,
        itUint64 calldata amount,
        bool privacyEnabled,
        bool stakingEnabled,
        itUint64 calldata stakeAmount
    ) external whenNotPaused nonReentrant validReceiver(receiver) returns (bytes32) {
        gtUint64 gtAmount;
        gtUint64 gtStakeAmount;
        
        if (isMpcAvailable) {
            gtAmount = MpcCore.validateCiphertext(amount);
            
            // Validate amount > 0
            gtBool isPositive = MpcCore.gt(gtAmount, MpcCore.setPublic64(0));
            require(MpcCore.decrypt(isPositive), "OmniCoinPaymentV2: Invalid amount");
            
            if (stakingEnabled) {
                gtStakeAmount = MpcCore.validateCiphertext(stakeAmount);
                gtBool isEnoughStake = MpcCore.ge(gtStakeAmount, minStakeAmount);
                require(MpcCore.decrypt(isEnoughStake), "OmniCoinPaymentV2: Stake too low");
            } else {
                gtStakeAmount = MpcCore.setPublic64(0);
            }
        } else {
            // Fallback for testing
            uint64 plainAmount = uint64(uint256(keccak256(abi.encode(amount))));
            gtAmount = gtUint64.wrap(plainAmount);
            require(plainAmount > 0, "OmniCoinPaymentV2: Invalid amount");
            
            if (stakingEnabled) {
                uint64 plainStake = uint64(uint256(keccak256(abi.encode(stakeAmount))));
                gtStakeAmount = gtUint64.wrap(plainStake);
                uint64 minStake = uint64(gtUint64.unwrap(minStakeAmount));
                require(plainStake >= minStake, "OmniCoinPaymentV2: Stake too low");
            } else {
                gtStakeAmount = gtUint64.wrap(0);
            }
        }
        
        bytes32 paymentId = keccak256(
            abi.encodePacked(msg.sender, receiver, block.timestamp, block.number)
        );
        
        // Calculate privacy fee if enabled
        gtUint64 fee;
        gtUint64 netAmount;
        
        if (privacyEnabled) {
            fee = _calculatePrivacyFee(gtAmount);
            if (isMpcAvailable) {
                netAmount = MpcCore.sub(gtAmount, fee);
            } else {
                uint64 amountValue = uint64(gtUint64.unwrap(gtAmount));
                uint64 feeValue = uint64(gtUint64.unwrap(fee));
                netAmount = gtUint64.wrap(amountValue - feeValue);
            }
        } else {
            fee = isMpcAvailable ? MpcCore.setPublic64(0) : gtUint64.wrap(0);
            netAmount = gtAmount;
        }
        
        // Create encrypted amounts for parties
        ctUint64 senderEncrypted;
        ctUint64 receiverEncrypted;
        
        if (isMpcAvailable) {
            senderEncrypted = MpcCore.offBoardToUser(gtAmount, msg.sender);
            receiverEncrypted = MpcCore.offBoardToUser(netAmount, receiver);
        } else {
            senderEncrypted = ctUint64.wrap(uint64(gtUint64.unwrap(gtAmount)));
            receiverEncrypted = ctUint64.wrap(uint64(gtUint64.unwrap(netAmount)));
        }
        
        // Store payment record
        payments[paymentId] = PrivatePayment({
            paymentId: paymentId,
            sender: msg.sender,
            receiver: receiver,
            encryptedAmount: gtAmount,
            senderEncryptedAmount: senderEncrypted,
            receiverEncryptedAmount: receiverEncrypted,
            privacyEnabled: privacyEnabled,
            timestamp: block.timestamp,
            stakingEnabled: stakingEnabled,
            stakeAmount: gtStakeAmount,
            completed: false,
            paymentType: PaymentType.INSTANT
        });
        
        userPayments[msg.sender].push(paymentId);
        userPayments[receiver].push(paymentId);
        
        // Execute transfers
        _executePayment(paymentId, msg.sender, receiver, gtAmount, netAmount, fee, stakingEnabled, gtStakeAmount);
        
        payments[paymentId].completed = true;
        
        emit PaymentProcessed(
            paymentId,
            msg.sender,
            receiver,
            privacyEnabled,
            PaymentType.INSTANT,
            block.timestamp
        );
        
        return paymentId;
    }
    
    // =============================================================================
    // PAYMENT STREAMING FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Create payment stream
     * @param receiver Stream receiver
     * @param totalAmount Total stream amount (encrypted)
     * @param duration Stream duration in seconds
     */
    function createPaymentStream(
        address receiver,
        itUint64 calldata totalAmount,
        uint256 duration
    ) external whenNotPaused nonReentrant validReceiver(receiver) returns (bytes32) {
        require(duration > 0, "OmniCoinPaymentV2: Invalid duration");
        require(duration <= 365 days, "OmniCoinPaymentV2: Duration too long");
        
        gtUint64 gtTotalAmount;
        
        if (isMpcAvailable) {
            gtTotalAmount = MpcCore.validateCiphertext(totalAmount);
            gtBool isPositive = MpcCore.gt(gtTotalAmount, MpcCore.setPublic64(0));
            require(MpcCore.decrypt(isPositive), "OmniCoinPaymentV2: Invalid amount");
        } else {
            uint64 plainAmount = uint64(uint256(keccak256(abi.encode(totalAmount))));
            gtTotalAmount = gtUint64.wrap(plainAmount);
            require(plainAmount > 0, "OmniCoinPaymentV2: Invalid amount");
        }
        
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
            releasedAmount: isMpcAvailable ? MpcCore.setPublic64(0) : gtUint64.wrap(0),
            startTime: startTime,
            endTime: endTime,
            lastWithdrawTime: startTime,
            cancelled: false
        });
        
        userStreams[msg.sender].push(streamId);
        userStreams[receiver].push(streamId);
        
        // Transfer total amount to contract
        if (isMpcAvailable) {
            // Use transferFrom with proper gtBool return type
            gtBool transferResult = token.transferFrom(msg.sender, address(this), gtTotalAmount);
            require(MpcCore.decrypt(transferResult), "OmniCoinPaymentV2: Transfer failed");
        } else {
            // Fallback - assume transfer succeeds in test mode
        }
        
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
        require(msg.sender == stream.receiver, "OmniCoinPaymentV2: Not receiver");
        require(!stream.cancelled, "OmniCoinPaymentV2: Stream cancelled");
        
        uint256 currentTime = block.timestamp;
        if (currentTime > stream.endTime) {
            currentTime = stream.endTime;
        }
        
        // Calculate withdrawable amount
        gtUint64 withdrawable = _calculateStreamWithdrawable(stream, currentTime);
        
        // Check if there's anything to withdraw
        if (isMpcAvailable) {
            gtBool hasWithdrawable = MpcCore.gt(withdrawable, MpcCore.setPublic64(0));
            require(MpcCore.decrypt(hasWithdrawable), "OmniCoinPaymentV2: Nothing to withdraw");
        } else {
            uint64 withdrawableAmount = uint64(gtUint64.unwrap(withdrawable));
            require(withdrawableAmount > 0, "OmniCoinPaymentV2: Nothing to withdraw");
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
            require(MpcCore.decrypt(transferResult), "OmniCoinPaymentV2: Transfer failed");
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
        require(msg.sender == stream.sender, "OmniCoinPaymentV2: Not sender");
        require(!stream.cancelled, "OmniCoinPaymentV2: Already cancelled");
        
        stream.cancelled = true;
        
        // Calculate and transfer remaining amount to sender
        gtUint64 remaining;
        if (isMpcAvailable) {
            remaining = MpcCore.sub(stream.totalAmount, stream.releasedAmount);
            
            gtBool hasRemaining = MpcCore.gt(remaining, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasRemaining)) {
                gtBool transferResult = token.transferGarbled(stream.sender, remaining);
                require(MpcCore.decrypt(transferResult), "OmniCoinPaymentV2: Refund failed");
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
            "OmniCoinPaymentV2: Not authorized"
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
            require(MpcCore.decrypt(transferFromResult), "OmniCoinPaymentV2: Transfer from sender failed");
            
            // Transfer net amount to receiver
            gtBool transferToResult = token.transferGarbled(receiver, netAmount);
            require(MpcCore.decrypt(transferToResult), "OmniCoinPaymentV2: Transfer to receiver failed");
            
            // Transfer fee if applicable
            gtBool hasFee = MpcCore.gt(fee, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(hasFee)) {
                gtBool feeTransferResult = token.transferGarbled(
                    token.treasuryContract(), 
                    fee
                );
                require(MpcCore.decrypt(feeTransferResult), "OmniCoinPaymentV2: Fee transfer failed");
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