// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MpcCore, gtBool, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinBridge
 * @author OmniCoin Development Team
 * @notice Cross-chain bridge for OmniCoin with privacy features
 * @dev Enables transfers between COTI V2 and other chains with MPC privacy
 */
contract OmniCoinBridge is RegistryAware, Ownable, ReentrancyGuard {
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct BridgeConfig {
        uint256 chainId;    // 32 bytes
        address token;      // 20 bytes  
        bool isActive;      // 1 byte
        // 11 bytes padding
        uint256 minAmount;  // 32 bytes
        uint256 maxAmount;  // 32 bytes
        uint256 fee;        // 32 bytes
    }

    struct Transfer {
        uint256 id;                 // 32 bytes
        address sender;             // 20 bytes
        bool completed;             // 1 byte
        bool refunded;              // 1 byte  
        bool isPrivate;             // 1 byte
        // 9 bytes padding
        uint256 sourceChainId;      // 32 bytes
        uint256 targetChainId;      // 32 bytes
        address targetToken;        // 20 bytes
        address recipient;          // 20 bytes (40 bytes total, 24 bytes padding)
        uint256 amount;             // 32 bytes
        uint256 fee;                // 32 bytes
        uint256 timestamp;          // 32 bytes - Time tracking required for transfers
        ctUint64 encryptedAmount;   // 32 bytes - For private transfers
        ctUint64 encryptedFee;      // 32 bytes - For private transfers
    }

    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Privacy multiplier for privacy-enabled transfers
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    /// @notice Role identifier for bridge validators
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice OmniCoin token contract (deprecated, use registry)
    IERC20 public token;
    /// @notice Whether to use private token for this transfer
    mapping(uint256 => bool) public transferUsePrivacy;
    /// @notice Privacy fee manager contract address
    address public privacyFeeManager;
    /// @notice MPC availability flag for COTI network
    bool public isMpcAvailable;
    /// @notice Authorized bridge validators
    mapping(address => bool) public validators;
    /// @notice Bridge configurations per chain ID
    mapping(uint256 => BridgeConfig) public bridgeConfigs;
    /// @notice Transfer records by ID
    mapping(uint256 => Transfer) public transfers;
    /// @notice Processed message hashes to prevent replay
    mapping(bytes32 => bool) public processedMessages;

    /// @notice Total number of transfers initiated
    uint256 public transferCount;
    /// @notice Minimum allowed transfer amount
    uint256 public minTransferAmount;
    /// @notice Maximum allowed transfer amount
    uint256 public maxTransferAmount;
    /// @notice Base fee for transfers
    uint256 public baseFee;
    /// @notice Message validity timeout
    uint256 public messageTimeout;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a bridge configuration is set or updated
     * @param chainId Target chain ID
     * @param token Token address on target chain
     * @param minAmount Minimum transfer amount
     * @param maxAmount Maximum transfer amount
     * @param fee Transfer fee
     */
    event BridgeConfigured(
        uint256 indexed chainId,
        address indexed token,
        uint256 indexed minAmount,
        uint256 maxAmount,
        uint256 fee
    );
    /**
     * @notice Emitted when a cross-chain transfer is initiated
     * @param transferId Unique transfer identifier
     * @param sender Address initiating the transfer
     * @param sourceChainId Source chain ID
     * @param targetChainId Target chain ID
     * @param targetToken Token address on target chain
     * @param recipient Recipient address on target chain
     * @param amount Transfer amount
     * @param fee Transfer fee
     */
    event TransferInitiated(
        uint256 indexed transferId,
        address indexed sender,
        uint256 indexed sourceChainId,
        uint256 targetChainId,
        address targetToken,
        address recipient,
        uint256 amount,
        uint256 fee
    );
    /**
     * @notice Emitted when a transfer is completed on target chain
     * @param transferId Unique transfer identifier
     * @param recipient Recipient address
     * @param amount Transfer amount
     */
    event TransferCompleted(
        uint256 indexed transferId,
        address indexed recipient,
        uint256 indexed amount
    );
    /**
     * @notice Emitted when a transfer is refunded
     * @param transferId Unique transfer identifier
     * @param sender Original sender address
     * @param amount Refunded amount
     * @param fee Refunded fee
     */
    event TransferRefunded(
        uint256 indexed transferId,
        address indexed sender,
        uint256 indexed amount,
        uint256 fee
    );
    /**
     * @notice Emitted when minimum transfer amount is updated
     * @param newAmount New minimum amount
     */
    event MinTransferAmountUpdated(uint256 indexed newAmount);
    /**
     * @notice Emitted when maximum transfer amount is updated
     * @param newAmount New maximum amount
     */
    event MaxTransferAmountUpdated(uint256 indexed newAmount);
    /**
     * @notice Emitted when base fee is updated
     * @param newFee New base fee
     */
    event BaseFeeUpdated(uint256 indexed newFee);
    /**
     * @notice Emitted when message timeout is updated
     * @param newTimeout New timeout value
     */
    event MessageTimeoutUpdated(uint256 indexed newTimeout);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidToken();
    error InvalidAmount();
    error TransferTooSmall();
    error TransferTooLarge();
    error BridgeNotActive();
    error TransferNotFound();
    error TransferAlreadyCompleted();
    error TransferAlreadyRefunded();
    error UnauthorizedValidator();
    error InsufficientFee();
    error MessageAlreadyProcessed();
    error InvalidChainId();
    error InvalidRecipient();
    error MessageTimeout();
    error TransferFailed();

    /**
     * @notice Initialize the OmniCoinBridge contract
     * @param _registry Registry contract address
     * @param _token OmniCoin token address (deprecated, use registry)
     * @param initialOwner Initial owner address
     * @param _privacyFeeManager Privacy fee manager address
     */
    constructor(
        address _registry,
        address _token, 
        address initialOwner,
        address _privacyFeeManager
    ) RegistryAware(_registry) Ownable(initialOwner) {
        token = IERC20(_token);
        privacyFeeManager = _privacyFeeManager;
        minTransferAmount = 100 * 10 ** 6; // 100 tokens
        maxTransferAmount = 1_000_000 * 10 ** 6; // 1M tokens
        baseFee = 1 * 10 ** 6; // 1 token
        messageTimeout = 1 hours;
        isMpcAvailable = false; // Default to false, set by admin when on COTI
    }
    
    /**
     * @notice Set MPC availability status
     * @param _available Whether MPC is available (true on COTI network)
     */
    function setMpcAvailability(bool _available) external onlyOwner {
        isMpcAvailable = _available;
    }
    
    /**
     * @notice Set the privacy fee manager contract address
     * @param _privacyFeeManager Address of privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyOwner {
        if (_privacyFeeManager == address(0)) revert InvalidToken();
        privacyFeeManager = _privacyFeeManager;
    }

    /**
     * @notice Configure or update bridge settings for a target chain
     * @param _chainId Target chain ID
     * @param _token Token address on target chain
     * @param _minAmount Minimum transfer amount
     * @param _maxAmount Maximum transfer amount
     * @param _fee Transfer fee for this chain
     */
    function configureBridge(
        uint256 _chainId,
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _fee
    ) external onlyOwner {
        if (_token == address(0)) revert InvalidToken();
        if (_minAmount == 0) revert InvalidAmount();
        if (_maxAmount < _minAmount + 1) revert InvalidAmount();
        if (_fee < baseFee) revert InsufficientFee();

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
     * @notice Initiate a public cross-chain transfer
     * @dev Validates bridge configuration and executes token transfer with fees
     * @param _targetChainId Target blockchain ID
     * @param _targetToken Token address on target chain
     * @param _recipient Recipient address on target chain
     * @param _amount Amount to transfer
     */
    function initiateTransfer(
        uint256 _targetChainId,
        address _targetToken,
        address _recipient,
        uint256 _amount
    ) external nonReentrant {
        BridgeConfig storage config = _validateTransferRequest(_targetChainId, _amount);
        
        uint256 transferId = ++transferCount;
        uint256 fee = config.fee;

        _createPublicTransfer(
            transferId,
            _targetChainId,
            _targetToken,
            _recipient,
            _amount,
            fee
        );

        _executePublicTokenTransfer(_amount, fee);

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
     * @notice Initiate a private cross-chain transfer with MPC privacy
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
        _validatePrivacyTransferPreconditions(usePrivacy, _targetChainId);
        
        gtUint64 gtAmount = _validatePrivateAmount(_amount, _targetChainId);
        
        uint256 transferId = ++transferCount;
        
        _processPrivacyFee(gtAmount);
        
        (, ctUint64 encryptedFee) = _createPrivateTransferData(
            transferId,
            _targetChainId,
            _targetToken,
            _recipient,
            gtAmount
        );
        
        _executePrivateTokenTransfer(transferId, gtAmount, encryptedFee);
        
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

    /**
     * @notice Complete a cross-chain transfer on target chain
     * @param _transferId Transfer ID to complete
     * @param _message Validator message
     * @param _signature Validator signature
     */
    function completeTransfer(
        uint256 _transferId,
        bytes calldata _message,
        bytes calldata _signature
    ) external nonReentrant {
        Transfer storage transfer = _validateTransferCompletion(_transferId);
        
        bytes32 messageHash = _generateMessageHash(_transferId, transfer, _message);
        _verifyMessageAndSignature(messageHash, _signature);
        
        transfer.completed = true;
        processedMessages[messageHash] = true;
        
        _executeTransferToRecipient(_transferId, transfer);
        
        emit TransferCompleted(
            _transferId,
            transfer.recipient,
            transfer.amount
        );
    }

    /**
     * @notice Refund a failed or expired transfer
     * @param _transferId Transfer ID to refund
     */
    function refundTransfer(uint256 _transferId) external nonReentrant {
        Transfer storage transfer = _validateRefundEligibility(_transferId);
        
        transfer.refunded = true;
        
        _executeRefundToSender(_transferId, transfer);
        
        emit TransferRefunded(
            _transferId,
            transfer.sender,
            transfer.amount,
            transfer.fee
        );
    }

    /**
     * @notice Set minimum transfer amount
     * @param _amount New minimum amount
     */
    function setMinTransferAmount(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert InvalidAmount();
        minTransferAmount = _amount;
        emit MinTransferAmountUpdated(_amount);
    }

    /**
     * @notice Set maximum transfer amount
     * @param _amount New maximum amount
     */
    function setMaxTransferAmount(uint256 _amount) external onlyOwner {
        if (_amount < minTransferAmount || _amount == minTransferAmount) revert InvalidAmount();
        maxTransferAmount = _amount;
        emit MaxTransferAmountUpdated(_amount);
    }

    /**
     * @notice Set base transfer fee
     * @param _fee New base fee
     */
    function setBaseFee(uint256 _fee) external onlyOwner {
        if (_fee == 0) revert InsufficientFee();
        baseFee = _fee;
        emit BaseFeeUpdated(_fee);
    }

    /**
     * @notice Set message validity timeout
     * @param _timeout New timeout duration
     */
    function setMessageTimeout(uint256 _timeout) external onlyOwner {
        if (_timeout < 1) revert MessageTimeout();
        messageTimeout = _timeout;
        emit MessageTimeoutUpdated(_timeout);
    }
    
    /**
     * @notice Add a new validator
     * @param _validator Validator address to add
     */
    function addValidator(address _validator) external onlyOwner {
        if (_validator == address(0)) revert InvalidToken();
        validators[_validator] = true;
    }
    
    /**
     * @notice Remove a validator
     * @param _validator Validator address to remove
     */
    function removeValidator(address _validator) external onlyOwner {
        validators[_validator] = false;
    }

    /**
     * @notice Get transfer details
     * @param _transferId Transfer ID to query
     * @return sender Original sender address
     * @return sourceChainId Source chain ID
     * @return targetChainId Target chain ID
     * @return targetToken Token address on target chain
     * @return recipient Recipient address
     * @return amount Transfer amount (0 if private)
     * @return fee Transfer fee (0 if private)
     * @return timestamp Transfer timestamp
     * @return completed Whether transfer is completed
     * @return refunded Whether transfer is refunded
     * @return isPrivate Whether transfer uses privacy
     */
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
     * @notice Get encrypted transfer amounts (restricted access)
     * @param _transferId Transfer ID to query
     * @return encryptedAmount Encrypted transfer amount
     * @return encryptedFee Encrypted transfer fee
     */
    function getPrivateTransferAmounts(
        uint256 _transferId
    ) external view returns (ctUint64 encryptedAmount, ctUint64 encryptedFee) {
        Transfer storage transfer = transfers[_transferId];
        if (!transfer.isPrivate) revert TransferNotFound();
        if (msg.sender != transfer.sender && 
            msg.sender != transfer.recipient && 
            msg.sender != owner()) {
            revert UnauthorizedValidator();
        }
        return (transfer.encryptedAmount, transfer.encryptedFee);
    }

    /**
     * @notice Get bridge configuration for a chain
     * @param _chainId Chain ID to query
     * @return tokenAddress Token address on target chain
     * @return isActive Whether bridge is active
     * @return minAmount Minimum transfer amount
     * @return maxAmount Maximum transfer amount
     * @return fee Transfer fee
     */
    function getBridgeConfig(
        uint256 _chainId
    )
        external
        view
        returns (
            address tokenAddress,
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
    
    /**
     * @notice Check if an address is a validator
     * @param _address Address to check
     * @return bool Whether address is a validator
     */
    function isValidator(address _address) external view returns (bool) {
        return validators[_address];
    }

    /**
     * @notice Validate privacy transfer preconditions
     * @dev Internal function to validate MPC availability and bridge config
     * @param usePrivacy Whether privacy features are requested
     * @param _targetChainId Target chain ID to validate
     */
    function _validatePrivacyTransferPreconditions(
        bool usePrivacy,
        uint256 _targetChainId
    ) internal view {
        if (!usePrivacy || !isMpcAvailable) revert BridgeNotActive();
        if (privacyFeeManager == address(0)) revert InvalidToken();
        
        BridgeConfig storage config = bridgeConfigs[_targetChainId];
        if (!config.isActive) revert BridgeNotActive();
    }
    
    /**
     * @notice Validate encrypted amount for privacy transfer
     * @dev Internal function to validate and decrypt amount bounds
     * @param _amount Encrypted amount to validate
     * @param _targetChainId Target chain ID for config lookup
     * @return gtAmount Validated encrypted amount
     */
    function _validatePrivateAmount(
        itUint64 calldata _amount,
        uint256 _targetChainId
    ) internal view returns (gtUint64 gtAmount) {
        BridgeConfig storage config = bridgeConfigs[_targetChainId];
        
        gtAmount = MpcCore.validateCiphertext(_amount);
        
        gtUint64 gtMinAmount = MpcCore.setPublic64(uint64(config.minAmount));
        gtUint64 gtMaxAmount = MpcCore.setPublic64(uint64(config.maxAmount));
        gtBool isAboveMin = MpcCore.ge(gtAmount, gtMinAmount);
        gtBool isBelowMax = MpcCore.le(gtAmount, gtMaxAmount);
        if (!MpcCore.decrypt(isAboveMin)) revert TransferTooSmall();
        if (!MpcCore.decrypt(isBelowMax)) revert TransferTooLarge();
    }
    
    /**
     * @notice Process privacy fee collection
     * @dev Internal function to calculate and collect privacy fees
     * @param gtAmount Encrypted transfer amount
     */
    function _processPrivacyFee(gtUint64 gtAmount) internal {
        uint256 bridgeFeeRate = 50; // 0.5% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(bridgeFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 privacyFeeBase = MpcCore.mul(gtAmount, feeRate);
        privacyFeeBase = MpcCore.div(privacyFeeBase, basisPointsGt);
        
        uint256 normalFee = uint64(gtUint64.unwrap(privacyFeeBase));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
            msg.sender,
            keccak256("BRIDGE_TRANSFER"),
            privacyFee
        );
    }
    
    /**
     * @notice Create private transfer data structure
     * @dev Internal function to create encrypted transfer record
     * @param transferId Unique transfer identifier
     * @param _targetChainId Target chain ID
     * @param _targetToken Token address on target chain
     * @param _recipient Recipient address
     * @param gtAmount Encrypted transfer amount
     * @return encryptedAmount Encrypted amount for storage
     * @return encryptedFee Encrypted fee for storage
     */
    function _createPrivateTransferData(
        uint256 transferId,
        uint256 _targetChainId,
        address _targetToken,
        address _recipient,
        gtUint64 gtAmount
    ) internal returns (ctUint64 encryptedAmount, ctUint64 encryptedFee) {
        BridgeConfig storage config = bridgeConfigs[_targetChainId];
        
        gtUint64 gtBridgeFee = MpcCore.setPublic64(uint64(config.fee));
        encryptedFee = MpcCore.offBoard(gtBridgeFee);
        encryptedAmount = MpcCore.offBoard(gtAmount);
        
        transfers[transferId] = Transfer({
            id: transferId,
            sender: msg.sender,
            sourceChainId: block.chainid,
            targetChainId: _targetChainId,
            targetToken: _targetToken,
            recipient: _recipient,
            amount: 0, // Use encrypted version
            fee: 0, // Use encrypted version
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            completed: false,
            refunded: false,
            isPrivate: true,
            encryptedAmount: encryptedAmount,
            encryptedFee: encryptedFee
        });
    }
    
    /**
     * @notice Execute private token transfer
     * @dev Internal function to handle private token transfers
     * @param transferId Transfer identifier
     * @param gtAmount Encrypted amount
     * @param encryptedFee Encrypted fee
     */
    function _executePrivateTokenTransfer(
        uint256 transferId,
        gtUint64 gtAmount,
        ctUint64 encryptedFee
    ) internal {
        address privateToken = registry.getContract(keccak256("PRIVATE_OMNICOIN"));
        if (privateToken != address(0)) {
            gtUint64 gtFee = MpcCore.onBoard(encryptedFee);
            gtUint64 gtTotal = MpcCore.add(gtAmount, gtFee);
            uint256 totalAmount = uint64(gtUint64.unwrap(gtTotal));
            
            if (!IERC20(privateToken).transferFrom(msg.sender, address(this), totalAmount)) {
                revert TransferFailed();
            }
            
            transferUsePrivacy[transferId] = true;
        } else {
            revert InvalidToken();
        }
    }
    
    /**
     * @notice Validate transfer request parameters
     * @dev Internal function to validate bridge config and amount limits
     * @param _targetChainId Target chain ID to validate
     * @param _amount Transfer amount to validate
     * @return config Bridge configuration for the target chain
     */
    function _validateTransferRequest(
        uint256 _targetChainId,
        uint256 _amount
    ) internal view returns (BridgeConfig storage config) {
        config = bridgeConfigs[_targetChainId];
        if (!config.isActive) revert BridgeNotActive();
        if (_amount < config.minAmount) revert TransferTooSmall();
        if (_amount > config.maxAmount) revert TransferTooLarge();
    }
    
    /**
     * @notice Create public transfer record
     * @dev Internal function to create transfer struct for public transfers
     * @param transferId Unique transfer identifier
     * @param _targetChainId Target chain ID
     * @param _targetToken Token address on target chain
     * @param _recipient Recipient address
     * @param _amount Transfer amount
     * @param fee Transfer fee
     */
    function _createPublicTransfer(
        uint256 transferId,
        uint256 _targetChainId,
        address _targetToken,
        address _recipient,
        uint256 _amount,
        uint256 fee
    ) internal {
        transfers[transferId] = Transfer({
            id: transferId,
            sender: msg.sender,
            sourceChainId: block.chainid,
            targetChainId: _targetChainId,
            targetToken: _targetToken,
            recipient: _recipient,
            amount: _amount,
            fee: fee,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            completed: false,
            refunded: false,
            isPrivate: false,
            encryptedAmount: ctUint64.wrap(0),
            encryptedFee: ctUint64.wrap(0)
        });
    }
    
    /**
     * @notice Execute token transfer for public transfers
     * @dev Internal function to handle token transfers using public OmniCoin
     * @param _amount Transfer amount
     * @param fee Transfer fee
     */
    function _executePublicTokenTransfer(uint256 _amount, uint256 fee) internal {
        address publicToken = registry.getContract(keccak256("OMNICOIN"));
        if (publicToken != address(0)) {
            if (!IERC20(publicToken).transferFrom(msg.sender, address(this), _amount + fee)) {
                revert TransferFailed();
            }
        } else if (address(token) != address(0)) {
            // Backwards compatibility
            if (!token.transferFrom(msg.sender, address(this), _amount + fee)) {
                revert TransferFailed();
            }
        } else {
            revert InvalidToken();
        }
    }
    
    /**
     * @notice Validate transfer completion prerequisites
     * @dev Internal function to validate transfer state before completion
     * @param _transferId Transfer ID to validate
     * @return transfer Storage reference to the transfer
     */
    function _validateTransferCompletion(
        uint256 _transferId
    ) internal view returns (Transfer storage transfer) {
        transfer = transfers[_transferId];
        if (transfer.completed) revert TransferAlreadyCompleted();
        if (transfer.refunded) revert TransferAlreadyRefunded();
        // Time-based check for message validity
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > transfer.timestamp + messageTimeout) {
            revert MessageTimeout();
        }
    }
    
    /**
     * @notice Generate message hash for validation
     * @dev Internal function to create consistent message hashes
     * @param _transferId Transfer ID
     * @param transfer Transfer data structure
     * @param _message Validator message
     * @return messageHash Hash of the complete message
     */
    function _generateMessageHash(
        uint256 _transferId,
        Transfer storage transfer,
        bytes calldata _message
    ) internal pure returns (bytes32 messageHash) {
        messageHash = keccak256(
            abi.encodePacked(
                _transferId,
                transfer.sender,
                transfer.sourceChainId,
                transfer.targetChainId,
                transfer.targetToken,
                transfer.recipient,
                transfer.amount,
                transfer.fee,
                _message
            )
        );
    }
    
    /**
     * @notice Verify message hash and signature
     * @dev Internal function to validate message authenticity
     * @param messageHash Hash to verify
     * @param _signature Validator signature
     */
    function _verifyMessageAndSignature(
        bytes32 messageHash,
        bytes calldata _signature
    ) internal view {
        if (processedMessages[messageHash]) revert MessageAlreadyProcessed();
        if (!verifyMessage(messageHash, _signature)) revert UnauthorizedValidator();
    }
    
    /**
     * @notice Execute token transfer to recipient
     * @dev Internal function to handle transfers using appropriate token contract
     * @param _transferId Transfer ID
     * @param transfer Transfer data structure
     */
    function _executeTransferToRecipient(
        uint256 _transferId,
        Transfer storage transfer
    ) internal {
        if (transferUsePrivacy[_transferId]) {
            _executePrivateTransferToRecipient(transfer);
        } else {
            _executePublicTransferToRecipient(transfer);
        }
    }
    
    /**
     * @notice Execute private token transfer to recipient
     * @dev Internal function for privacy-enabled transfers
     * @param transfer Transfer data structure
     */
    function _executePrivateTransferToRecipient(Transfer storage transfer) internal {
        address privateToken = registry.getContract(keccak256("PRIVATE_OMNICOIN"));
        if (privateToken != address(0)) {
            uint256 amount = ctUint64.unwrap(transfer.encryptedAmount);
            if (!IERC20(privateToken).transfer(transfer.recipient, amount)) {
                revert TransferFailed();
            }
        } else {
            revert InvalidToken();
        }
    }
    
    /**
     * @notice Execute public token transfer to recipient
     * @dev Internal function for standard transfers
     * @param transfer Transfer data structure
     */
    function _executePublicTransferToRecipient(Transfer storage transfer) internal {
        address publicToken = registry.getContract(keccak256("OMNICOIN"));
        if (publicToken != address(0)) {
            if (!IERC20(publicToken).transfer(transfer.recipient, transfer.amount)) {
                revert TransferFailed();
            }
        } else if (address(token) != address(0)) {
            // Backwards compatibility
            if (!token.transfer(transfer.recipient, transfer.amount)) {
                revert TransferFailed();
            }
        } else {
            revert InvalidToken();
        }
    }
    
    /**
     * @notice Validate refund eligibility
     * @dev Internal function to check if transfer can be refunded
     * @param _transferId Transfer ID to validate
     * @return transfer Storage reference to the transfer
     */
    function _validateRefundEligibility(
        uint256 _transferId
    ) internal view returns (Transfer storage transfer) {
        transfer = transfers[_transferId];
        if (transfer.completed) revert TransferAlreadyCompleted();
        if (transfer.refunded) revert TransferAlreadyRefunded();
        // Time-based check required for refund eligibility
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < transfer.timestamp + messageTimeout) {
            revert MessageTimeout();
        }
    }
    
    /**
     * @notice Execute refund to original sender
     * @dev Internal function to refund tokens using appropriate contract
     * @param _transferId Transfer ID
     * @param transfer Transfer data structure
     */
    function _executeRefundToSender(
        uint256 _transferId,
        Transfer storage transfer
    ) internal {
        if (transferUsePrivacy[_transferId]) {
            _executePrivateRefund(transfer);
        } else {
            _executePublicRefund(transfer);
        }
    }
    
    /**
     * @notice Execute private refund to sender
     * @dev Internal function for privacy-enabled refunds
     * @param transfer Transfer data structure
     */
    function _executePrivateRefund(Transfer storage transfer) internal {
        address privateToken = registry.getContract(keccak256("PRIVATE_OMNICOIN"));
        if (privateToken != address(0)) {
            uint256 amount = ctUint64.unwrap(transfer.encryptedAmount);
            uint256 fee = ctUint64.unwrap(transfer.encryptedFee);
            if (!IERC20(privateToken).transfer(transfer.sender, amount + fee)) {
                revert TransferFailed();
            }
        } else {
            revert InvalidToken();
        }
    }
    
    /**
     * @notice Execute public refund to sender
     * @dev Internal function for standard refunds
     * @param transfer Transfer data structure
     */
    function _executePublicRefund(Transfer storage transfer) internal {
        address publicToken = registry.getContract(keccak256("OMNICOIN"));
        if (publicToken != address(0)) {
            if (!IERC20(publicToken).transfer(transfer.sender, transfer.amount + transfer.fee)) {
                revert TransferFailed();
            }
        } else if (address(token) != address(0)) {
            // Backwards compatibility
            if (!token.transfer(transfer.sender, transfer.amount + transfer.fee)) {
                revert TransferFailed();
            }
        } else {
            revert InvalidToken();
        }
    }
    
    /**
     * @notice Verify validator signature on message
     * @param _messageHash Hash of the message
     * @param _signature Validator signature
     * @return bool Whether signature is valid
     */
    function verifyMessage(
        bytes32 _messageHash,
        bytes memory _signature
    ) internal view returns (bool) {
        // Verify signature length
        if (_signature.length != 65) {
            return false;
        }
        
        // Extract signature components
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        assembly ("memory-safe") {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }
        
        // Adjust v for Ethereum's ecrecover
        if (v < 27) {
            v += 27;
        }
        
        // Verify the signature is from an authorized validator
        address signer = ecrecover(_messageHash, v, r, s);
        return validators[signer];
    }
}
