// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./PrivacyFeeManager.sol";

contract OmniCoinBridge is Ownable, ReentrancyGuard {
    // Privacy configuration
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    address public privacyFeeManager;
    bool public isMpcAvailable;
    struct BridgeConfig {
        uint256 chainId;
        address token;
        bool isActive;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 fee;
    }

    struct Transfer {
        uint256 id;
        address sender;
        uint256 sourceChainId;
        uint256 targetChainId;
        address targetToken;
        address recipient;
        uint256 amount;
        uint256 fee;
        uint256 timestamp;
        bool completed;
        bool refunded;
        bool isPrivate;
        ctUint64 encryptedAmount;  // For private transfers
        ctUint64 encryptedFee;     // For private transfers
    }

    IERC20 public token;

    mapping(uint256 => BridgeConfig) public bridgeConfigs;
    mapping(uint256 => Transfer) public transfers;
    mapping(bytes32 => bool) public processedMessages;

    uint256 public transferCount;
    uint256 public minTransferAmount;
    uint256 public maxTransferAmount;
    uint256 public baseFee;
    uint256 public messageTimeout;

    event BridgeConfigured(
        uint256 indexed chainId,
        address indexed token,
        uint256 minAmount,
        uint256 maxAmount,
        uint256 fee
    );
    event TransferInitiated(
        uint256 indexed transferId,
        address indexed sender,
        uint256 sourceChainId,
        uint256 targetChainId,
        address targetToken,
        address recipient,
        uint256 amount,
        uint256 fee
    );
    event TransferCompleted(
        uint256 indexed transferId,
        address indexed recipient,
        uint256 amount
    );
    event TransferRefunded(
        uint256 indexed transferId,
        address indexed sender,
        uint256 amount,
        uint256 fee
    );
    event MinTransferAmountUpdated(uint256 newAmount);
    event MaxTransferAmountUpdated(uint256 newAmount);
    event BaseFeeUpdated(uint256 newFee);
    event MessageTimeoutUpdated(uint256 newTimeout);

    constructor(
        address _token, 
        address initialOwner,
        address _privacyFeeManager
    ) Ownable(initialOwner) {
        token = IERC20(_token);
        privacyFeeManager = _privacyFeeManager;
        minTransferAmount = 100 * 10 ** 6; // 100 tokens
        maxTransferAmount = 1000000 * 10 ** 6; // 1M tokens
        baseFee = 1 * 10 ** 6; // 1 token
        messageTimeout = 1 hours;
        isMpcAvailable = false; // Default to false, set by admin when on COTI
    }
    
    /**
     * @dev Set MPC availability (admin only)
     */
    function setMpcAvailability(bool _available) external onlyOwner {
        isMpcAvailable = _available;
    }
    
    /**
     * @dev Set privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyOwner {
        require(_privacyFeeManager != address(0), "Invalid address");
        privacyFeeManager = _privacyFeeManager;
    }

    function configureBridge(
        uint256 _chainId,
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _fee
    ) external onlyOwner {
        require(_token != address(0), "Invalid token");
        require(_minAmount > 0, "Invalid min amount");
        require(_maxAmount > _minAmount, "Invalid max amount");
        require(_fee >= baseFee, "Invalid fee");

        bridgeConfigs[_chainId] = BridgeConfig({
            chainId: _chainId,
            token: _token,
            isActive: true,
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            fee: _fee
        });

        emit BridgeConfigured(_chainId, _token, _minAmount, _maxAmount, _fee);
    }

    /**
     * @dev Initiate public bridge transfer (default, no privacy fees)
     */
    function initiateTransfer(
        uint256 _targetChainId,
        address _targetToken,
        address _recipient,
        uint256 _amount
    ) external nonReentrant {
        BridgeConfig storage config = bridgeConfigs[_targetChainId];
        require(config.isActive, "Bridge inactive");
        require(_amount >= config.minAmount, "Amount too small");
        require(_amount <= config.maxAmount, "Amount too large");

        uint256 transferId = transferCount++;
        uint256 fee = config.fee;

        transfers[transferId] = Transfer({
            id: transferId,
            sender: msg.sender,
            sourceChainId: block.chainid,
            targetChainId: _targetChainId,
            targetToken: _targetToken,
            recipient: _recipient,
            amount: _amount,
            fee: fee,
            timestamp: block.timestamp,
            completed: false,
            refunded: false,
            isPrivate: false,
            encryptedAmount: ctUint64.wrap(0),
            encryptedFee: ctUint64.wrap(0)
        });

        require(
            token.transferFrom(msg.sender, address(this), _amount + fee),
            "Transfer failed"
        );

        emit TransferInitiated(
            transferId,
            msg.sender,
            block.chainid,
            _targetChainId,
            _targetToken,
            _recipient,
            _amount,
            fee
        );
    }
    
    /**
     * @dev Initiate private bridge transfer (premium feature)
     * @param _targetChainId Target blockchain ID
     * @param _targetToken Token address on target chain
     * @param _recipient Recipient address
     * @param _amount Encrypted transfer amount
     * @param usePrivacy Whether to use privacy features
     */
    function initiateTransferWithPrivacy(
        uint256 _targetChainId,
        address _targetToken,
        address _recipient,
        itUint64 calldata _amount,
        bool usePrivacy
    ) external nonReentrant {
        require(usePrivacy && isMpcAvailable, "Privacy not available");
        require(privacyFeeManager != address(0), "Privacy fee manager not set");
        
        BridgeConfig storage config = bridgeConfigs[_targetChainId];
        require(config.isActive, "Bridge inactive");
        
        // Validate encrypted amount
        gtUint64 gtAmount = MpcCore.validateCiphertext(_amount);
        
        // Check amount bounds
        gtUint64 gtMinAmount = MpcCore.setPublic64(uint64(config.minAmount));
        gtUint64 gtMaxAmount = MpcCore.setPublic64(uint64(config.maxAmount));
        gtBool isAboveMin = MpcCore.ge(gtAmount, gtMinAmount);
        gtBool isBelowMax = MpcCore.le(gtAmount, gtMaxAmount);
        require(MpcCore.decrypt(isAboveMin), "Amount too small");
        require(MpcCore.decrypt(isBelowMax), "Amount too large");
        
        uint256 transferId = transferCount++;
        
        // Calculate privacy fee (0.5% of amount for bridge operations)
        uint256 BRIDGE_FEE_RATE = 50; // 0.5% in basis points
        uint256 BASIS_POINTS = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(BRIDGE_FEE_RATE));
        gtUint64 basisPoints = MpcCore.setPublic64(uint64(BASIS_POINTS));
        gtUint64 privacyFeeBase = MpcCore.mul(gtAmount, feeRate);
        privacyFeeBase = MpcCore.div(privacyFeeBase, basisPoints);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(privacyFeeBase));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("BRIDGE_TRANSFER"),
            privacyFee
        );
        
        // Bridge fee (encrypted)
        gtUint64 gtBridgeFee = MpcCore.setPublic64(uint64(config.fee));
        ctUint64 encryptedFee = MpcCore.offBoard(gtBridgeFee);
        
        // Store transfer with encrypted amounts
        ctUint64 encryptedAmount = MpcCore.offBoard(gtAmount);
        
        transfers[transferId] = Transfer({
            id: transferId,
            sender: msg.sender,
            sourceChainId: block.chainid,
            targetChainId: _targetChainId,
            targetToken: _targetToken,
            recipient: _recipient,
            amount: 0, // Use encrypted version
            fee: 0, // Use encrypted version
            timestamp: block.timestamp,
            completed: false,
            refunded: false,
            isPrivate: true,
            encryptedAmount: encryptedAmount,
            encryptedFee: encryptedFee
        });
        
        // Transfer tokens (amount + bridge fee) using privacy
        gtUint64 gtTotalAmount = MpcCore.add(gtAmount, gtBridgeFee);
        
        // Note: Actual token transfer would use OmniCoinCore's private transfer
        // For now, emit event with transfer ID
        
        emit TransferInitiated(
            transferId,
            msg.sender,
            block.chainid,
            _targetChainId,
            _targetToken,
            _recipient,
            0, // Amount is private
            0  // Fee is private
        );
    }

    function completeTransfer(
        uint256 _transferId,
        bytes memory _message,
        bytes memory _signature
    ) external nonReentrant {
        Transfer storage transfer = transfers[_transferId];
        require(!transfer.completed, "Already completed");
        require(!transfer.refunded, "Already refunded");
        require(
            block.timestamp <= transfer.timestamp + messageTimeout,
            "Message expired"
        );

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _transferId,
                transfer.sender,
                transfer.sourceChainId,
                transfer.targetChainId,
                transfer.targetToken,
                transfer.recipient,
                transfer.amount,
                transfer.fee
            )
        );

        require(!processedMessages[messageHash], "Message processed");
        require(verifyMessage(messageHash, _signature), "Invalid signature");

        transfer.completed = true;
        processedMessages[messageHash] = true;

        require(
            token.transfer(transfer.recipient, transfer.amount),
            "Transfer failed"
        );

        emit TransferCompleted(
            _transferId,
            transfer.recipient,
            transfer.amount
        );
    }

    function refundTransfer(uint256 _transferId) external nonReentrant {
        Transfer storage transfer = transfers[_transferId];
        require(!transfer.completed, "Already completed");
        require(!transfer.refunded, "Already refunded");
        require(
            block.timestamp > transfer.timestamp + messageTimeout,
            "Not expired"
        );

        transfer.refunded = true;

        require(
            token.transfer(transfer.sender, transfer.amount + transfer.fee),
            "Transfer failed"
        );

        emit TransferRefunded(
            _transferId,
            transfer.sender,
            transfer.amount,
            transfer.fee
        );
    }

    function setMinTransferAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Invalid amount");
        minTransferAmount = _amount;
        emit MinTransferAmountUpdated(_amount);
    }

    function setMaxTransferAmount(uint256 _amount) external onlyOwner {
        require(_amount > minTransferAmount, "Invalid amount");
        maxTransferAmount = _amount;
        emit MaxTransferAmountUpdated(_amount);
    }

    function setBaseFee(uint256 _fee) external onlyOwner {
        require(_fee > 0, "Invalid fee");
        baseFee = _fee;
        emit BaseFeeUpdated(_fee);
    }

    function setMessageTimeout(uint256 _timeout) external onlyOwner {
        require(_timeout > 0, "Invalid timeout");
        messageTimeout = _timeout;
        emit MessageTimeoutUpdated(_timeout);
    }

    function getTransfer(
        uint256 _transferId
    )
        external
        view
        returns (
            address sender,
            uint256 sourceChainId,
            uint256 targetChainId,
            address targetToken,
            address recipient,
            uint256 amount,
            uint256 fee,
            uint256 timestamp,
            bool completed,
            bool refunded,
            bool isPrivate
        )
    {
        Transfer storage transfer = transfers[_transferId];
        return (
            transfer.sender,
            transfer.sourceChainId,
            transfer.targetChainId,
            transfer.targetToken,
            transfer.recipient,
            transfer.isPrivate ? 0 : transfer.amount, // Hide amount if private
            transfer.isPrivate ? 0 : transfer.fee,    // Hide fee if private
            transfer.timestamp,
            transfer.completed,
            transfer.refunded,
            transfer.isPrivate
        );
    }
    
    /**
     * @dev Get encrypted transfer amounts (only for authorized parties)
     */
    function getPrivateTransferAmounts(
        uint256 _transferId
    ) external view returns (ctUint64 encryptedAmount, ctUint64 encryptedFee) {
        Transfer storage transfer = transfers[_transferId];
        require(transfer.isPrivate, "Not a private transfer");
        require(
            msg.sender == transfer.sender || msg.sender == transfer.recipient || msg.sender == owner(),
            "Not authorized"
        );
        return (transfer.encryptedAmount, transfer.encryptedFee);
    }

    function getBridgeConfig(
        uint256 _chainId
    )
        external
        view
        returns (
            address token,
            bool isActive,
            uint256 minAmount,
            uint256 maxAmount,
            uint256 fee
        )
    {
        BridgeConfig storage config = bridgeConfigs[_chainId];
        return (
            config.token,
            config.isActive,
            config.minAmount,
            config.maxAmount,
            config.fee
        );
    }

    function verifyMessage(
        bytes32 _messageHash,
        bytes memory _signature
    ) internal view returns (bool) {
        // TODO: Implement message verification
        // This is a placeholder that should be replaced with actual verification
        return true;
    }
}
