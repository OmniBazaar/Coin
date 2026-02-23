// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
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

/* solhint-disable max-states-count */

/**
 * @title OmniBridge
 * @author OmniCoin Development Team
 * @notice UUPS-upgradeable cross-chain bridge leveraging Avalanche Warp Messaging
 * @dev Uses Avalanche Warp Messaging for cross-subnet communication.
 *      Upgraded to UUPS pattern for post-launch bug fixes and chain additions.
 *
 * IMPORTANT: Integrates with Avalanche Warp precompile at
 * 0x0200000000000000000000000000000000000005.
 * For asset transfers, extend with Teleporter from
 * github.com/ava-labs/icm-contracts.
 *
 * Supports ossification: once ossify() is called through governance,
 * the bridge contract becomes permanently immutable.
 */
contract OmniBridge is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // Type declarations
    /// @notice Bridge transfer information (packed for gas efficiency)
    struct BridgeTransfer {
        address sender;         // slot 1: 20 bytes
        bool completed;         // slot 1: 1 byte (total: 21 bytes)
        address recipient;      // slot 2: 20 bytes
        uint256 amount;         // slot 3: 32 bytes
        uint256 sourceChainId;  // slot 4: 32 bytes
        uint256 targetChainId;  // slot 5: 32 bytes
        bytes32 transferHash;   // slot 6: 32 bytes
        uint256 timestamp;      // slot 7: 32 bytes
    }

    /// @notice Chain configuration
    struct ChainConfig {
        address teleporterAddress;  // slot 1: 20 bytes - Avalanche Teleporter contract
        bool isActive;              // slot 1: 1 byte (total: 21 bytes in slot 1)
        uint256 minTransfer;        // slot 2: 32 bytes
        uint256 maxTransfer;        // slot 3: 32 bytes
        uint256 dailyLimit;         // slot 4: 32 bytes
        uint256 transferFee;        // slot 5: 32 bytes - basis points
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

    /// @notice Minimum delay before a transfer can be refunded (7 days)
    /// @dev Gives sufficient time for cross-chain message delivery and
    ///      validator processing before allowing sender to reclaim funds.
    uint256 public constant REFUND_DELAY = 7 days;

    /// @notice Admin role for upgrade authorization (held by timelock)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Warp Messenger precompile address
    IWarpMessenger public constant WARP_MESSENGER = IWarpMessenger(0x0200000000000000000000000000000000000005);

    // =========================================================================
    // State Variables (STORAGE LAYOUT - DO NOT REORDER!)
    // =========================================================================

    /// @notice Core contract reference
    OmniCore public core;

    /// @notice Current blockchain ID (cached from Warp precompile)
    bytes32 public blockchainId;

    /// @notice Transfer counter
    uint256 public transferCount;

    /// @notice Chain configurations
    mapping(uint256 => ChainConfig) public chainConfigs;

    /// @notice Bridge transfers by ID
    mapping(uint256 => BridgeTransfer) public transfers;

    /// @notice Daily outbound transfer volume by chain (chainId => day => volume)
    mapping(uint256 => mapping(uint256 => uint256)) public dailyVolume;

    /// @notice Daily inbound transfer volume by source chain (chainId => day => volume)
    /// @dev H-04 remediation: independent inbound rate limiting prevents
    ///      asymmetric draining even if source chain enforcement is bypassed.
    mapping(uint256 => mapping(uint256 => uint256)) public dailyInboundVolume;

    /// @notice Processed message hashes (prevent replay)
    mapping(bytes32 => bool) public processedMessages;

    /// @notice Blockchain ID to chain ID mapping
    mapping(bytes32 => uint256) public blockchainToChainId;

    /// @notice Trusted bridge address per source blockchain ID
    mapping(bytes32 => address) public trustedBridges;

    /// @notice Reverse mapping from chain ID to blockchain ID
    /// @dev M-03 remediation: enables cleanup of stale blockchainToChainId
    ///      entries when a chain's blockchain ID is updated.
    mapping(uint256 => bytes32) public chainToBlockchainId;

    /// @notice Accumulated bridge fees per token address
    /// @dev M-01 remediation: tracks fees collected from transfers so they
    ///      can be distributed via distributeFees() rather than being locked.
    mapping(address => uint256) public accumulatedFees;

    // Private state variables
    /// @notice Track which transfers use privacy features
    mapping(uint256 => bool) private transferUsePrivacy;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Storage gap for future upgrades
    uint256[44] private __gap;

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
        uint256 indexed amount
    );

    /// @notice Emitted when chain config is updated
    /// @param chainId Chain identifier
    /// @param isActive Whether chain is active
    /// @param teleporterAddress Teleporter contract address
    event ChainConfigUpdated(
        uint256 indexed chainId,
        bool indexed isActive,
        address indexed teleporterAddress
    );

    /// @notice Emitted when a trusted bridge address is updated
    /// @param blockchainId Source blockchain ID
    /// @param bridgeAddress Trusted bridge contract address on that chain
    event TrustedBridgeUpdated(
        bytes32 indexed blockchainId,
        address indexed bridgeAddress
    );

    /// @notice Emitted when tokens are recovered by admin
    /// @param token Token contract address recovered
    /// @param amount Amount of tokens recovered
    /// @param recipient Address receiving recovered tokens
    event TokensRecovered(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when Warp message is sent for transfer
    /// @param transferId Transfer identifier
    /// @param messageId Warp message ID
    /// @param targetChainId Target chain for transfer
    event WarpMessageSent(
        uint256 indexed transferId,
        bytes32 indexed messageId,
        uint256 indexed targetChainId
    );

    /// @notice Emitted when accumulated bridge fees are distributed
    /// @param token Token address whose fees were distributed
    /// @param amount Total fee amount distributed
    /// @param recipient Address receiving the fees
    event FeeDistributed(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when a transfer is refunded to the original sender
    /// @param transferId Refunded transfer identifier
    /// @param sender Address receiving the refund
    /// @param amount Amount refunded
    event TransferRefunded(
        uint256 indexed transferId,
        address indexed sender,
        uint256 indexed amount
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // Custom errors
    /// @notice Thrown when amount is zero or insufficient balance
    error InvalidAmount();
    /// @notice Thrown when target chain is not configured or inactive
    error ChainNotSupported();
    /// @notice Thrown when transfer amount exceeds min/max limits
    error TransferLimitExceeded();
    /// @notice Thrown when daily volume limit would be exceeded
    error DailyLimitExceeded();
    /// @notice Thrown when transfer fee exceeds maximum allowed
    error InvalidFee();
    /// @notice Thrown when referenced transfer does not exist
    error TransferNotFound();
    /// @notice Thrown when a message has already been processed (replay)
    error AlreadyProcessed();
    /// @notice Thrown when recipient is zero address or caller lacks admin role
    error InvalidRecipient();
    /// @notice Thrown when chain ID does not match expected target
    error InvalidChainId();
    /// @notice Thrown when Warp message origin is not a trusted bridge
    error UnauthorizedSender();
    /// @notice Thrown when trying to recover bridge-locked operational tokens
    error CannotRecoverBridgeTokens();
    /// @notice Thrown when refund is attempted before the refund delay expires
    error TransferTooEarly();
    /// @notice Thrown when transfer has already been completed or refunded
    error TransferAlreadyCompleted();
    /// @notice Thrown when no fees are available to distribute for a token
    error NoFeesToDistribute();
    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /**
     * @notice Disable initializers on implementation contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize bridge with core contract references
     * @dev Can only be called once via proxy deployment
     * @param _core OmniCore contract address
     * @param admin Address to receive initial admin role (timelock)
     */
    function initialize(
        address _core,
        address admin
    ) external initializer {
        if (_core == address(0) || admin == address(0)) {
            revert InvalidRecipient();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        core = OmniCore(_core);
        blockchainId = WARP_MESSENGER.getBlockchainID();
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
    ) external nonReentrant whenNotPaused returns (uint256 transferId) {
        // Validate inputs and chain configuration
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        ChainConfig memory config = _validateChainTransfer(
            targetChainId, amount
        );

        // Calculate fee
        uint256 fee = (amount * config.transferFee) / BASIS_POINTS;
        uint256 netAmount = amount - fee;

        // Get token address and validate service is registered
        address tokenAddress = _resolveToken(usePrivateToken);
        IERC20 token = IERC20(tokenAddress);

        // Transfer tokens to bridge
        token.safeTransferFrom(msg.sender, address(this), amount);

        // M-01: Track accumulated fees for later distribution
        if (fee > 0) {
            accumulatedFees[tokenAddress] += fee;
        }

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
            completed: false,
            recipient: recipient,
            amount: netAmount,
            sourceChainId: block.chainid,
            targetChainId: targetChainId,
            transferHash: transferHash,
            timestamp: block.timestamp // solhint-disable-line not-rely-on-time
        });
        
        // Update daily volume
        // solhint-disable-next-line not-rely-on-time
        dailyVolume[targetChainId][block.timestamp / 1 days] += amount;
        
        emit TransferInitiated(
            transferId,
            msg.sender,
            recipient,
            netAmount,
            targetChainId,
            fee
        );
        
        // Record privacy preference for this transfer (H-01 fix)
        transferUsePrivacy[transferId] = usePrivateToken;

        // Send Warp message for cross-chain transfer
        _sendWarpTransferMessage(transferId, transfers[transferId]);
    }

    /**
     * @notice Process incoming Warp message
     * @dev Processes cross-chain transfers from Warp messages.
     *      Validates origin, checks replay, and releases tokens.
     * @param messageIndex Index of Warp message to process
     */
    function processWarpMessage(
        uint32 messageIndex
    ) external nonReentrant whenNotPaused {
        // Validate and retrieve Warp message
        WarpMessage memory message = _validateWarpMessage(
            messageIndex
        );

        // Decode transfer payload
        (
            uint256 transferId,
            ,
            address recipient,
            uint256 amount,
            uint256 targetChainId,
            bool usePrivateToken
        ) = abi.decode(
                message.payload,
                (uint256, address, address, uint256, uint256, bool)
            );

        // Verify this chain is the target
        if (targetChainId != block.chainid) revert InvalidChainId();

        // H-02: Simplified replay hash (unique per source chain)
        bytes32 messageHash = keccak256(
            abi.encodePacked(message.sourceChainID, transferId)
        );
        if (processedMessages[messageHash]) revert AlreadyProcessed();
        processedMessages[messageHash] = true;

        // H-04: Enforce independent inbound rate limiting
        uint256 sourceChainId = blockchainToChainId[
            message.sourceChainID
        ];
        _enforceInboundLimit(sourceChainId, amount);

        // Release tokens to recipient
        _releaseTokens(recipient, amount, usePrivateToken);

        emit TransferCompleted(transferId, recipient, amount);
    }

    /**
     * @notice Update chain configuration
     * @dev Only admin can update
     * @param chainId Chain identifier
     * @param chainBlockchainId Avalanche blockchain ID for this chain
     * @param isActive Whether chain is active
     * @param minTransfer Minimum transfer amount
     * @param maxTransfer Maximum transfer amount
     * @param dailyLimit Daily transfer limit
     * @param transferFee Transfer fee in basis points
     * @param teleporterAddress Teleporter contract address
     */
    function updateChainConfig(
        uint256 chainId,
        bytes32 chainBlockchainId,
        bool isActive,
        uint256 minTransfer,
        uint256 maxTransfer,
        uint256 dailyLimit,
        uint256 transferFee,
        address teleporterAddress
    ) external {
        // Only admin can update
        if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }

        if (transferFee > MAX_FEE) revert InvalidFee();
        // solhint-disable-next-line gas-strict-inequalities
        if (minTransfer >= maxTransfer) revert InvalidAmount();

        chainConfigs[chainId] = ChainConfig({
            teleporterAddress: teleporterAddress,
            isActive: isActive,
            minTransfer: minTransfer,
            maxTransfer: maxTransfer,
            dailyLimit: dailyLimit,
            transferFee: transferFee
        });

        // M-03: Clear stale blockchain-to-chain mapping before setting new one
        bytes32 oldBlockchainId = chainToBlockchainId[chainId];
        if (oldBlockchainId != bytes32(0)) {
            delete blockchainToChainId[oldBlockchainId];
        }

        // Map blockchain ID to chain ID (bidirectional)
        if (chainBlockchainId != bytes32(0)) {
            blockchainToChainId[chainBlockchainId] = chainId;
            chainToBlockchainId[chainId] = chainBlockchainId;
        } else {
            delete chainToBlockchainId[chainId];
        }

        emit ChainConfigUpdated(chainId, isActive, teleporterAddress);
    }

    /**
     * @notice Emergency token recovery for non-operational tokens
     * @dev Only admin can recover stuck tokens. Bridge-locked XOM and pXOM
     *      cannot be recovered to prevent draining bridge liquidity.
     * @param token Token address to recover
     * @param amount Amount to recover
     */
    function recoverTokens(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }

        // C-02: Prevent draining bridge-locked operational tokens
        address xom = core.getService(OMNICOIN_SERVICE);
        address pxom = core.getService(PRIVATE_OMNICOIN_SERVICE);
        if (token == xom || token == pxom) {
            revert CannotRecoverBridgeTokens();
        }

        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokensRecovered(token, amount, msg.sender);
    }

    /**
     * @notice Distribute accumulated bridge fees to admin for 70/20/10 split
     * @dev M-01 remediation: fees are tracked separately from bridge liquidity
     *      and can be withdrawn without affecting locked user funds. The admin
     *      (expected to be a TimelockController or multi-sig) distributes per
     *      the OmniBazaar 70/20/10 fee structure off-chain or via a fee router.
     * @param token Token address to distribute fees for
     */
    function distributeFees(
        address token
    ) external nonReentrant {
        if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }

        uint256 fees = accumulatedFees[token];
        if (fees == 0) revert NoFeesToDistribute();

        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(msg.sender, fees);
        emit FeeDistributed(token, fees, msg.sender);
    }

    /**
     * @notice Refund a transfer that was not completed within the refund delay
     * @dev M-02 remediation: prevents permanent fund lock when the destination
     *      chain is unreachable or the Warp message fails to process. Only the
     *      original sender can claim the refund after REFUND_DELAY has elapsed.
     *      The refunded amount is the net amount (after fees were deducted).
     * @param transferId Transfer identifier to refund
     */
    function refundTransfer(
        uint256 transferId
    ) external nonReentrant whenNotPaused {
        BridgeTransfer storage t = transfers[transferId];

        if (t.sender != msg.sender) revert InvalidRecipient();
        if (t.completed) revert TransferAlreadyCompleted();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < t.timestamp + REFUND_DELAY) {
            revert TransferTooEarly();
        }

        t.completed = true;

        // Resolve token and refund the net amount
        bytes32 tokenService = transferUsePrivacy[transferId]
            ? PRIVATE_OMNICOIN_SERVICE
            : OMNICOIN_SERVICE;
        address tokenAddress = core.getService(tokenService);
        if (tokenAddress == address(0)) revert InvalidAmount();

        IERC20(tokenAddress).safeTransfer(t.sender, t.amount);
        emit TransferRefunded(transferId, t.sender, t.amount);
    }

    /**
     * @notice Set trusted bridge address for a source chain
     * @dev Only admin can set trusted bridges. Required for C-01 origin
     *      sender validation in processWarpMessage.
     * @param srcBlockchainId Source blockchain ID (Avalanche Warp chain ID)
     * @param bridgeAddress Trusted bridge contract address on that chain
     */
    function setTrustedBridge(
        bytes32 srcBlockchainId,
        address bridgeAddress
    ) external {
        if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }
        trustedBridges[srcBlockchainId] = bridgeAddress;
        emit TrustedBridgeUpdated(srcBlockchainId, bridgeAddress);
    }

    /**
     * @notice Pause all bridge operations
     * @dev Only admin can pause. Halts initiateTransfer and processWarpMessage.
     */
    function pause() external {
        if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }
        _pause();
    }

    /**
     * @notice Unpause bridge operations
     * @dev Only admin can unpause. Resumes initiateTransfer and processWarpMessage.
     */
    function unpause() external {
        if (!core.hasRole(core.ADMIN_ROLE(), msg.sender)) {
            revert InvalidRecipient();
        }
        _unpause();
    }

    // =========================================================================
    // Upgrade & Ossification
    // =========================================================================

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Get transfer details
     * @param transferId Transfer identifier
     * @return Transfer information
     */
    function getTransfer(
        uint256 transferId
    ) external view returns (BridgeTransfer memory) {
        return transfers[transferId];
    }

    /**
     * @notice Get current daily volume for a chain
     * @param chainId Chain identifier
     * @return volume Current daily volume
     */
    function getCurrentDailyVolume(
        uint256 chainId
    ) external view returns (uint256 volume) {
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        return dailyVolume[chainId][today];
    }

    /**
     * @notice Get current blockchain ID
     * @return Blockchain ID of current chain
     */
    function getBlockchainID() external view returns (bytes32) {
        return blockchainId;
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
        bytes32 messageHash = keccak256(
            abi.encodePacked(sourceChainID, transferId)
        );
        return processedMessages[messageHash];
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
        emit WarpMessageSent(
            transferId, messageId, transfer.targetChainId
        );
    }

    /**
     * @notice Enforce inbound daily volume limit for a source chain
     * @dev H-04 remediation: prevents asymmetric draining by independently
     *      rate-limiting inbound transfers on the destination side, even if
     *      the source chain's outbound limit enforcement is bypassed.
     * @param sourceChainId Source chain ID (mapped from Warp blockchain ID)
     * @param amount Transfer amount to check against the daily limit
     */
    function _enforceInboundLimit(
        uint256 sourceChainId,
        uint256 amount
    ) internal {
        ChainConfig memory config = chainConfigs[sourceChainId];
        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        uint256 currentInbound = dailyInboundVolume[sourceChainId][
            today
        ];
        if (currentInbound + amount > config.dailyLimit) {
            revert DailyLimitExceeded();
        }
        dailyInboundVolume[sourceChainId][today] =
            currentInbound + amount;
    }

    /**
     * @notice Release tokens to a recipient from bridge reserves
     * @dev Resolves the token service, validates address, checks balance,
     *      and transfers. Reverts if bridge has insufficient liquidity.
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to release
     * @param usePrivateToken Whether to use pXOM instead of XOM
     */
    function _releaseTokens(
        address recipient,
        uint256 amount,
        bool usePrivateToken
    ) internal {
        bytes32 tokenService = usePrivateToken
            ? PRIVATE_OMNICOIN_SERVICE
            : OMNICOIN_SERVICE;
        address tokenAddress = core.getService(tokenService);
        if (tokenAddress == address(0)) revert InvalidAmount();

        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert InvalidAmount();
        token.safeTransfer(recipient, amount);
    }

    /**
     * @notice Validate a Warp message: verify signature and trusted origin
     * @dev Checks Warp precompile validity and trusted bridge registry.
     *      Also verifies the source blockchain ID maps to a known chain.
     * @param messageIndex Index of Warp message to validate
     * @return message The validated WarpMessage struct
     */
    function _validateWarpMessage(
        uint32 messageIndex
    ) internal view returns (WarpMessage memory message) {
        bool valid;
        (message, valid) = WARP_MESSENGER.getVerifiedWarpMessage(
            messageIndex
        );
        if (!valid) revert InvalidAmount();

        // C-01: Validate origin is a trusted bridge on source chain
        address trusted = trustedBridges[message.sourceChainID];
        if (
            trusted == address(0) ||
            message.originSenderAddress != trusted
        ) {
            revert UnauthorizedSender();
        }

        // Verify source chain is registered
        if (blockchainToChainId[message.sourceChainID] == 0) {
            revert InvalidChainId();
        }
    }

    /**
     * @notice Authorize UUPS upgrades (admin only, respects ossification)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyRole(ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        (newImplementation);
    }

    /**
     * @notice Validate chain configuration and daily limits for a transfer
     * @dev Extracted from initiateTransfer to reduce cyclomatic complexity.
     *      Checks that the target chain is active, amount is within min/max
     *      bounds, and the daily outbound volume limit is not exceeded.
     * @param targetChainId Target chain identifier
     * @param amount Transfer amount to validate
     * @return config The validated chain configuration
     */
    function _validateChainTransfer(
        uint256 targetChainId,
        uint256 amount
    ) private view returns (ChainConfig memory config) {
        config = chainConfigs[targetChainId];
        if (!config.isActive) revert ChainNotSupported();
        if (amount < config.minTransfer || amount > config.maxTransfer) {
            revert TransferLimitExceeded();
        }

        // solhint-disable-next-line not-rely-on-time
        uint256 today = block.timestamp / 1 days;
        uint256 currentVolume = dailyVolume[targetChainId][today];
        if (currentVolume + amount > config.dailyLimit) {
            revert DailyLimitExceeded();
        }
    }

    /**
     * @notice Resolve token address from service registry
     * @dev Looks up the XOM or pXOM token address from OmniCore and
     *      reverts if the service is not registered (zero address).
     * @param usePrivateToken Whether to resolve pXOM instead of XOM
     * @return tokenAddress The resolved token contract address
     */
    function _resolveToken(
        bool usePrivateToken
    ) private view returns (address tokenAddress) {
        bytes32 tokenService = usePrivateToken
            ? PRIVATE_OMNICOIN_SERVICE
            : OMNICOIN_SERVICE;
        tokenAddress = core.getService(tokenService);
        if (tokenAddress == address(0)) revert InvalidAmount();
    }
}
/* solhint-enable max-states-count */