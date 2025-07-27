// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";

/**
 * @title BatchProcessor
 * @dev Handles batched transaction processing for gas efficiency
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
     * @dev First slot packs address (20 bytes) + enum (1) + 3 bools (3) = 24 bytes
     */
    struct BatchOperation {
        address target;         // 20 bytes
        OperationType opType;   // 1 byte
        bool usePrivacy;        // 1 byte
        bool executed;          // 1 byte
        bool success;           // 1 byte
        // 8 bytes padding to complete 32-byte slot
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
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant PROCESSOR_ROLE = keccak256("PROCESSOR_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant BATCH_TIMEOUT = 1 hours;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Batch counter
    uint256 public batchCounter;
    
    /// @dev Mapping of batch ID to batch data
    mapping(uint256 => Batch) public batches;
    
    /// @dev Required validator approvals for batch execution
    uint256 public requiredApprovals;
    
    /// @dev Gas limit per operation
    uint256 public gasLimitPerOperation;
    
    /// @dev Privacy fee for batch operations
    uint256 public batchPrivacyFee;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event BatchCreated(
        uint256 indexed batchId,
        address indexed submitter,
        uint256 operationCount,
        uint256 timestamp
    );
    
    event BatchApproved(
        uint256 indexed batchId,
        address indexed validator,
        uint256 approvalCount
    );
    
    event BatchExecuted(
        uint256 indexed batchId,
        uint256 successCount,
        uint256 failureCount,
        BatchStatus status
    );
    
    event OperationExecuted(
        uint256 indexed batchId,
        uint256 indexed operationIndex,
        bool success,
        bytes result
    );
    
    event BatchFailed(
        uint256 indexed batchId,
        string reason
    );
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
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
        Batch storage batch = batches[batchId];
        
        batch.batchId = batchId;
        batch.submitter = msg.sender;
        batch.status = BatchStatus.PENDING;
        batch.timestamp = block.timestamp;
        
        // Copy operations to storage
        for (uint256 i = 0; i < operations.length; ++i) {
            batch.operations.push(operations[i]);
        }
        
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
            address privacyFeeManager = _getContract(registry.FEE_MANAGER());
            if (privacyFeeManager != address(0)) {
                PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
                    msg.sender,
                    keccak256("BATCH_PROCESS"),
                    batchPrivacyFee
                );
            }
        }
        
        emit BatchCreated(batchId, msg.sender, operations.length, block.timestamp);
        
        return batchId;
    }
    
    // =============================================================================
    // BATCH APPROVAL & EXECUTION
    // =============================================================================
    
    /**
     * @dev Approve a batch for execution (validator only)
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
        if (block.timestamp > batch.timestamp + BATCH_TIMEOUT) revert BatchExpired();
        
        batch.validatorApprovals[msg.sender] = true;
        ++batch.approvalCount;
        
        emit BatchApproved(batchId, msg.sender, batch.approvalCount);
        
        // Execute if enough approvals
        if (batch.approvalCount >= requiredApprovals) {
            _executeBatch(batchId);
        }
    }
    
    /**
     * @dev Execute an approved batch
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
     * @dev Execute a single operation
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
     * @dev Execute batch transfer operation
     */
    function _executeTransfer(
        BatchOperation memory
    ) internal returns (bool success, bytes memory result) {
        // Decode transfer parameters
        // (address to, uint256 amount) = abi.decode(op.data, (address, uint256));
        
        // OmniCoinCore token = OmniCoinCore(_getContract(registry.OMNICOIN_CORE()));
        
        // try token.transferPublic(to, amount) returns (bool transferSuccess) {
        //     return (transferSuccess, "");
        // } catch Error(string memory reason) {
        //     return (false, bytes(reason));
        // } catch {
        //     return (false, "Transfer failed");
        // }
        return (false, "Not implemented");
    }
    
    /**
     * @dev Execute batch mint operation
     */
    function _executeMint(
        BatchOperation memory
    ) internal returns (bool success, bytes memory result) {
        // Only authorized minters can mint
        if (!hasRole(PROCESSOR_ROLE, msg.sender)) {
            revert UnauthorizedValidator();
        }
        
        // Decode mint parameters
        // (address to, uint256 amount) = abi.decode(op.data, (address, uint256));
        
        // Minting would be implemented based on token contract
        return (false, "Mint not implemented");
    }
    
    /**
     * @dev Execute batch burn operation
     */
    function _executeBurn(
        BatchOperation memory
    ) internal returns (bool success, bytes memory result) {
        // Decode burn parameters
        // (address from, uint256 amount) = abi.decode(op.data, (address, uint256));
        
        // Burning would be implemented based on token contract
        return (false, "Burn not implemented");
    }
    
    // =============================================================================
    // RECOVERY FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Retry failed operations in a batch
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
            if (index >= batch.operations.length) {
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
     * @dev Update required approvals
     * @param newRequired New number of required approvals
     */
    function updateRequiredApprovals(
        uint256 newRequired
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRequired == 0) revert InvalidBatchId();
        requiredApprovals = newRequired;
    }
    
    /**
     * @dev Update gas limit per operation
     * @param newLimit New gas limit
     */
    function updateGasLimitPerOperation(
        uint256 newLimit
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLimit == 0) revert InvalidBatchId();
        gasLimitPerOperation = newLimit;
    }
    
    /**
     * @dev Update batch privacy fee
     * @param newFee New privacy fee
     */
    function updateBatchPrivacyFee(
        uint256 newFee
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        batchPrivacyFee = newFee;
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
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
     * @dev Get operation details
     * @param batchId The batch ID
     * @param operationIndex The operation index
     */
    function getOperationDetails(
        uint256 batchId,
        uint256 operationIndex
    ) external view returns (BatchOperation memory) {
        if (operationIndex >= batches[batchId].operations.length) {
            revert OperationFailed(operationIndex);
        }
        return batches[batchId].operations[operationIndex];
    }
    
    /**
     * @dev Check if batch can be executed
     * @param batchId The batch ID
     */
    function canExecuteBatch(uint256 batchId) external view returns (bool) {
        Batch storage batch = batches[batchId];
        return (
            batch.status == BatchStatus.PENDING &&
            batch.approvalCount >= requiredApprovals &&
            block.timestamp <= batch.timestamp + BATCH_TIMEOUT
        );
    }
}