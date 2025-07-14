// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./omnicoin-erc20-coti.sol";

/**
 * @title OmniBatchTransactions
 * @dev Enables efficient batch execution of multiple operations in a single transaction
 * Essential for wallet functionality to reduce gas costs and improve UX
 */
contract OmniBatchTransactions is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // Transaction types
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

    // Batch operation structure
    struct BatchOperation {
        TransactionType opType;
        address target;
        bytes data;
        uint256 value;
        bool critical; // If true, failure stops batch execution
    }

    struct BatchResult {
        bool success;
        bytes returnData;
        uint256 gasUsed;
        string errorMessage;
    }

    struct BatchExecution {
        uint256 batchId;
        address executor;
        uint256 operationCount;
        uint256 successCount;
        uint256 totalGasUsed;
        uint256 timestamp;
        bool completed;
    }

    // State variables
    OmniCoin public omniCoin;
    mapping(uint256 => BatchExecution) public batchExecutions;
    mapping(address => uint256[]) public userBatches;
    mapping(address => bool) public authorizedExecutors;
    uint256 public batchCounter;
    uint256 public maxBatchSize;
    uint256 public maxGasPerOperation;

    // Events
    event BatchExecutionStarted(
        uint256 indexed batchId,
        address indexed executor,
        uint256 operationCount
    );
    event BatchExecutionCompleted(
        uint256 indexed batchId,
        uint256 successCount,
        uint256 totalGasUsed
    );
    event OperationExecuted(
        uint256 indexed batchId,
        uint256 operationIndex,
        bool success,
        uint256 gasUsed
    );
    event ExecutorAuthorized(address indexed executor);
    event ExecutorDeauthorized(address indexed executor);
    event MaxBatchSizeUpdated(uint256 newSize);
    event MaxGasPerOperationUpdated(uint256 newGas);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the batch transaction contract
     */
    function initialize(address _omniCoin) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        omniCoin = OmniCoin(_omniCoin);
        maxBatchSize = 50; // Maximum 50 operations per batch
        maxGasPerOperation = 500000; // 500k gas per operation max
        batchCounter = 0;
    }

    /**
     * @dev Execute a batch of operations
     */
    function executeBatch(
        BatchOperation[] calldata operations
    )
        external
        nonReentrant
        returns (uint256 batchId, BatchResult[] memory results)
    {
        require(operations.length > 0, "Empty batch");
        require(operations.length <= maxBatchSize, "Batch too large");

        batchId = ++batchCounter;
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
            timestamp: block.timestamp,
            completed: false
        });

        userBatches[msg.sender].push(batchId);

        emit BatchExecutionStarted(batchId, msg.sender, operations.length);

        // Execute each operation
        for (uint256 i = 0; i < operations.length; i++) {
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
                successCount++;
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
     * @dev Execute a single operation within a batch
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
        require(gasleft() >= maxGasPerOperation, "Insufficient gas");

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
     * @dev Perform the actual operation (external call for gas limiting)
     */
    function _performOperation(
        BatchOperation calldata operation
    ) external returns (bytes memory) {
        require(msg.sender == address(this), "Internal call only");

        if (operation.opType == TransactionType.TRANSFER) {
            return _executeTransfer(operation);
        } else if (operation.opType == TransactionType.APPROVE) {
            return _executeApprove(operation);
        } else if (operation.opType == TransactionType.STAKE) {
            return _executeStake(operation);
        } else if (operation.opType == TransactionType.UNSTAKE) {
            return _executeUnstake(operation);
        } else {
            // For other operation types, make direct call
            (bool success, bytes memory data) = operation.target.call{
                value: operation.value
            }(operation.data);
            require(success, "Operation failed");
            return data;
        }
    }

    /**
     * @dev Execute token transfer
     */
    function _executeTransfer(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(
            operation.data,
            (address, uint256)
        );
        require(omniCoin.transfer(recipient, amount), "Transfer failed");
        return abi.encode(true);
    }

    /**
     * @dev Execute token approval
     */
    function _executeApprove(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        (address spender, uint256 amount) = abi.decode(
            operation.data,
            (address, uint256)
        );
        require(omniCoin.approve(spender, amount), "Approval failed");
        return abi.encode(true);
    }

    /**
     * @dev Execute staking
     */
    function _executeStake(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        (uint256 amount, uint256 lockPeriod) = abi.decode(
            operation.data,
            (uint256, uint256)
        );
        omniCoin.stake(amount, lockPeriod);
        return abi.encode(true);
    }

    /**
     * @dev Execute unstaking
     */
    function _executeUnstake(
        BatchOperation calldata operation
    ) internal returns (bytes memory) {
        omniCoin.unstake();
        return abi.encode(true);
    }

    /**
     * @dev Create optimized batch for common wallet operations
     */
    function createTransferBatch(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external view returns (BatchOperation[] memory operations) {
        require(recipients.length == amounts.length, "Array length mismatch");
        require(recipients.length <= maxBatchSize, "Too many transfers");

        operations = new BatchOperation[](recipients.length);

        for (uint256 i = 0; i < recipients.length; i++) {
            operations[i] = BatchOperation({
                opType: TransactionType.TRANSFER,
                target: address(omniCoin),
                data: abi.encode(recipients[i], amounts[i]),
                value: 0,
                critical: false
            });
        }
    }

    /**
     * @dev Create optimized batch for NFT operations
     */
    function createNFTBatch(
        address nftContract,
        address[] calldata recipients,
        string[] calldata tokenURIs
    ) external view returns (BatchOperation[] memory operations) {
        require(recipients.length == tokenURIs.length, "Array length mismatch");
        require(recipients.length <= maxBatchSize, "Too many NFTs");

        operations = new BatchOperation[](recipients.length);

        for (uint256 i = 0; i < recipients.length; i++) {
            operations[i] = BatchOperation({
                opType: TransactionType.NFT_MINT,
                target: nftContract,
                data: abi.encodeWithSignature(
                    "mint(address,string)",
                    recipients[i],
                    tokenURIs[i]
                ),
                value: 0,
                critical: false
            });
        }
    }

    /**
     * @dev Get batch execution details
     */
    function getBatchExecution(
        uint256 batchId
    ) external view returns (BatchExecution memory) {
        return batchExecutions[batchId];
    }

    /**
     * @dev Get user's batch history
     */
    function getUserBatches(
        address user
    ) external view returns (uint256[] memory) {
        return userBatches[user];
    }

    /**
     * @dev Estimate gas for a batch operation
     */
    function estimateBatchGas(
        BatchOperation[] calldata operations
    ) external view returns (uint256 totalGasEstimate) {
        totalGasEstimate = 21000; // Base transaction gas

        for (uint256 i = 0; i < operations.length; i++) {
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
     * @dev Authorize an executor for advanced batch operations
     */
    function authorizeExecutor(address executor) external onlyOwner {
        authorizedExecutors[executor] = true;
        emit ExecutorAuthorized(executor);
    }

    /**
     * @dev Deauthorize an executor
     */
    function deauthorizeExecutor(address executor) external onlyOwner {
        authorizedExecutors[executor] = false;
        emit ExecutorDeauthorized(executor);
    }

    /**
     * @dev Update maximum batch size
     */
    function updateMaxBatchSize(uint256 newSize) external onlyOwner {
        require(newSize > 0 && newSize <= 100, "Invalid batch size");
        maxBatchSize = newSize;
        emit MaxBatchSizeUpdated(newSize);
    }

    /**
     * @dev Update maximum gas per operation
     */
    function updateMaxGasPerOperation(uint256 newGas) external onlyOwner {
        require(newGas >= 100000 && newGas <= 1000000, "Invalid gas limit");
        maxGasPerOperation = newGas;
        emit MaxGasPerOperationUpdated(newGas);
    }

    /**
     * @dev Emergency pause for batch operations
     */
    function emergencyPause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Resume batch operations
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
    }
}
