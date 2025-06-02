// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title OmniCoinMultisig
 * @dev 2-of-3 multisig contract for critical protocol operations
 */
contract OmniCoinMultisig is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    // State variables
    mapping(address => bool) public isOwner;
    address[] public owners;
    uint256 public requiredConfirmations;
    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmations;

    // Events
    event TransactionSubmitted(uint256 indexed txId, address indexed target, uint256 value, bytes data);
    event TransactionConfirmed(uint256 indexed txId, address indexed owner);
    event TransactionRevoked(uint256 indexed txId, address indexed owner);
    event TransactionExecuted(uint256 indexed txId, address indexed executor);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event RequiredConfirmationsChanged(uint256 requiredConfirmations);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract with initial owners
     */
    function initialize(address[] calldata _owners) public initializer {
        require(_owners.length == 3, "Must have exactly 3 owners");
        require(_owners[0] != address(0) && _owners[1] != address(0) && _owners[2] != address(0), "Invalid owner address");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(!isOwner[owner], "Duplicate owner");
            isOwner[owner] = true;
            owners.push(owner);
        }

        requiredConfirmations = 2;
    }

    /**
     * @dev Submits a new transaction
     */
    function submitTransaction(
        address _target,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (uint256 txId) {
        txId = transactions.length;
        transactions.push(
            Transaction({
                target: _target,
                value: _value,
                data: _data,
                executed: false,
                confirmations: 0
            })
        );
        emit TransactionSubmitted(txId, _target, _value, _data);
    }

    /**
     * @dev Confirms a transaction
     */
    function confirmTransaction(uint256 _txId) external onlyOwner {
        Transaction storage transaction = transactions[_txId];
        require(!transaction.executed, "Transaction already executed");
        require(!confirmations[_txId][msg.sender], "Transaction already confirmed");

        transaction.confirmations += 1;
        confirmations[_txId][msg.sender] = true;

        emit TransactionConfirmed(_txId, msg.sender);
    }

    /**
     * @dev Revokes a confirmation
     */
    function revokeConfirmation(uint256 _txId) external onlyOwner {
        Transaction storage transaction = transactions[_txId];
        require(!transaction.executed, "Transaction already executed");
        require(confirmations[_txId][msg.sender], "Transaction not confirmed");

        transaction.confirmations -= 1;
        confirmations[_txId][msg.sender] = false;

        emit TransactionRevoked(_txId, msg.sender);
    }

    /**
     * @dev Executes a confirmed transaction
     */
    function executeTransaction(uint256 _txId) external nonReentrant {
        Transaction storage transaction = transactions[_txId];
        require(!transaction.executed, "Transaction already executed");
        require(transaction.confirmations >= requiredConfirmations, "Not enough confirmations");

        transaction.executed = true;

        (bool success, ) = transaction.target.call{value: transaction.value}(transaction.data);
        require(success, "Transaction execution failed");

        emit TransactionExecuted(_txId, msg.sender);
    }

    /**
     * @dev Returns the number of transactions
     */
    function getTransactionCount() external view returns (uint256) {
        return transactions.length;
    }

    /**
     * @dev Returns transaction details
     */
    function getTransaction(uint256 _txId) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        bool executed,
        uint256 confirmations
    ) {
        Transaction storage transaction = transactions[_txId];
        return (
            transaction.target,
            transaction.value,
            transaction.data,
            transaction.executed,
            transaction.confirmations
        );
    }

    /**
     * @dev Returns whether an owner has confirmed a transaction
     */
    function isConfirmed(uint256 _txId, address _owner) external view returns (bool) {
        return confirmations[_txId][_owner];
    }

    /**
     * @dev Returns the list of owners
     */
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    /**
     * @dev Modifier to restrict function access to owners
     */
    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }
} 