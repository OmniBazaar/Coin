// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";
import {OmniCoin} from "./OmniCoin.sol";
import {PrivateOmniCoin} from "./PrivateOmniCoin.sol";
import {OmniCoinPrivacyBridge} from "./OmniCoinPrivacyBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BatchProcessor
 * @author OmniBazaar Team
 * @notice Handles batched transaction processing for gas efficiency and privacy-aware batch processing
 * @dev Implements validator consensus for batch execution with failed operation recovery mechanism
 * 
 * Features:
 * - Batch multiple operations in single transaction
 * - Privacy-aware batch processing
 * - Validator consensus for batch execution
 * - Failed operation recovery mechanism
 */
contract BatchProcessor is RegistryAware, AccessControl, Pausable, ReentrancyGuard {
    
    // =============================================================================
    // ENUMS & STRUCTS
    // =============================================================================
    
    enum OperationType {
        TRANSFER,
        MINT,
        BURN,
        ESCROW_CREATE,
        ESCROW_RELEASE,
        STAKE,
        UNSTAKE,
        BRIDGE_TO_PRIVATE,
        BRIDGE_TO_PUBLIC,
        CUSTOM
    }
    
    enum BatchStatus {
        PENDING,
        PROCESSING,
        COMPLETED,
        FAILED,
        PARTIALLY_COMPLETED
    }
    
    /**
     * @notice Struct for batch operations with gas-optimized packing
     * @dev Optimized for 32-byte slot alignment
     */
    struct BatchOperation {
        address target;         // 20 bytes
        OperationType opType;   // 1 byte  
        bool usePrivacy;        // 1 byte
        bool executed;          // 1 byte
        bool success;           // 1 byte
        uint64 gasUsed;         // 8 bytes - fills the first 32-byte slot
        uint256 value;          // 32 bytes
        bytes data;             // dynamic
        bytes result;           // dynamic
    }
    
    struct Batch {
        uint256 batchId;
        address submitter;
        BatchOperation[] operations;
        BatchStatus status;
        uint256 timestamp;
        uint256 successCount;
        uint256 failureCount;
        mapping(address => bool) validatorApprovals;
        uint256 approvalCount;
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for batch processors
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    /// @notice Role for validators who approve batches
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    /// @notice Maximum number of operations allowed in a single batch
    uint256 public constant MAX_BATCH_SIZE = 100;
    /// @notice Time limit for batch approval before expiration
    uint256 public constant BATCH_TIMEOUT = 1 hours;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error BatchSizeTooLarge();
    error InvalidBatchId();
    error BatchNotPending();
    error InsufficientValidations();
    error BatchExpired();
    error AlreadyValidated();
    error InvalidOperationType();
    error OperationFailed(uint256 index);
    error UnauthorizedValidator();
    error BatchNotCompleted();
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Counter for generating unique batch IDs
    uint256 public batchCounter;
    
    /// @notice Mapping of batch ID to batch data
    mapping(uint256 => Batch) public batches;
    
    /// @notice Required validator approvals for batch execution
    uint256 public requiredApprovals;
    
    /// @notice Gas limit per operation to prevent DoS
    uint256 public gasLimitPerOperation;
    
    /// @notice Privacy fee charged for batch operations using privacy features
    uint256 public batchPrivacyFee;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a new batch is created
     * @param batchId Unique identifier for the batch
     * @param submitter Address that created the batch
     * @param operationCount Number of operations in the batch
     * @param timestamp Block timestamp when batch was created
     */
    event BatchCreated(
        uint256 indexed batchId,
        address indexed submitter,
        uint256 indexed operationCount,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when a validator approves a batch
     * @param batchId Unique identifier for the batch
     * @param validator Address of the approving validator
     * @param approvalCount Total number of approvals after this approval
     */
    event BatchApproved(
        uint256 indexed batchId,
        address indexed validator,
        uint256 indexed approvalCount
    );
    
    /**
     * @notice Emitted when a batch is executed
     * @param batchId Unique identifier for the batch
     * @param successCount Number of successful operations
     * @param failureCount Number of failed operations  
     * @param status Final status of the batch
     */
    event BatchExecuted(
        uint256 indexed batchId,
        uint256 successCount,
        uint256 failureCount,
        BatchStatus status
    );
    
    /**
     * @notice Emitted when an individual operation is executed
     * @param batchId Unique identifier for the batch
     * @param operationIndex Index of the operation within the batch
     * @param success Whether the operation succeeded
     * @param result Return data from the operation
     */
    event OperationExecuted(
        uint256 indexed batchId,
        uint256 indexed operationIndex,
        bool indexed success,
        bytes result
    );
    
    /**
     * @notice Emitted when a batch fails
     * @param batchId Unique identifier for the batch
     * @param reason Failure reason
     */
    event BatchFailed(
        uint256 indexed batchId,
        string reason
    );
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initializes the BatchProcessor contract
     * @param _registry Address of the registry contract
     * @param _admin Address of the initial admin
     */
    constructor(
        address _registry,
        address _admin
    ) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PROCESSOR_ROLE, _admin);
        
        requiredApprovals = 3;
        gasLimitPerOperation = 500000; // 500k gas per operation
        batchPrivacyFee = 0.01 ether; // Base privacy fee for batch
    }
    
    // =============================================================================
    // BATCH CREATION
    // =============================================================================
    
    /**
     * @notice Create a new batch of operations
     * @dev Collects privacy fee if any operations use privacy
     * @param operations Array of operations to execute
     * @return batchId The ID of the created batch
     */
    function createBatch(
        BatchOperation[] calldata operations
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (operations.length == 0) revert InvalidBatchId();
        if (operations.length > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        
        uint256 batchId = batchCounter;
        ++batchCounter;
        
        _storeBatch(batchId, operations);
        _handlePrivacyFees(operations);
        
        emit BatchCreated(
            batchId, 
            msg.sender, 
            operations.length, 
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        return batchId;
    }
    
    /**
     * @notice Store batch operations in storage
     * @dev Internal helper to reduce complexity
     * @param batchId The batch ID
     * @param operations Array of operations to store
     */
    function _storeBatch(uint256 batchId, BatchOperation[] calldata operations) internal {
        Batch storage batch = batches[batchId];
        batch.batchId = batchId;
        batch.submitter = msg.sender;
        batch.status = BatchStatus.PENDING;
        batch.timestamp = block.timestamp; // solhint-disable-line not-rely-on-time
        
        // Copy operations to storage
        for (uint256 i = 0; i < operations.length; ++i) {
            batch.operations.push(operations[i]);
        }
    }
    
    /**
     * @notice Handle privacy fee collection for batch operations
     * @dev Internal helper to reduce complexity
     * @param operations Array of operations to check for privacy
     */
    function _handlePrivacyFees(BatchOperation[] calldata operations) internal {
        // Check if privacy fees needed
        bool hasPrivacyOps = false;
        for (uint256 i = 0; i < operations.length; ++i) {
            if (operations[i].usePrivacy) {
                hasPrivacyOps = true;
                break;
            }
        }
        
        // Collect privacy fee if applicable
        if (hasPrivacyOps) {
            address privacyFeeManager = _getContract(REGISTRY.FEE_MANAGER());
            if (privacyFeeManager != address(0)) {
                PrivacyFeeManager(privacyFeeManager).collectPrivateFee(
                    msg.sender,
                    keccak256("BATCH_PROCESS"),
                    batchPrivacyFee
                );
            }
        }
    }
    
    // =============================================================================
    // BATCH APPROVAL & EXECUTION
    // =============================================================================
    
    /**
     * @notice Approve a batch for execution (validator only)
     * @dev Requires validator role and batch to be in pending status
     * @param batchId The batch to approve
     */
    function approveBatch(uint256 batchId) 
        external 
        onlyRole(VALIDATOR_ROLE) 
        whenNotPaused 
    {
        Batch storage batch = batches[batchId];
        if (batch.timestamp == 0) revert InvalidBatchId();
        if (batch.status != BatchStatus.PENDING) revert BatchNotPending();
        if (batch.validatorApprovals[msg.sender]) revert AlreadyValidated();
        if (block.timestamp > batch.timestamp + BATCH_TIMEOUT) { // solhint-disable-line not-rely-on-time
            revert BatchExpired();
        }
        
        batch.validatorApprovals[msg.sender] = true;
        ++batch.approvalCount;
        
        emit BatchApproved(batchId, msg.sender, batch.approvalCount);
        
        // Execute if enough approvals
        if (batch.approvalCount > requiredApprovals - 1) {
            _executeBatch(batchId);
        }
    }
    
    /**
     * @notice Execute an approved batch
     * @dev Internal function that executes all operations in the batch
     * @param batchId The batch to execute
     */
    function _executeBatch(uint256 batchId) internal {
        Batch storage batch = batches[batchId];
        batch.status = BatchStatus.PROCESSING;
        
        uint256 successCount = 0;
        uint256 failureCount = 0;
        
        // Execute each operation
        for (uint256 i = 0; i < batch.operations.length; ++i) {
            BatchOperation storage op = batch.operations[i];
            
            if (op.executed) continue; // Skip already executed
            
            // Execute operation with gas limit
            (bool success, bytes memory result) = _executeOperation(op);
            
            op.executed = true;
            op.success = success;
            op.result = result;
            
            if (success) {
                ++successCount;
            } else {
                ++failureCount;
            }
            
            emit OperationExecuted(batchId, i, success, result);
        }
        
        // Update batch status
        batch.successCount = successCount;
        batch.failureCount = failureCount;
        
        if (failureCount == 0) {
            batch.status = BatchStatus.COMPLETED;
        } else if (successCount == 0) {
            batch.status = BatchStatus.FAILED;
        } else {
            batch.status = BatchStatus.PARTIALLY_COMPLETED;
        }
        
        emit BatchExecuted(batchId, successCount, failureCount, batch.status);
    }
    
    /**
     * @notice Execute a single operation
     * @dev Routes execution based on operation type
     * @param op The operation to execute
     * @return success Whether the operation succeeded
     * @return result Return data from the operation
     */
    function _executeOperation(
        BatchOperation memory op
    ) internal returns (bool success, bytes memory result) {
        if (op.opType == OperationType.TRANSFER) {
            return _executeTransfer(op);
        } else if (op.opType == OperationType.MINT) {
            return _executeMint(op);
        } else if (op.opType == OperationType.BURN) {
            return _executeBurn(op);
        } else if (op.opType == OperationType.BRIDGE_TO_PRIVATE) {
            return _executeBridgeToPrivate(op);
        } else if (op.opType == OperationType.BRIDGE_TO_PUBLIC) {
            return _executeBridgeToPublic(op);
        } else if (op.opType == OperationType.CUSTOM) {
            // Custom operation - direct call with gas limit
            (success, result) = op.target.call{
                value: op.value,
                gas: gasLimitPerOperation
            }(op.data);
        } else {
            // Other operation types would be implemented similarly
            return (false, "Unsupported operation type");
        }
    }
    
    /**
     * @notice Execute batch transfer operation
     * @dev Executes token transfers using either standard ERC20 or private transfers
     * @param op The batch operation containing transfer details
     * @return success Whether the transfer succeeded
     * @return result Return data from the transfer
     */
    function _executeTransfer(
        BatchOperation memory op
    ) internal returns (bool success, bytes memory result) {
        // Decode transfer parameters
        (address token, address to, uint256 amount) = abi.decode(op.data, (address, address, uint256));
        
        // Determine which token to use
        address tokenAddress;
        if (token == address(0)) {
            // Default to public OmniCoin if no token specified
            tokenAddress = _getContract(REGISTRY.OMNICOIN());
        } else {
            tokenAddress = token;
        }
        
        // Execute transfer based on privacy mode
        if (op.usePrivacy) {
            // Use PrivateOmniCoin for privacy transfers
            address privateToken = _getContract(REGISTRY.PRIVATE_OMNICOIN());
            if (tokenAddress != privateToken) {
                return (false, "Privacy transfer needs PrivateOmniCoin");
            }
            
            // Use PrivateOmniCoin's private transfer method
            try PrivateOmniCoin(privateToken).transferFromPrivate(
                op.target, 
                to, 
                amount
            ) returns (bool transferSuccess) {
                return (transferSuccess, "");
            } catch Error(string memory reason) {
                return (false, bytes(reason));
            } catch {
                return (false, "Private transfer failed");
            }
        } else {
            // Standard ERC20 transfer
            try IERC20(tokenAddress).transferFrom(op.target, to, amount) returns (bool transferSuccess) {
                return (transferSuccess, "");
            } catch Error(string memory reason) {
                return (false, bytes(reason));
            } catch {
                return (false, "Transfer failed");
            }
        }
    }
    
    /**
     * @notice Execute batch mint operation
     * @dev Executes token minting for authorized processors (public tokens only)
     * @param op The batch operation containing mint details
     * @return success Whether the mint succeeded
     * @return result Return data from the mint
     */
    function _executeMint(
        BatchOperation memory op
    ) internal returns (bool success, bytes memory result) {
        // Only authorized minters can mint
        if (!hasRole(PROCESSOR_ROLE, msg.sender)) {
            return (false, "Unauthorized minter");
        }
        
        // Decode mint parameters
        (address token, address to, uint256 amount) = abi.decode(op.data, (address, address, uint256));
        
        // Determine which token to mint
        address tokenAddress;
        if (token == address(0)) {
            tokenAddress = _getContract(REGISTRY.OMNICOIN());
        } else {
            tokenAddress = token;
        }
        
        // Check if minting private tokens
        address privateToken = _getContract(REGISTRY.PRIVATE_OMNICOIN());
        if (tokenAddress == privateToken) {
            // Private token minting is restricted
            return (false, "Private mint not allowed in batch");
        }
        
        // Execute mint on public token
        try OmniCoin(tokenAddress).mint(to, amount) {
            return (true, "");
        } catch Error(string memory reason) {
            return (false, bytes(reason));
        } catch {
            return (false, "Mint failed");
        }
    }
    
    /**
     * @notice Execute batch burn operation
     * @dev Executes token burning (public tokens only, private burns not supported)
     * @param op The batch operation containing burn details
     * @return success Whether the burn succeeded
     * @return result Return data from the burn
     */
    function _executeBurn(
        BatchOperation memory op
    ) internal returns (bool success, bytes memory result) {
        // Decode burn parameters
        (address token, uint256 amount) = abi.decode(op.data, (address, uint256));
        
        // Determine which token to burn
        address tokenAddress;
        if (token == address(0)) {
            tokenAddress = _getContract(REGISTRY.OMNICOIN());
        } else {
            tokenAddress = token;
        }
        
        // Execute burn based on token type
        if (op.usePrivacy) {
            // Burn private tokens
            address privateToken = _getContract(REGISTRY.PRIVATE_OMNICOIN());
            if (tokenAddress != privateToken) {
                return (false, "Privacy burn needs PrivateOmniCoin");
            }
            
            // PrivateOmniCoin burning requires bridge role
            // For batch processing, we can't burn private tokens directly
            return (false, "Private burn not supported in batch");
        } else {
            // Standard burn
            try OmniCoin(tokenAddress).burnFrom(op.target, amount) {
                return (true, "");
            } catch Error(string memory reason) {
                return (false, bytes(reason));
            } catch {
                return (false, "Burn failed");
            }
        }
    }
    
    /**
     * @notice Execute bridge to private operation
     * @dev Bridges public OmniCoin to PrivateOmniCoin
     * @param op The operation containing bridge details
     * @return success Whether the bridge operation succeeded
     * @return result Return data from the bridge
     */
    function _executeBridgeToPrivate(
        BatchOperation memory op
    ) internal returns (bool success, bytes memory result) {
        // Decode bridge parameters
        (uint256 amount) = abi.decode(op.data, (uint256));
        
        // Get bridge contract
        address bridge = _getContract(REGISTRY.OMNICOIN_BRIDGE());
        if (bridge == address(0)) {
            return (false, "Bridge not configured");
        }
        
        // Execute bridge operation
        try OmniCoinPrivacyBridge(bridge).convertToPrivate(amount) returns (uint256 amountOut) {
            return (true, abi.encode(amountOut));
        } catch Error(string memory reason) {
            return (false, bytes(reason));
        } catch {
            return (false, "Bridge to private failed");
        }
    }
    
    /**
     * @notice Execute bridge to public operation
     * @dev Bridges PrivateOmniCoin back to public OmniCoin
     * @param op The operation containing bridge details
     * @return success Whether the bridge operation succeeded
     * @return result Return data from the bridge
     */
    function _executeBridgeToPublic(
        BatchOperation memory op
    ) internal returns (bool success, bytes memory result) {
        // Decode bridge parameters
        (uint256 amount) = abi.decode(op.data, (uint256));
        
        // Get bridge contract
        address bridge = _getContract(REGISTRY.OMNICOIN_BRIDGE());
        if (bridge == address(0)) {
            return (false, "Bridge not configured");
        }
        
        // Execute bridge operation
        try OmniCoinPrivacyBridge(bridge).convertToPublic(amount) {
            return (true, abi.encode(amount)); // Return the amount that was converted
        } catch Error(string memory reason) {
            return (false, bytes(reason));
        } catch {
            return (false, "Bridge to public failed");
        }
    }
    
    // =============================================================================
    // RECOVERY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Retry failed operations in a batch
     * @dev Allows processors to retry specific failed operations
     * @param batchId The batch ID
     * @param operationIndices Indices of operations to retry
     */
    function retryFailedOperations(
        uint256 batchId,
        uint256[] calldata operationIndices
    ) external onlyRole(PROCESSOR_ROLE) whenNotPaused {
        Batch storage batch = batches[batchId];
        if (batch.status != BatchStatus.PARTIALLY_COMPLETED && 
            batch.status != BatchStatus.FAILED) {
            revert BatchNotCompleted();
        }
        
        for (uint256 i = 0; i < operationIndices.length; ++i) {
            uint256 index = operationIndices[i];
            if (index > batch.operations.length - 1) {
                revert OperationFailed(index);
            }
            
            BatchOperation storage op = batch.operations[index];
            if (!op.executed || op.success) {
                revert OperationFailed(index);
            }
            
            // Retry the operation
            (bool success, bytes memory result) = _executeOperation(op);
            op.success = success;
            op.result = result;
            
            if (success) {
                ++batch.successCount;
                --batch.failureCount;
            }
            
            emit OperationExecuted(batchId, index, success, result);
        }
        
        // Update batch status if all succeeded
        if (batch.failureCount == 0) {
            batch.status = BatchStatus.COMPLETED;
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update required approvals for batch execution
     * @dev Admin function to adjust consensus requirements
     * @param newRequired New number of required approvals
     */
    function updateRequiredApprovals(
        uint256 newRequired
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRequired == 0) revert InvalidBatchId();
        requiredApprovals = newRequired;
    }
    
    /**
     * @notice Update gas limit per operation
     * @dev Admin function to adjust gas limits for safety
     * @param newLimit New gas limit
     */
    function updateGasLimitPerOperation(
        uint256 newLimit
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLimit == 0) revert InvalidBatchId();
        gasLimitPerOperation = newLimit;
    }
    
    /**
     * @notice Update batch privacy fee
     * @dev Admin function to adjust privacy fee amount
     * @param newFee New privacy fee
     */
    function updateBatchPrivacyFee(
        uint256 newFee
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        batchPrivacyFee = newFee;
    }
    
    /**
     * @notice Emergency pause
     * @dev Pauses all batch operations
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause contract operations  
     * @dev Resumes normal batch operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get batch details
     * @param batchId The batch ID
     * @return submitter Address that created the batch
     * @return status Current status of the batch
     * @return timestamp When the batch was created
     * @return operationCount Number of operations in the batch
     * @return successCount Number of successful operations
     * @return failureCount Number of failed operations
     * @return approvalCount Number of validator approvals
     */
    function getBatchDetails(uint256 batchId) external view returns (
        address submitter,
        BatchStatus status,
        uint256 timestamp,
        uint256 operationCount,
        uint256 successCount,
        uint256 failureCount,
        uint256 approvalCount
    ) {
        Batch storage batch = batches[batchId];
        return (
            batch.submitter,
            batch.status,
            batch.timestamp,
            batch.operations.length,
            batch.successCount,
            batch.failureCount,
            batch.approvalCount
        );
    }
    
    /**
     * @notice Get operation details
     * @dev Returns full details of a specific operation
     * @param batchId The batch ID
     * @param operationIndex The operation index
     * @return The BatchOperation struct with all details
     */
    function getOperationDetails(
        uint256 batchId,
        uint256 operationIndex
    ) external view returns (BatchOperation memory) {
        if (operationIndex > batches[batchId].operations.length - 1) {
            revert OperationFailed(operationIndex);
        }
        return batches[batchId].operations[operationIndex];
    }
    
    /**
     * @notice Check if batch can be executed
     * @dev Verifies all conditions for batch execution
     * @param batchId The batch ID
     * @return Whether the batch can be executed
     */
    function canExecuteBatch(uint256 batchId) external view returns (bool) {
        Batch storage batch = batches[batchId];
        return (
            batch.status == BatchStatus.PENDING &&
            batch.approvalCount > requiredApprovals - 1 &&
            block.timestamp < batch.timestamp + BATCH_TIMEOUT + 1 // solhint-disable-line not-rely-on-time
        );
    }
}