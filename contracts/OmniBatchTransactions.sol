// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OmniCoinCore} from "./OmniCoinCore.sol";
import {OmniCoin} from "./OmniCoin.sol";
import {PrivateOmniCoin} from "./PrivateOmniCoin.sol";
import {OmniCoinPrivacyBridge} from "./OmniCoinPrivacyBridge.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OmniBatchTransactions
 * @author OmniCoin Development Team
 * @notice Enables efficient batch execution of multiple operations in a single transaction
 * @dev Essential for wallet functionality to reduce gas costs and improve UX
 */
contract OmniBatchTransactions is
    Initializable,
    RegistryAware,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // =============================================================================
    // ENUMS & STRUCTS
    // =============================================================================
    
    enum TransactionType {
        TRANSFER,
        APPROVE,
        NFT_MINT,
        NFT_TRANSFER,
        ESCROW_CREATE,
        ESCROW_RELEASE,
        BRIDGE_TRANSFER,
        PRIVACY_DEPOSIT,
        PRIVACY_WITHDRAW,
        STAKE,
        UNSTAKE
    }

    struct BatchOperation {
        address target;          // 20 bytes
        TransactionType opType;  // 1 byte
        bool critical;           // 1 byte - If true, failure stops batch execution
        bool usePrivacy;         // 1 byte - Whether to use PrivateOmniCoin
        uint88 gasLimit;         // 11 bytes - Gas limit for this operation
        uint256 value;           // 32 bytes
        bytes data;              // dynamic
    }

    struct BatchResult {
        bool success;
        bytes returnData;
        uint256 gasUsed;
        string errorMessage;
    }

    struct BatchExecution {
        uint256 batchId;
        address executor;        // 20 bytes
        bool completed;          // 1 byte
        // 11 bytes padding
        uint256 operationCount;  // 32 bytes
        uint256 successCount;    // 32 bytes
        uint256 totalGasUsed;    // 32 bytes
        uint256 timestamp;       // 32 bytes
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice OmniCoin core contract instance
    OmniCoinCore public omniCoin;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error EmptyBatch();
    error BatchTooLarge();
    error InsufficientGas();
    error InternalCallOnly();
    error OperationFailed();
    error TransferFailed();
    error ApprovalFailed();
    error StakeOperationsNotSupported();
    error UnstakeOperationsNotSupported();
    error ArrayLengthMismatch();
    error TooManyTransfers();
    error Unauthorized();
    error InvalidWhitelistRequest();
    error InvalidMaxBatchSize();
    error InvalidMaxGasPerOperation();
    
    /// @notice Mapping of batch ID to batch execution details
    mapping(uint256 => BatchExecution) public batchExecutions;
    
    /// @notice Mapping of user address to their batch IDs
    mapping(address => uint256[]) public userBatches;
    
    /// @notice Mapping of authorized batch executors
    mapping(address => bool) public authorizedExecutors;
    
    /// @notice Current batch ID counter
    uint256 public batchCounter;
    
    /// @notice Maximum number of operations per batch
    uint256 public maxBatchSize;
    
    /// @notice Maximum gas allowed per operation
    uint256 public maxGasPerOperation;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when batch execution starts
     * @param batchId Unique batch identifier
     * @param executor Address executing the batch
     * @param operationCount Number of operations in batch
     */
    event BatchExecutionStarted(
        uint256 indexed batchId,
        address indexed executor,
        uint256 indexed operationCount
    );
    /**
     * @notice Emitted when batch execution completes
     * @param batchId Unique batch identifier
     * @param successCount Number of successful operations
     * @param totalGasUsed Total gas consumed
     */
    event BatchExecutionCompleted(
        uint256 indexed batchId,
        uint256 indexed successCount,
        uint256 indexed totalGasUsed
    );
    /**
     * @notice Emitted for each operation execution
     * @param batchId Unique batch identifier
     * @param operationIndex Index of operation in batch
     * @param success Whether operation succeeded
     * @param gasUsed Gas consumed by operation
     */
    event OperationExecuted(
        uint256 indexed batchId,
        uint256 indexed operationIndex,
        bool indexed success,
        uint256 gasUsed
    );
    /**
     * @notice Emitted when an executor is authorized
     * @param executor Address of the authorized executor
     */
    event ExecutorAuthorized(address indexed executor);
    
    /**
     * @notice Emitted when an executor is deauthorized
     * @param executor Address of the deauthorized executor
     */
    event ExecutorDeauthorized(address indexed executor);
    
    /**
     * @notice Emitted when max batch size is updated
     * @param newSize New maximum batch size
     */
    event MaxBatchSizeUpdated(uint256 indexed newSize);
    
    /**
     * @notice Emitted when max gas per operation is updated
     * @param newGas New maximum gas per operation
     */
    event MaxGasPerOperationUpdated(uint256 indexed newGas);

    /**
     * @notice Constructor for the upgradeable contract
     * @dev Disables initializers to prevent implementation contract initialization
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the batch transaction contract
     * @dev Called once during deployment
     * @param _registry Address of the registry contract
     * @param _omniCoin Address of the OmniCoin core contract (deprecated, use registry)
     */
    function initialize(address _registry, address _omniCoin) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        
        // Initialize registry
        _initializeRegistry(_registry);

        // For backwards compatibility
        if (_omniCoin != address(0)) {
            omniCoin = OmniCoinCore(_omniCoin);
        }
        
        maxBatchSize = 50; // Maximum 50 operations per batch
        maxGasPerOperation = 500000; // 500k gas per operation max
        batchCounter = 0;
    }

    /**
     * @notice Execute a batch of operations
     * @dev Executes operations sequentially, stopping on critical failures
     * @param operations Array of batch operations to execute
     * @return batchId Unique identifier for this batch
     * @return results Array of results for each operation
     */
    function executeBatch(
        BatchOperation[] calldata operations
    )
        external
        nonReentrant
        returns (uint256 batchId, BatchResult[] memory results)
    {
        if (operations.length == 0) revert EmptyBatch();
        if (operations.length > maxBatchSize) revert BatchTooLarge();

        ++batchCounter;
        batchId = batchCounter;
        results = new BatchResult[](operations.length);

        uint256 successCount = 0;
        uint256 totalGasUsed = 0;

        // Create batch execution record
        batchExecutions[batchId] = BatchExecution({
            batchId: batchId,
            executor: msg.sender,
            operationCount: operations.length,
            successCount: 0,
            totalGasUsed: 0,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            completed: false
        });

        userBatches[msg.sender].push(batchId);

        emit BatchExecutionStarted(batchId, msg.sender, operations.length);

        // Execute each operation
        for (uint256 i = 0; i < operations.length; ++i) {
            uint256 gasStart = gasleft();

            (
                bool success,
                bytes memory returnData,
                string memory errorMsg
            ) = _executeOperation(operations[i]);

            uint256 gasUsed = gasStart - gasleft();
            totalGasUsed += gasUsed;

            results[i] = BatchResult({
                success: success,
                returnData: returnData,
                gasUsed: gasUsed,
                errorMessage: errorMsg
            });

            if (success) {
                ++successCount;
            } else if (operations[i].critical) {
                // Stop execution if critical operation fails
                break;
            }

            emit OperationExecuted(batchId, i, success, gasUsed);
        }

        // Update batch execution record
        batchExecutions[batchId].successCount = successCount;
        batchExecutions[batchId].totalGasUsed = totalGasUsed;
        batchExecutions[batchId].completed = true;

        emit BatchExecutionCompleted(batchId, successCount, totalGasUsed);
    }

    /**
     * @notice Execute a single operation within a batch
     * @dev Executes operation with gas limiting and error handling
     * @param operation The operation to execute
     * @return success Whether the operation succeeded
     * @return returnData Data returned from the operation
     * @return errorMessage Error message if operation failed
     */
    function _executeOperation(
        BatchOperation calldata operation
    )
        internal
        returns (
            bool success,
            bytes memory returnData,
            string memory errorMessage
        )
    {
        if (gasleft() < maxGasPerOperation) revert InsufficientGas();

        try this._performOperation{gas: maxGasPerOperation}(operation) returns (
            bytes memory data
        ) {
            return (true, data, "");
        } catch Error(string memory reason) {
            return (false, "", reason);
        } catch (bytes memory lowLevelData) {
            return (false, lowLevelData, "Low-level error");
        }
    }

    /**
     * @notice Perform the actual operation (external call for gas limiting)
     * @dev Must be called internally via this._performOperation
     * @param operation The operation to execute
     * @return Data returned from the operation
     */
    function _performOperation(
        BatchOperation calldata operation
    ) external returns (bytes memory) {
        if (msg.sender != address(this)) revert InternalCallOnly();

        if (operation.opType == TransactionType.TRANSFER) {
            return _executeTransfer(operation);
        } else if (operation.opType == TransactionType.APPROVE) {
            return _executeApprove(operation);
        } else if (operation.opType == TransactionType.BRIDGE_TRANSFER) {
            return _executeBridgeTransfer(operation);
        } else if (operation.opType == TransactionType.PRIVACY_DEPOSIT) {
            return _executePrivacyDeposit(operation);
        } else if (operation.opType == TransactionType.PRIVACY_WITHDRAW) {
            return _executePrivacyWithdraw(operation);
        } else if (operation.opType == TransactionType.STAKE) {
            return _executeStake(operation);
        } else if (operation.opType == TransactionType.UNSTAKE) {
            return _executeUnstake(operation);
        } else {
            // For other operation types, make direct call
            (bool success, bytes memory data) = operation.target.call{
                value: operation.value
            }(operation.data);
            if (!success) revert OperationFailed();
            return data;
        }
    }

    /**
     * @notice Execute token transfer
     * @dev Decodes transfer parameters and executes via appropriate token
     * @param operation The transfer operation
     * @return Encoded success boolean
     */
    function _executeTransfer(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(
            operation.data,
            (address, uint256)
        );
        
        if (operation.usePrivacy) {
            // Use PrivateOmniCoin
            address privateToken = _getContract(registry.PRIVATE_OMNICOIN());
            if (!IERC20(privateToken).transfer(recipient, amount)) revert TransferFailed();
        } else {
            // Use OmniCoin
            address publicToken = _getContract(registry.OMNICOIN());
            if (publicToken != address(0)) {
                if (!IERC20(publicToken).transfer(recipient, amount)) revert TransferFailed();
            } else if (address(omniCoin) != address(0)) {
                // Fallback to legacy OmniCoinCore
                if (!omniCoin.transferPublic(recipient, amount)) revert TransferFailed();
            } else {
                revert TransferFailed();
            }
        }
        
        return abi.encode(true);
    }

    /**
     * @notice Execute token approval
     * @dev Decodes approval parameters and executes via appropriate token
     * @param operation The approval operation
     * @return Encoded success boolean
     */
    function _executeApprove(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        (address spender, uint256 amount) = abi.decode(
            operation.data,
            (address, uint256)
        );
        
        if (operation.usePrivacy) {
            // Use PrivateOmniCoin
            address privateToken = _getContract(registry.PRIVATE_OMNICOIN());
            if (!IERC20(privateToken).approve(spender, amount)) revert ApprovalFailed();
        } else {
            // Use OmniCoin
            address publicToken = _getContract(registry.OMNICOIN());
            if (publicToken != address(0)) {
                if (!IERC20(publicToken).approve(spender, amount)) revert ApprovalFailed();
            } else if (address(omniCoin) != address(0)) {
                // Fallback to legacy OmniCoinCore
                if (!omniCoin.approvePublic(spender, amount)) revert ApprovalFailed();
            } else {
                revert ApprovalFailed();
            }
        }
        
        return abi.encode(true);
    }

    /**
     * @notice Execute staking
     * @dev Currently not implemented - use OmniCoinStaking
     * @return Never returns, always reverts
     */
    function _executeStake(
        BatchOperation calldata /* operation */
    ) internal pure returns (bytes memory) {
        // Staking functionality would be in OmniCoinStaking contract
        revert StakeOperationsNotSupported();
    }

    /**
     * @notice Execute unstaking
     * @dev Currently not implemented - use OmniCoinStaking
     * @return Never returns, always reverts
     */
    function _executeUnstake(
        BatchOperation calldata /* operation */
    ) internal pure returns (bytes memory) {
        // Unstaking functionality would be in OmniCoinStaking contract
        revert UnstakeOperationsNotSupported();
    }
    
    /**
     * @notice Execute bridge transfer between OmniCoin and PrivateOmniCoin
     * @dev Executes conversion via OmniCoinPrivacyBridge
     * @param operation The bridge operation
     * @return Encoded amount output
     */
    function _executeBridgeTransfer(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        (uint256 amount, bool toPrivate) = abi.decode(
            operation.data,
            (uint256, bool)
        );
        
        address bridge = _getContract(registry.OMNICOIN_BRIDGE());
        if (bridge == address(0)) revert OperationFailed();
        
        uint256 amountOut;
        if (toPrivate) {
            amountOut = OmniCoinPrivacyBridge(bridge).convertToPrivate(amount);
        } else {
            amountOut = OmniCoinPrivacyBridge(bridge).convertToPublic(amount);
        }
        
        return abi.encode(amountOut);
    }
    
    /**
     * @notice Execute privacy deposit (convert to private tokens)
     * @dev Convenience wrapper for bridge operation
     * @param operation The deposit operation
     * @return Encoded amount output
     */
    function _executePrivacyDeposit(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        uint256 amount = abi.decode(operation.data, (uint256));
        
        // Create bridge operation data
        operation.data = abi.encode(amount, true); // true = convert to private
        return _executeBridgeTransfer(operation);
    }
    
    /**
     * @notice Execute privacy withdraw (convert to public tokens)
     * @dev Convenience wrapper for bridge operation
     * @param operation The withdraw operation
     * @return Encoded amount output
     */
    function _executePrivacyWithdraw(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        uint256 amount = abi.decode(operation.data, (uint256));
        
        // Create bridge operation data
        operation.data = abi.encode(amount, false); // false = convert to public
        return _executeBridgeTransfer(operation);
    }

    /**
     * @notice Create optimized batch for common wallet operations
     * @dev Generates batch operations for multiple transfers
     * @param recipients Array of recipient addresses
     * @param amounts Array of transfer amounts
     * @return operations Array of batch operations
     */
    function createTransferBatch(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external view returns (BatchOperation[] memory operations) {
        if (recipients.length != amounts.length) revert ArrayLengthMismatch();
        if (recipients.length > maxBatchSize) revert TooManyTransfers();

        operations = new BatchOperation[](recipients.length);

        for (uint256 i = 0; i < recipients.length; ++i) {
            operations[i] = BatchOperation({
                opType: TransactionType.TRANSFER,
                target: address(0), // Will be determined by usePrivacy flag
                data: abi.encode(recipients[i], amounts[i]),
                value: 0,
                critical: false,
                usePrivacy: false, // Default to public transfers
                gasLimit: uint88(maxGasPerOperation)
            });
        }
    }

    /**
     * @notice Create optimized batch for NFT operations
     * @dev Generates batch operations for multiple NFT mints
     * @param nftContract Address of the NFT contract
     * @param recipients Array of recipient addresses
     * @param tokenURIs Array of token URIs
     * @return operations Array of batch operations
     */
    function createNFTBatch(
        address nftContract,
        address[] calldata recipients,
        string[] calldata tokenURIs
    ) external view returns (BatchOperation[] memory operations) {
        if (recipients.length != tokenURIs.length) revert ArrayLengthMismatch();
        if (recipients.length > maxBatchSize) revert TooManyTransfers();

        operations = new BatchOperation[](recipients.length);

        for (uint256 i = 0; i < recipients.length; ++i) {
            operations[i] = BatchOperation({
                opType: TransactionType.NFT_MINT,
                target: nftContract,
                data: abi.encodeWithSignature(
                    "mint(address,string)",
                    recipients[i],
                    tokenURIs[i]
                ),
                value: 0,
                critical: false,
                usePrivacy: false, // NFTs don't use privacy flag
                gasLimit: uint88(maxGasPerOperation)
            });
        }
    }

    /**
     * @notice Get batch execution details
     * @dev Returns full details of a batch execution
     * @param batchId The batch ID to query
     * @return BatchExecution struct with all details
     */
    function getBatchExecution(
        uint256 batchId
    ) external view returns (BatchExecution memory) {
        return batchExecutions[batchId];
    }

    /**
     * @notice Get user's batch history
     * @dev Returns array of batch IDs for a user
     * @param user The user address to query
     * @return Array of batch IDs
     */
    function getUserBatches(
        address user
    ) external view returns (uint256[] memory) {
        return userBatches[user];
    }

    /**
     * @notice Estimate gas for a batch operation
     * @dev Provides rough gas estimate for planning
     * @param operations Array of operations to estimate
     * @return totalGasEstimate Estimated total gas cost
     */
    function estimateBatchGas(
        BatchOperation[] calldata operations
    ) external view returns (uint256 totalGasEstimate) {
        totalGasEstimate = 21000; // Base transaction gas

        for (uint256 i = 0; i < operations.length; ++i) {
            if (operations[i].opType == TransactionType.TRANSFER) {
                totalGasEstimate += 65000; // Approximate gas for ERC20 transfer
            } else if (operations[i].opType == TransactionType.APPROVE) {
                totalGasEstimate += 46000; // Approximate gas for ERC20 approval
            } else if (operations[i].opType == TransactionType.NFT_MINT) {
                totalGasEstimate += 150000; // Approximate gas for NFT mint
            } else {
                totalGasEstimate += maxGasPerOperation; // Conservative estimate
            }
        }
    }

    /**
     * @notice Authorize an executor for advanced batch operations
     * @dev Grants executor privileges to an address
     * @param executor Address to authorize
     */
    function authorizeExecutor(address executor) external onlyOwner {
        authorizedExecutors[executor] = true;
        emit ExecutorAuthorized(executor);
    }

    /**
     * @notice Deauthorize an executor
     * @dev Removes executor privileges from an address
     * @param executor Address to deauthorize
     */
    function deauthorizeExecutor(address executor) external onlyOwner {
        authorizedExecutors[executor] = false;
        emit ExecutorDeauthorized(executor);
    }

    /**
     * @notice Update maximum batch size
     * @dev Adjusts the limit on operations per batch
     * @param newSize New maximum batch size (1-100)
     */
    function updateMaxBatchSize(uint256 newSize) external onlyOwner {
        if (newSize == 0 || newSize > 100) revert InvalidMaxBatchSize();
        maxBatchSize = newSize;
        emit MaxBatchSizeUpdated(newSize);
    }

    /**
     * @notice Update maximum gas per operation
     * @dev Adjusts gas limit for individual operations
     * @param newGas New gas limit (100k-1M)
     */
    function updateMaxGasPerOperation(uint256 newGas) external onlyOwner {
        if (newGas < 100000 || newGas > 1000000) revert InvalidMaxGasPerOperation();
        maxGasPerOperation = newGas;
        emit MaxGasPerOperationUpdated(newGas);
    }

    /**
     * @notice Emergency pause for batch operations
     * @dev Pauses all batch execution functionality
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume batch operations
     * @dev Unpauses batch execution functionality
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }
}
