// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinMultisig
 * @author OmniCoin Development Team
 * @notice Multi-signature wallet for secure transaction management
 * @dev Implements a multi-signature wallet with time-based signer activity tracking
 */
contract OmniCoinMultisig is RegistryAware, Ownable, ReentrancyGuard {
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct Transaction {
        address target;
        bool executed;
        bool canceled;
        uint256 id;
        uint256 value;
        uint256 requiredSignatures;
        uint256 signatureCount;
        bytes data;
        mapping(address => bool) signed;
    }

    struct Signer {
        address account;
        bool isActive;
        uint256 lastActive;
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice Mapping from transaction ID to transaction data
    mapping(uint256 => Transaction) public transactions;
    /// @notice Mapping from address to signer data
    mapping(address => Signer) public signers;
    /// @notice Array of active signer addresses
    address[] public activeSigners;

    /// @notice Total number of transactions created
    uint256 public transactionCount;
    /// @notice Minimum number of signatures required
    uint256 public minSignatures;
    /// @notice Timeout period for signer inactivity
    uint256 public signerTimeout;
    
    // =============================================================================
    // EVENTS
    // =============================================================================

    /**
     * @notice Emitted when a transaction is created
     * @param transactionId The transaction ID
     * @param target The target address
     * @param data The transaction data
     * @param value The ETH value
     * @param requiredSignatures Number of signatures required
     */
    event TransactionCreated(
        uint256 indexed transactionId,
        address indexed target,
        bytes data,
        uint256 indexed value,
        uint256 requiredSignatures
    );
    
    /**
     * @notice Emitted when a transaction is signed
     * @param transactionId The transaction ID
     * @param signer The signer address
     */
    event TransactionSigned(uint256 indexed transactionId, address indexed signer);
    
    /**
     * @notice Emitted when a transaction is executed
     * @param transactionId The transaction ID
     */
    event TransactionExecuted(uint256 indexed transactionId);
    
    /**
     * @notice Emitted when a transaction is cancelled
     * @param transactionId The transaction ID
     */
    event TransactionCancelledEvent(uint256 indexed transactionId);
    
    /**
     * @notice Emitted when a signer is added
     * @param signer The signer address
     */
    event SignerAdded(address indexed signer);
    
    /**
     * @notice Emitted when a signer is removed
     * @param signer The signer address
     */
    event SignerRemoved(address indexed signer);
    
    /**
     * @notice Emitted when minimum signatures is updated
     * @param oldCount Previous count
     * @param newCount New count
     */
    event MinSignaturesUpdated(uint256 indexed oldCount, uint256 indexed newCount);
    
    /**
     * @notice Emitted when signer timeout is updated
     * @param oldTimeout Previous timeout
     * @param newTimeout New timeout
     */
    event SignerTimeoutUpdated(uint256 indexed oldTimeout, uint256 indexed newTimeout);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error ZeroTarget();
    error InsufficientSignatures();
    error TooManySignatures();
    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TransactionCanceled();
    error AlreadySigned();
    error NotSigner();
    error AlreadyActiveSigner();
    error InactiveSigners();
    error TransactionExecutionFailed();
    error NotOwnerOrSigner();
    error InvalidMinSignatures();
    error InvalidTimeout();

    /**
     * @notice Initialize the multisig contract
     * @param _registry Registry contract address
     * @param initialOwner Initial owner address
     */
    constructor(address _registry, address initialOwner) 
        RegistryAware(_registry) 
        Ownable(initialOwner) {
        minSignatures = 2;
        signerTimeout = 1 days;
    }

    /**
     * @notice Create a new transaction
     * @param target Target address
     * @param data Transaction data
     * @param value ETH value to send
     * @param requiredSignatures Number of signatures required
     * @return The transaction ID
     */
    function createTransaction(
        address target,
        bytes memory data,
        uint256 value,
        uint256 requiredSignatures
    ) external onlyOwner nonReentrant returns (uint256) {
        if (target == address(0)) revert ZeroTarget();
        if (requiredSignatures < minSignatures) revert InsufficientSignatures();
        if (requiredSignatures > activeSigners.length) revert TooManySignatures();

        uint256 transactionId = transactionCount;
        ++transactionCount;

        Transaction storage transaction = transactions[transactionId];
        transaction.id = transactionId;
        transaction.target = target;
        transaction.data = data;
        transaction.value = value;
        transaction.requiredSignatures = requiredSignatures;

        emit TransactionCreated(
            transactionId,
            target,
            data,
            value,
            requiredSignatures
        );

        return transactionId;
    }

    /**
     * @notice Sign a transaction
     * @param transactionId The transaction ID to sign
     */
    function signTransaction(uint256 transactionId) external nonReentrant {
        Transaction storage transaction = transactions[transactionId];
        if (transaction.executed) revert TransactionAlreadyExecuted();
        if (transaction.canceled) revert TransactionCanceled();
        if (transaction.signed[msg.sender]) revert AlreadySigned();
        if (!signers[msg.sender].isActive) revert NotSigner();

        transaction.signed[msg.sender] = true;
        ++transaction.signatureCount;

        emit TransactionSigned(transactionId, msg.sender);
    }

    /**
     * @notice Execute a transaction after sufficient signatures
     * @param transactionId The transaction ID to execute
     */
    function executeTransaction(uint256 transactionId) external nonReentrant {
        Transaction storage transaction = transactions[transactionId];
        if (transaction.executed) revert TransactionAlreadyExecuted();
        if (transaction.canceled) revert TransactionCanceled();
        if (transaction.signatureCount < transaction.requiredSignatures) 
            revert InsufficientSignatures();

        transaction.executed = true;

        (bool success, ) = transaction.target.call{value: transaction.value}(
            transaction.data
        );
        if (!success) revert TransactionExecutionFailed();

        emit TransactionExecuted(transactionId);
    }

    /**
     * @notice Cancel a transaction
     * @param transactionId The transaction ID to cancel
     */
    function cancelTransaction(
        uint256 transactionId
    ) external onlyOwner nonReentrant {
        Transaction storage transaction = transactions[transactionId];
        if (transaction.executed) revert TransactionAlreadyExecuted();
        if (transaction.canceled) revert TransactionCanceled();

        transaction.canceled = true;

        emit TransactionCancelledEvent(transactionId);
    }

    /**
     * @notice Add a new signer to the multisig
     * @param signer The signer address to add
     */
    function addSigner(address signer) external onlyOwner nonReentrant {
        if (signer == address(0)) revert ZeroTarget();
        if (signers[signer].isActive) revert AlreadyActiveSigner();

        signers[signer] = Signer({
            account: signer,
            isActive: true,
            lastActive: block.timestamp // solhint-disable-line not-rely-on-time
        });

        activeSigners.push(signer);

        emit SignerAdded(signer);
    }

    /**
     * @notice Update signer activity timestamp
     * @param signer The signer address to update
     */
    function updateSignerActivity(address signer) external {
        if (!signers[signer].isActive) revert NotSigner();

        signers[signer].lastActive = block.timestamp; // solhint-disable-line not-rely-on-time

        // Check for timeout
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > signers[signer].lastActive + signerTimeout) {
            removeSigner(signer);
        }
    }

    /**
     * @notice Set minimum signatures required
     * @param _count The new minimum signature count
     */
    function setMinSignatures(uint256 _count) external onlyOwner {
        if (_count == 0) revert InvalidMinSignatures();
        if (_count > activeSigners.length) revert TooManySignatures();

        emit MinSignaturesUpdated(minSignatures, _count);
        minSignatures = _count;
    }

    /**
     * @notice Set signer timeout period
     * @param _timeout The new timeout period in seconds
     */
    function setSignerTimeout(uint256 _timeout) external onlyOwner {
        emit SignerTimeoutUpdated(signerTimeout, _timeout);
        signerTimeout = _timeout;
    }

    /**
     * @notice Remove a signer from the multisig
     * @param signer The signer address to remove
     */
    function removeSigner(address signer) public onlyOwner nonReentrant {
        if (!signers[signer].isActive) revert NotSigner();

        signers[signer].isActive = false;

        for (uint256 i = 0; i < activeSigners.length; ++i) {
            if (activeSigners[i] == signer) {
                activeSigners[i] = activeSigners[activeSigners.length - 1];
                activeSigners.pop();
                break;
            }
        }

        emit SignerRemoved(signer);
    }

    /**
     * @notice Get transaction details
     * @param transactionId The transaction ID
     * @return id The transaction ID
     * @return target The target address
     * @return data The transaction data
     * @return value The ETH value
     * @return requiredSignatures Number of signatures required
     * @return signatureCount Current number of signatures
     * @return executed Whether transaction was executed
     * @return canceled Whether transaction was canceled
     */
    function getTransaction(
        uint256 transactionId
    )
        external
        view
        returns (
            uint256 id,
            address target,
            bytes memory data,
            uint256 value,
            uint256 requiredSignatures,
            uint256 signatureCount,
            bool executed,
            bool canceled
        )
    {
        Transaction storage transaction = transactions[transactionId];
        return (
            transaction.id,
            transaction.target,
            transaction.data,
            transaction.value,
            transaction.requiredSignatures,
            transaction.signatureCount,
            transaction.executed,
            transaction.canceled
        );
    }

    /**
     * @notice Check if an address has signed a transaction
     * @param transactionId The transaction ID
     * @param signer The signer address to check
     * @return Whether the address has signed
     */
    function hasSigned(
        uint256 transactionId,
        address signer
    ) external view returns (bool) {
        return transactions[transactionId].signed[signer];
    }

    /**
     * @notice Get signer details
     * @param account The signer address
     * @return signer The signer address
     * @return isActive Whether signer is active
     * @return lastActive Last activity timestamp
     */
    function getSigner(
        address account
    )
        external
        view
        returns (address signer, bool isActive, uint256 lastActive)
    {
        Signer storage s = signers[account];
        return (s.account, s.isActive, s.lastActive);
    }

    /**
     * @notice Get all active signers
     * @return Array of active signer addresses
     */
    function getActiveSigners() external view returns (address[] memory) {
        return activeSigners;
    }

    /**
     * @notice Check if an address is an active signer
     * @param signer The address to check
     * @return Whether the address is an active signer
     */
    function isActiveSigner(address signer) external view returns (bool) {
        return signers[signer].isActive;
    }

    /**
     * @notice Check if a transfer is approved
     * @dev Simplified implementation - small amounts auto-approved, large amounts need explicit multisig
     * @param from Address sending the transfer (unused in current implementation)
     * @param to Address receiving the transfer (unused in current implementation)
     * @param amount Transfer amount
     * @return Whether the transfer is approved
     */
    function isApproved(
        address /* from */,
        address /* to */,
        uint256 amount
    ) external view returns (bool) {
        // For now, return true for small amounts, false for large amounts requiring multisig
        // In a real implementation, this would check if a specific transaction has been approved
        return amount < 1000 * 10 ** 6; // Amounts under 1000 tokens (6 decimals) don't need multisig approval
    }
}
