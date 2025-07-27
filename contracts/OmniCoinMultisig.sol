// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OmniCoinMultisig is Ownable, ReentrancyGuard {
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct Transaction {
        uint256 id;
        address target;
        bytes data;
        uint256 value;
        uint256 requiredSignatures;
        uint256 signatureCount;
        bool executed;
        bool canceled;
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

    mapping(uint256 => Transaction) public transactions;
    mapping(address => Signer) public signers;
    address[] public activeSigners;

    uint256 public transactionCount;
    uint256 public minSignatures;
    uint256 public signerTimeout;
    
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
    
    // =============================================================================
    // EVENTS
    // =============================================================================

    event TransactionCreated(
        uint256 indexed transactionId,
        address target,
        bytes data,
        uint256 value,
        uint256 requiredSignatures
    );
    event TransactionSigned(uint256 indexed transactionId, address signer);
    event TransactionExecuted(uint256 indexed transactionId);
    event TransactionCancelledEvent(uint256 indexed transactionId);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event MinSignaturesUpdated(uint256 oldCount, uint256 newCount);
    event SignerTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    constructor(address initialOwner) Ownable(initialOwner) {
        minSignatures = 2;
        signerTimeout = 1 days;
    }

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

    function signTransaction(uint256 transactionId) external nonReentrant {
        Transaction storage transaction = transactions[transactionId];
        if (transaction.executed) revert TransactionAlreadyExecuted();
        if (transaction.canceled) revert TransactionCanceled();
        if (transaction.signed[msg.sender]) revert AlreadySigned();
        if (!signers[msg.sender].isActive) revert NotSigner();

        transaction.signed[msg.sender] = true;
        transaction.signatureCount++;

        emit TransactionSigned(transactionId, msg.sender);
    }

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

    function cancelTransaction(
        uint256 transactionId
    ) external onlyOwner nonReentrant {
        Transaction storage transaction = transactions[transactionId];
        if (transaction.executed) revert TransactionAlreadyExecuted();
        if (transaction.canceled) revert TransactionCanceled();

        transaction.canceled = true;

        emit TransactionCancelledEvent(transactionId);
    }

    function addSigner(address signer) external onlyOwner nonReentrant {
        if (signer == address(0)) revert ZeroTarget();
        if (signers[signer].isActive) revert AlreadyActiveSigner();

        signers[signer] = Signer({
            account: signer,
            isActive: true,
            lastActive: block.timestamp
        });

        activeSigners.push(signer);

        emit SignerAdded(signer);
    }

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

    function updateSignerActivity(address signer) external {
        if (!signers[signer].isActive) revert NotSigner();

        signers[signer].lastActive = block.timestamp;

        // Check for timeout
        if (block.timestamp > signers[signer].lastActive + signerTimeout) {
            removeSigner(signer);
        }
    }

    function setMinSignatures(uint256 _count) external onlyOwner {
        if (_count == 0) revert InvalidMinSignatures();
        if (_count > activeSigners.length) revert TooManySignatures();

        emit MinSignaturesUpdated(minSignatures, _count);
        minSignatures = _count;
    }

    function setSignerTimeout(uint256 _timeout) external onlyOwner {
        emit SignerTimeoutUpdated(signerTimeout, _timeout);
        signerTimeout = _timeout;
    }

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

    function hasSigned(
        uint256 transactionId,
        address signer
    ) external view returns (bool) {
        return transactions[transactionId].signed[signer];
    }

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

    function getActiveSigners() external view returns (address[] memory) {
        return activeSigners;
    }

    function isActiveSigner(address signer) external view returns (bool) {
        return signers[signer].isActive;
    }

    function isApproved(
        address /* from */,
        address /* to */,
        uint256 amount
    ) external view returns (bool) {
        // For now, return true for small amounts, false for large amounts requiring multisig
        // In a real implementation, this would check if a specific transaction has been approved
        return amount < 1000 * 10 ** 18; // Amounts under 1000 tokens don't need multisig approval
    }
}
