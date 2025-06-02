// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinAccount.sol";

/**
 * @title OmniCoinPrivacy
 * @dev Handles privacy features for OmniCoin transactions
 */
contract OmniCoinPrivacy is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct PrivacySettings {
        bool enabled;
        uint256 privacyLevel;
        uint256 maxAmount;
        uint256 cooldownPeriod;
        uint256 lastTransaction;
    }

    struct PrivacyTransaction {
        bytes32 transactionId;
        address sender;
        address receiver;
        uint256 amount;
        uint256 timestamp;
        uint256 privacyLevel;
        bool completed;
    }

    // State variables
    mapping(address => PrivacySettings) public privacySettings;
    mapping(bytes32 => PrivacyTransaction) public privacyTransactions;
    mapping(address => bytes32[]) public userPrivacyTransactions;
    
    OmniCoin public omniCoin;
    OmniCoinAccount public omniCoinAccount;
    uint256 public basePrivacyFee;
    uint256 public maxPrivacyLevel;
    uint256 public minCooldownPeriod;

    // Events
    event PrivacySettingsUpdated(
        address indexed user,
        bool enabled,
        uint256 privacyLevel,
        uint256 maxAmount,
        uint256 cooldownPeriod
    );
    event PrivacyTransactionCreated(
        bytes32 indexed transactionId,
        address indexed sender,
        address indexed receiver,
        uint256 amount,
        uint256 privacyLevel
    );
    event PrivacyTransactionCompleted(bytes32 indexed transactionId);
    event PrivacyFeeUpdated(uint256 newFee);
    event MaxPrivacyLevelUpdated(uint256 newLevel);
    event MinCooldownPeriodUpdated(uint256 newPeriod);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _omniCoin,
        address _omniCoinAccount,
        uint256 _basePrivacyFee,
        uint256 _maxPrivacyLevel,
        uint256 _minCooldownPeriod
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        omniCoinAccount = OmniCoinAccount(_omniCoinAccount);
        basePrivacyFee = _basePrivacyFee;
        maxPrivacyLevel = _maxPrivacyLevel;
        minCooldownPeriod = _minCooldownPeriod;
    }

    /**
     * @dev Update privacy settings for a user
     */
    function updatePrivacySettings(
        bool _enabled,
        uint256 _privacyLevel,
        uint256 _maxAmount,
        uint256 _cooldownPeriod
    ) external {
        require(_privacyLevel <= maxPrivacyLevel, "Privacy level too high");
        require(_cooldownPeriod >= minCooldownPeriod, "Cooldown period too short");

        privacySettings[msg.sender] = PrivacySettings({
            enabled: _enabled,
            privacyLevel: _privacyLevel,
            maxAmount: _maxAmount,
            cooldownPeriod: _cooldownPeriod,
            lastTransaction: privacySettings[msg.sender].lastTransaction
        });

        emit PrivacySettingsUpdated(
            msg.sender,
            _enabled,
            _privacyLevel,
            _maxAmount,
            _cooldownPeriod
        );
    }

    /**
     * @dev Create a private transaction
     */
    function createPrivateTransaction(
        address _receiver,
        uint256 _amount,
        uint256 _privacyLevel
    ) external nonReentrant returns (bytes32 transactionId) {
        PrivacySettings storage settings = privacySettings[msg.sender];
        require(settings.enabled, "Privacy not enabled");
        require(_privacyLevel <= settings.privacyLevel, "Privacy level too high");
        require(_amount <= settings.maxAmount, "Amount exceeds maximum");
        require(
            block.timestamp >= settings.lastTransaction + settings.cooldownPeriod,
            "Cooldown period not elapsed"
        );

        uint256 privacyFee = calculatePrivacyFee(_privacyLevel);
        require(
            omniCoin.transferFrom(msg.sender, address(this), privacyFee),
            "Privacy fee transfer failed"
        );

        require(
            omniCoin.transferFrom(msg.sender, _receiver, _amount),
            "Transaction transfer failed"
        );

        transactionId = keccak256(
            abi.encodePacked(
                msg.sender,
                _receiver,
                _amount,
                block.timestamp
            )
        );

        privacyTransactions[transactionId] = PrivacyTransaction({
            transactionId: transactionId,
            sender: msg.sender,
            receiver: _receiver,
            amount: _amount,
            timestamp: block.timestamp,
            privacyLevel: _privacyLevel,
            completed: true
        });

        userPrivacyTransactions[msg.sender].push(transactionId);
        userPrivacyTransactions[_receiver].push(transactionId);
        settings.lastTransaction = block.timestamp;

        emit PrivacyTransactionCreated(
            transactionId,
            msg.sender,
            _receiver,
            _amount,
            _privacyLevel
        );
    }

    /**
     * @dev Calculate privacy fee based on level
     */
    function calculatePrivacyFee(uint256 _privacyLevel) public view returns (uint256) {
        return basePrivacyFee * (_privacyLevel + 1);
    }

    /**
     * @dev Get privacy settings for a user
     */
    function getPrivacySettings(address _user) external view returns (
        bool enabled,
        uint256 privacyLevel,
        uint256 maxAmount,
        uint256 cooldownPeriod,
        uint256 lastTransaction
    ) {
        PrivacySettings storage settings = privacySettings[_user];
        return (
            settings.enabled,
            settings.privacyLevel,
            settings.maxAmount,
            settings.cooldownPeriod,
            settings.lastTransaction
        );
    }

    /**
     * @dev Get privacy transaction details
     */
    function getPrivacyTransaction(bytes32 _transactionId) external view returns (
        address sender,
        address receiver,
        uint256 amount,
        uint256 timestamp,
        uint256 privacyLevel,
        bool completed
    ) {
        PrivacyTransaction storage transaction = privacyTransactions[_transactionId];
        return (
            transaction.sender,
            transaction.receiver,
            transaction.amount,
            transaction.timestamp,
            transaction.privacyLevel,
            transaction.completed
        );
    }

    /**
     * @dev Get user's privacy transaction history
     */
    function getUserPrivacyTransactions(address _user) external view returns (bytes32[] memory) {
        return userPrivacyTransactions[_user];
    }

    /**
     * @dev Update base privacy fee
     */
    function updateBasePrivacyFee(uint256 _newFee) external onlyOwner {
        basePrivacyFee = _newFee;
        emit PrivacyFeeUpdated(_newFee);
    }

    /**
     * @dev Update maximum privacy level
     */
    function updateMaxPrivacyLevel(uint256 _newLevel) external onlyOwner {
        maxPrivacyLevel = _newLevel;
        emit MaxPrivacyLevelUpdated(_newLevel);
    }

    /**
     * @dev Update minimum cooldown period
     */
    function updateMinCooldownPeriod(uint256 _newPeriod) external onlyOwner {
        minCooldownPeriod = _newPeriod;
        emit MinCooldownPeriodUpdated(_newPeriod);
    }
} 