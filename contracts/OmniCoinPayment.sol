// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinAccount.sol";

/**
 * @title OmniCoinPayment
 * @dev Handles payment processing for OmniCoin with privacy and staking features
 */
contract OmniCoinPayment is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct Payment {
        address sender;
        address receiver;
        uint256 amount;
        bool privacyEnabled;
        uint256 timestamp;
        bool stakingEnabled;
        uint256 stakeAmount;
        bool completed;
    }

    // State variables
    mapping(bytes32 => Payment) public payments;
    mapping(address => bytes32[]) public userPayments;
    mapping(address => uint256) public totalPayments;
    mapping(address => uint256) public totalReceived;
    
    OmniCoin public omniCoin;
    OmniCoinAccount public omniCoinAccount;
    uint256 public minStakeAmount;
    uint256 public maxPrivacyFee;

    // Events
    event PaymentProcessed(
        bytes32 indexed paymentId,
        address indexed sender,
        address indexed receiver,
        uint256 amount,
        bool privacyEnabled,
        bool stakingEnabled,
        uint256 stakeAmount
    );
    event PaymentCancelled(bytes32 indexed paymentId);
    event PrivacyToggled(bytes32 indexed paymentId, bool enabled);
    event StakingToggled(bytes32 indexed paymentId, bool enabled, uint256 amount);
    event MinStakeAmountUpdated(uint256 newAmount);
    event MaxPrivacyFeeUpdated(uint256 newFee);

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
        uint256 _minStakeAmount,
        uint256 _maxPrivacyFee
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        omniCoinAccount = OmniCoinAccount(_omniCoinAccount);
        minStakeAmount = _minStakeAmount;
        maxPrivacyFee = _maxPrivacyFee;
    }

    /**
     * @dev Process a payment
     */
    function processPayment(
        address _receiver,
        uint256 _amount,
        bool _privacyEnabled,
        bool _stakingEnabled,
        uint256 _stakeAmount
    ) external nonReentrant returns (bytes32 paymentId) {
        require(_amount > 0, "Amount must be greater than 0");
        require(_receiver != address(0), "Invalid receiver");
        require(_receiver != msg.sender, "Cannot send to self");

        if (_stakingEnabled) {
            require(_stakeAmount >= minStakeAmount, "Stake amount too low");
            require(
                omniCoin.transferFrom(msg.sender, address(this), _stakeAmount),
                "Stake transfer failed"
            );
        }

        if (_privacyEnabled) {
            require(
                omniCoin.transferFrom(msg.sender, address(this), maxPrivacyFee),
                "Privacy fee transfer failed"
            );
        }

        require(
            omniCoin.transferFrom(msg.sender, _receiver, _amount),
            "Payment transfer failed"
        );

        paymentId = keccak256(
            abi.encodePacked(
                msg.sender,
                _receiver,
                _amount,
                block.timestamp
            )
        );

        payments[paymentId] = Payment({
            sender: msg.sender,
            receiver: _receiver,
            amount: _amount,
            privacyEnabled: _privacyEnabled,
            timestamp: block.timestamp,
            stakingEnabled: _stakingEnabled,
            stakeAmount: _stakeAmount,
            completed: true
        });

        userPayments[msg.sender].push(paymentId);
        userPayments[_receiver].push(paymentId);
        totalPayments[msg.sender] += _amount;
        totalReceived[_receiver] += _amount;

        emit PaymentProcessed(
            paymentId,
            msg.sender,
            _receiver,
            _amount,
            _privacyEnabled,
            _stakingEnabled,
            _stakeAmount
        );
    }

    /**
     * @dev Cancel a payment
     */
    function cancelPayment(bytes32 _paymentId) external nonReentrant {
        Payment storage payment = payments[_paymentId];
        require(payment.sender == msg.sender, "Not payment sender");
        require(!payment.completed, "Payment already completed");

        if (payment.stakingEnabled) {
            require(
                omniCoin.transfer(msg.sender, payment.stakeAmount),
                "Stake return failed"
            );
        }

        if (payment.privacyEnabled) {
            require(
                omniCoin.transfer(msg.sender, maxPrivacyFee),
                "Privacy fee return failed"
            );
        }

        payment.completed = false;
        emit PaymentCancelled(_paymentId);
    }

    /**
     * @dev Toggle privacy for a payment
     */
    function togglePrivacy(bytes32 _paymentId) external {
        Payment storage payment = payments[_paymentId];
        require(payment.sender == msg.sender, "Not payment sender");
        require(!payment.completed, "Payment already completed");

        if (!payment.privacyEnabled) {
            require(
                omniCoin.transferFrom(msg.sender, address(this), maxPrivacyFee),
                "Privacy fee transfer failed"
            );
        } else {
            require(
                omniCoin.transfer(msg.sender, maxPrivacyFee),
                "Privacy fee return failed"
            );
        }

        payment.privacyEnabled = !payment.privacyEnabled;
        emit PrivacyToggled(_paymentId, payment.privacyEnabled);
    }

    /**
     * @dev Toggle staking for a payment
     */
    function toggleStaking(bytes32 _paymentId, uint256 _stakeAmount) external {
        Payment storage payment = payments[_paymentId];
        require(payment.sender == msg.sender, "Not payment sender");
        require(!payment.completed, "Payment already completed");

        if (!payment.stakingEnabled) {
            require(_stakeAmount >= minStakeAmount, "Stake amount too low");
            require(
                omniCoin.transferFrom(msg.sender, address(this), _stakeAmount),
                "Stake transfer failed"
            );
        } else {
            require(
                omniCoin.transfer(msg.sender, payment.stakeAmount),
                "Stake return failed"
            );
        }

        payment.stakingEnabled = !payment.stakingEnabled;
        payment.stakeAmount = _stakeAmount;
        emit StakingToggled(_paymentId, payment.stakingEnabled, _stakeAmount);
    }

    /**
     * @dev Get payment details
     */
    function getPayment(bytes32 _paymentId) external view returns (
        address sender,
        address receiver,
        uint256 amount,
        bool privacyEnabled,
        uint256 timestamp,
        bool stakingEnabled,
        uint256 stakeAmount,
        bool completed
    ) {
        Payment storage payment = payments[_paymentId];
        return (
            payment.sender,
            payment.receiver,
            payment.amount,
            payment.privacyEnabled,
            payment.timestamp,
            payment.stakingEnabled,
            payment.stakeAmount,
            payment.completed
        );
    }

    /**
     * @dev Get user's payment history
     */
    function getUserPayments(address _user) external view returns (bytes32[] memory) {
        return userPayments[_user];
    }

    /**
     * @dev Get total payments and received amounts for an address
     */
    function getPaymentStats(address _user) external view returns (
        uint256 totalSent,
        uint256 totalReceived
    ) {
        return (totalPayments[_user], totalReceived[_user]);
    }

    /**
     * @dev Update minimum stake amount
     */
    function updateMinStakeAmount(uint256 _newAmount) external onlyOwner {
        minStakeAmount = _newAmount;
        emit MinStakeAmountUpdated(_newAmount);
    }

    /**
     * @dev Update maximum privacy fee
     */
    function updateMaxPrivacyFee(uint256 _newFee) external onlyOwner {
        maxPrivacyFee = _newFee;
        emit MaxPrivacyFeeUpdated(_newFee);
    }
} 