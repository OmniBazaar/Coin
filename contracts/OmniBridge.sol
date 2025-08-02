// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OmniCore} from "./OmniCore.sol";

/**
 * @notice Warp message structure
 * @dev Matches Avalanche Warp precompile format
 */
struct WarpMessage {
    bytes32 sourceChainID;
    address originSenderAddress;
    bytes payload;
}

/**
 * @notice Warp block hash structure
 */
struct WarpBlockHash {
    bytes32 sourceChainID;
    bytes32 blockHash;
}

/**
 * @title IWarpMessenger
 * @author OmniCoin Development Team
 * @notice Interface for Avalanche Warp Messenger precompile
 * @dev Located at 0x0200000000000000000000000000000000000005
 */
interface IWarpMessenger {
    /**
     * @notice Emitted when a Warp message is sent
     * @param sender Address sending the message
     * @param messageID Unique message identifier
     * @param message Encoded message data
     */
    event SendWarpMessage(
        address indexed sender,
        bytes32 indexed messageID,
        bytes message
    );

    /**
     * @notice Send a Warp message
     * @param payload Message payload
     * @return messageID Unique message identifier
     */
    function sendWarpMessage(bytes calldata payload) external returns (bytes32 messageID);
    /**
     * @notice Get verified Warp message
     * @param index Message index
     * @return message Verified message data
     * @return valid Whether message is valid
     */
    function getVerifiedWarpMessage(uint32 index) external view returns (WarpMessage memory message, bool valid);
    /**
     * @notice Get verified Warp block hash
     * @param index Block hash index
     * @return warpBlockHash Verified block hash data
     * @return valid Whether block hash is valid
     */
    function getVerifiedWarpBlockHash(uint32 index) external view 
        returns (WarpBlockHash memory warpBlockHash, bool valid);
    /**
     * @notice Get blockchain ID
     * @return blockchainID Current blockchain identifier
     */
    function getBlockchainID() external view returns (bytes32 blockchainID);
}

/**
 * @title OmniBridge
 * @author OmniCoin Development Team
 * @notice Ultra-lean cross-chain bridge leveraging Avalanche Warp Messaging
 * @dev Uses Avalanche Warp Messaging for cross-subnet communication
 * 
 * IMPORTANT: This implementation integrates with Avalanche's native Warp precompile at 0x0200000000000000000000000000000000000005
 * For asset transfers, this should be extended with Teleporter from github.com/ava-labs/icm-contracts
 */
contract OmniBridge is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Type declarations
    /// @notice Bridge transfer information
    struct BridgeTransfer {
        address sender;
        address recipient;
        uint256 amount;
        uint256 sourceChainId;
        uint256 targetChainId;
        bytes32 transferHash;
        uint256 timestamp;
        bool completed;
    }

    /// @notice Chain configuration
    struct ChainConfig {
        bool isActive;
        uint256 minTransfer;
        uint256 maxTransfer;
        uint256 dailyLimit;
        uint256 transferFee; // basis points
        address teleporterAddress; // Avalanche Teleporter contract
    }

    // Constants
    /// @notice Service identifier for OmniCoin token
    bytes32 public constant OMNICOIN_SERVICE = keccak256("OMNICOIN");
    
    /// @notice Service identifier for Private OmniCoin
    bytes32 public constant PRIVATE_OMNICOIN_SERVICE = keccak256("PRIVATE_OMNICOIN");
    
    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;
    
    /// @notice Maximum transfer fee (5%)
    uint256 public constant MAX_FEE = 500;
    
    /// @notice Warp Messenger precompile address
    IWarpMessenger public constant WARP_MESSENGER = IWarpMessenger(0x0200000000000000000000000000000000000005);

    // State variables
    /// @notice Core contract reference
    OmniCore public immutable CORE;
    
    /// @notice Transfer counter
    uint256 public transferCount;
    
    /// @notice Chain configurations
    mapping(uint256 => ChainConfig) public chainConfigs;
    
    /// @notice Bridge transfers by ID
    mapping(uint256 => BridgeTransfer) public transfers;
    
    /// @notice Daily transfer volume by chain
    mapping(uint256 => mapping(uint256 => uint256)) public dailyVolume;
    
    /// @notice Processed message hashes (prevent replay)
    mapping(bytes32 => bool) public processedMessages;
    
    /// @notice Blockchain ID to chain ID mapping
    mapping(bytes32 => uint256) public blockchainToChainId;
    
    /// @notice Current blockchain ID (cached)
    bytes32 public immutable BLOCKCHAIN_ID;
    
    /// @notice Track which transfers use privacy features
    mapping(uint256 => bool) private transferUsePrivacy;

    // Events
    /// @notice Emitted when transfer is initiated
    /// @param transferId Unique transfer identifier
    /// @param sender Address initiating transfer
    /// @param recipient Recipient on target chain
    /// @param amount Transfer amount
    /// @param targetChainId Target chain ID
    /// @param fee Transfer fee
    event TransferInitiated(
        uint256 indexed transferId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 targetChainId,
        uint256 fee
    );

    /// @notice Emitted when transfer is completed
    /// @param transferId Transfer identifier
    /// @param recipient Recipient address
    /// @param amount Amount received
    event TransferCompleted(
        uint256 indexed transferId,
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when chain config is updated
    /// @param chainId Chain identifier
    /// @param isActive Whether chain is active
    /// @param teleporterAddress Teleporter contract address
    event ChainConfigUpdated(
        uint256 indexed chainId,
        bool isActive,
        address teleporterAddress
    );

    // Custom errors
    error InvalidAmount();
    error ChainNotSupported();
    error TransferLimitExceeded();
    error DailyLimitExceeded();
    error InvalidFee();
    error TransferNotFound();
    error AlreadyProcessed();
    error InvalidRecipient();

    /**
     * @notice Initialize bridge with core contract
     * @param _core OmniCore contract address
     */
    constructor(address _core) {
        CORE = OmniCore(_core);
        BLOCKCHAIN_ID = WARP_MESSENGER.getBlockchainID();
    }

    /**
     * @notice Initiate cross-chain transfer
     * @dev Locks tokens and emits event for validators/relayers
     * @param recipient Recipient address on target chain
     * @param amount Amount to transfer
     * @param targetChainId Target chain ID
     * @param usePrivateToken Whether to use private token
     * @return transferId Unique transfer identifier
     */
    function initiateTransfer(
        address recipient,
        uint256 amount,
        uint256 targetChainId,
        bool usePrivateToken
    ) external nonReentrant returns (uint256 transferId) {
        // Validate inputs
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        
        // Check chain configuration
        ChainConfig memory config = chainConfigs[targetChainId];
        if (!config.isActive) revert ChainNotSupported();
        if (amount < config.minTransfer || amount > config.maxTransfer) {
            revert TransferLimitExceeded();
        }
        
        // Check daily limit
        uint256 today = block.timestamp / 1 days; // solhint-disable-line not-rely-on-time
        uint256 currentVolume = dailyVolume[targetChainId][today];
        if (currentVolume + amount > config.dailyLimit) {
            revert DailyLimitExceeded();
        }
        
        // Calculate fee
        uint256 fee = (amount * config.transferFee) / BASIS_POINTS;
        uint256 netAmount = amount - fee;
        
        // Get token address
        bytes32 tokenService = usePrivateToken ? PRIVATE_OMNICOIN_SERVICE : OMNICOIN_SERVICE;
        address tokenAddress = CORE.getService(tokenService);
        IERC20 token = IERC20(tokenAddress);
        
        // Transfer tokens to bridge
        token.safeTransferFrom(msg.sender, address(this), amount);
        
        // Create transfer record
        transferId = ++transferCount;
        bytes32 transferHash = keccak256(abi.encodePacked(
            transferId,
            msg.sender,
            recipient,
            amount,
            targetChainId,
            block.timestamp // solhint-disable-line not-rely-on-time
        ));
        
        transfers[transferId] = BridgeTransfer({
            sender: msg.sender,
            recipient: recipient,
            amount: netAmount,
            sourceChainId: block.chainid,
            targetChainId: targetChainId,
            transferHash: transferHash,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            completed: false
        });
        
        // Update daily volume
        dailyVolume[targetChainId][today] += amount;
        
        emit TransferInitiated(
            transferId,
            msg.sender,
            recipient,
            netAmount,
            targetChainId,
            fee
        );
        
        // Send Warp message for cross-chain transfer
        _sendWarpTransferMessage(transferId, transfers[transferId]);
    }

    /**
     * @notice Process incoming Warp message
     * @dev Processes cross-chain transfers from Warp messages
     * @param messageIndex Index of Warp message to process
     */
    function processWarpMessage(uint32 messageIndex) external nonReentrant {
        // Get verified Warp message
        (WarpMessage memory message, bool valid) = WARP_MESSENGER.getVerifiedWarpMessage(messageIndex);
        if (!valid) revert InvalidAmount();
        
        // Decode transfer payload
        (
            uint256 transferId,
            address sender,
            address recipient,
            uint256 amount,
            uint256 targetChainId,
            bool usePrivateToken
        ) = abi.decode(message.payload, (uint256, address, address, uint256, uint256, bool));
        
        // Verify this chain is the target
        if (targetChainId != block.chainid) revert InvalidChainId();
        
        // Create message hash for replay protection
        bytes32 messageHash = keccak256(abi.encodePacked(
            message.sourceChainID,
            transferId,
            sender,
            recipient,
            amount
        ));
        
        // Prevent replay
        if (processedMessages[messageHash]) revert AlreadyProcessed();
        processedMessages[messageHash] = true;
        
        // Get source chain ID from blockchain ID
        uint256 sourceChainId = blockchainToChainId[message.sourceChainID];
        if (sourceChainId == 0) revert InvalidChainId();
        
        // Get token address
        bytes32 tokenService = usePrivateToken ? PRIVATE_OMNICOIN_SERVICE : OMNICOIN_SERVICE;
        address tokenAddress = CORE.getService(tokenService);
        IERC20 token = IERC20(tokenAddress);
        
        // Transfer tokens to recipient
        uint256 balance = token.balanceOf(address(this));
        if (balance > amount || balance == amount) {
            token.safeTransfer(recipient, amount);
        } else {
            // If insufficient, would need minting capability
            revert InvalidAmount();
        }
        
        emit TransferCompleted(transferId, recipient, amount);
    }

    /**
     * @notice Update chain configuration
     * @dev Only admin can update
     * @param chainId Chain identifier
     * @param blockchainId Avalanche blockchain ID for this chain
     * @param isActive Whether chain is active
     * @param minTransfer Minimum transfer amount
     * @param maxTransfer Maximum transfer amount
     * @param dailyLimit Daily transfer limit
     * @param transferFee Transfer fee in basis points
     * @param teleporterAddress Teleporter contract address
     */
    function updateChainConfig(
        uint256 chainId,
        bytes32 blockchainId,
        bool isActive,
        uint256 minTransfer,
        uint256 maxTransfer,
        uint256 dailyLimit,
        uint256 transferFee,
        address teleporterAddress
    ) external {
        // Only admin can update
        if (!CORE.hasRole(CORE.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }
        
        if (transferFee > MAX_FEE) revert InvalidFee();
        if (minTransfer >= maxTransfer) revert InvalidAmount();
        
        chainConfigs[chainId] = ChainConfig({
            isActive: isActive,
            minTransfer: minTransfer,
            maxTransfer: maxTransfer,
            dailyLimit: dailyLimit,
            transferFee: transferFee,
            teleporterAddress: teleporterAddress
        });
        
        // Map blockchain ID to chain ID
        if (blockchainId != bytes32(0)) {
            blockchainToChainId[blockchainId] = chainId;
        }
        
        emit ChainConfigUpdated(chainId, isActive, teleporterAddress);
    }

    /**
     * @notice Get transfer details
     * @param transferId Transfer identifier
     * @return Transfer information
     */
    function getTransfer(uint256 transferId) external view returns (BridgeTransfer memory) {
        return transfers[transferId];
    }

    /**
     * @notice Get current daily volume for a chain
     * @param chainId Chain identifier
     * @return volume Current daily volume
     */
    function getCurrentDailyVolume(uint256 chainId) external view returns (uint256 volume) {
        uint256 today = block.timestamp / 1 days; // solhint-disable-line not-rely-on-time
        return dailyVolume[chainId][today];
    }

    /**
     * @notice Emergency token recovery
     * @dev Only admin can recover stuck tokens
     * @param token Token address
     * @param amount Amount to recover
     */
    function recoverTokens(address token, uint256 amount) external {
        if (!CORE.hasRole(CORE.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }
        
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    /**
     * @notice Send Warp message for cross-chain transfer
     * @dev Internal function to emit Warp message
     * @param transferId Transfer identifier
     * @param transfer Transfer details
     */
    function _sendWarpTransferMessage(
        uint256 transferId,
        BridgeTransfer memory transfer
    ) internal {
        // Encode transfer data as Warp message payload
        bytes memory payload = abi.encode(
            transferId,
            transfer.sender,
            transfer.recipient,
            transfer.amount,
            transfer.targetChainId,
            transferUsePrivacy[transferId] // Include privacy flag
        );
        
        // Send Warp message
        bytes32 messageId = WARP_MESSENGER.sendWarpMessage(payload);
        
        // Log for tracking
        emit WarpMessageSent(transferId, messageId, transfer.targetChainId);
    }
    
    /**
     * @notice Get current blockchain ID
     * @return Blockchain ID of current chain
     */
    function getBlockchainID() external view returns (bytes32) {
        return BLOCKCHAIN_ID;
    }
    
    /**
     * @notice Check if message index has been processed
     * @param sourceChainID Source blockchain ID
     * @param transferId Transfer identifier
     * @return Whether message has been processed
     */
    function isMessageProcessed(
        bytes32 sourceChainID,
        uint256 transferId
    ) external view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(
            sourceChainID,
            transferId
        ));
        return processedMessages[messageHash];
    }
    
    /**
     * @notice Emitted when Warp message is sent for transfer
     * @param transferId Transfer identifier
     * @param messageId Warp message ID
     * @param targetChainId Target chain for transfer
     */
    event WarpMessageSent(
        uint256 indexed transferId,
        bytes32 indexed messageId,
        uint256 indexed targetChainId
    );
}