// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OmniCoin} from "./OmniCoin.sol";

/**
 * @title OmniCoinAccount
 * @dev ERC-4337 compliant account abstraction implementation with payment integration
 */
contract OmniCoinAccount is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Custom errors
    error NotEntryPoint();
    error AccountAlreadyDeployed();
    error InvalidSignature();
    error InvalidNonce();
    error AccountNotDeployed();
    error InvalidAddress();
    error AmountMustBePositive();
    error TransferFailed();
    error NotWhitelisted();
    error InvalidRecipient();

    // Structs
    struct UserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        uint256 callGasLimit;
        uint256 verificationGasLimit;
        uint256 preVerificationGas;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        bytes paymasterAndData;
        bytes signature;
    }

    struct ExecutionResult {
        bool success;
        bytes returnData;
    }

    // State variables
    mapping(address => uint256) public nonces;
    mapping(address => bool) public isDeployed;
    mapping(address => bytes) public initCode;
    mapping(address => bool) public privacyEnabled;
    mapping(address => uint256) public stakingAmount;
    mapping(address => uint256) public reputationScore;
    uint256 public entryPointGasLimit;
    address public entryPoint;
    OmniCoin public omniCoin;

    // Events
    event AccountDeployed(address indexed account, bytes initCode);
    event OperationExecuted(
        address indexed account,
        uint256 indexed nonce,
        bool success
    );
    event EntryPointUpdated(address indexed newEntryPoint);
    event GasLimitUpdated(uint256 newGasLimit);
    event PrivacyToggled(address indexed account, bool enabled);
    event StakingUpdated(address indexed account, uint256 amount);
    event ReputationUpdated(address indexed account, uint256 score);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _entryPoint,
        address _omniCoin
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        entryPoint = _entryPoint;
        omniCoin = OmniCoin(_omniCoin);
        entryPointGasLimit = 1000000; // Default gas limit
    }

    /**
     * @dev Validates a user operation
     */
    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData) {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        if (isDeployed[userOp.sender] && userOp.initCode.length > 0)
            revert AccountAlreadyDeployed();

        // Validate signature
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address recovered = hash.recover(userOp.signature);
        if (recovered != userOp.sender) revert InvalidSignature();

        // Validate nonce
        if (nonces[userOp.sender] != userOp.nonce) revert InvalidNonce();
        nonces[userOp.sender]++;

        // Handle account deployment
        if (!isDeployed[userOp.sender] && userOp.initCode.length > 0) {
            initCode[userOp.sender] = userOp.initCode;
            isDeployed[userOp.sender] = true;
            emit AccountDeployed(userOp.sender, userOp.initCode);
        }

        // Handle missing funds
        if (missingAccountFunds > 0) {
            // Implementation would handle funding logic
        }

        return 0; // Validation successful
    }

    /**
     * @dev Executes a user operation
     */
    function executeUserOp(
        UserOperation calldata userOp
    ) external nonReentrant returns (ExecutionResult memory result) {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        if (!isDeployed[userOp.sender]) revert AccountNotDeployed();

        // Execute the operation
        (bool success, bytes memory returnData) = userOp.sender.call{
            gas: userOp.callGasLimit
        }(userOp.callData);

        result.success = success;
        result.returnData = returnData;

        emit OperationExecuted(userOp.sender, userOp.nonce, success);
    }

    /**
     * @dev Toggle privacy for an account
     */
    function togglePrivacy() external {
        privacyEnabled[msg.sender] = !privacyEnabled[msg.sender];
        emit PrivacyToggled(msg.sender, privacyEnabled[msg.sender]);
    }

    /**
     * @dev Update staking amount for an account
     */
    function updateStaking(uint256 amount) external nonReentrant {
        if (amount > stakingAmount[msg.sender]) {
            uint256 additionalStake = amount - stakingAmount[msg.sender];
            if (!omniCoin.transferFrom(
                    msg.sender,
                    address(this),
                    additionalStake
                )) revert TransferFailed();
        } else if (amount < stakingAmount[msg.sender]) {
            uint256 returnStake = stakingAmount[msg.sender] - amount;
            // Update state before transfer to prevent reentrancy
            stakingAmount[msg.sender] = amount;
            if (!omniCoin.transfer(msg.sender, returnStake))
                revert TransferFailed();
        } else {
            stakingAmount[msg.sender] = amount;
        }
        emit StakingUpdated(msg.sender, amount);
    }

    /**
     * @dev Update reputation score for an account
     */
    function updateReputation(uint256 score) external {
        if (msg.sender != owner()) revert NotWhitelisted();
        reputationScore[msg.sender] = score;
        emit ReputationUpdated(msg.sender, score);
    }

    /**
     * @dev Updates the entry point address
     */
    function updateEntryPoint(address _newEntryPoint) external onlyOwner {
        if (_newEntryPoint == address(0)) revert InvalidAddress();
        entryPoint = _newEntryPoint;
        emit EntryPointUpdated(_newEntryPoint);
    }

    /**
     * @dev Updates the gas limit
     */
    function updateGasLimit(uint256 _newGasLimit) external onlyOwner {
        entryPointGasLimit = _newGasLimit;
        emit GasLimitUpdated(_newGasLimit);
    }

    /**
     * @dev Returns account status and settings
     */
    function getAccountStatus(
        address _account
    )
        external
        view
        returns (
            bool deployed,
            uint256 nonce,
            bytes memory init,
            bool privacy,
            uint256 stake,
            uint256 reputation
        )
    {
        return (
            isDeployed[_account],
            nonces[_account],
            initCode[_account],
            privacyEnabled[_account],
            stakingAmount[_account],
            reputationScore[_account]
        );
    }

    /**
     * @dev Returns the current nonce for an account
     */
    function getNonce(address _account) external view returns (uint256) {
        return nonces[_account];
    }

    /**
     * @dev Returns whether an account is deployed
     */
    function isAccountDeployed(address _account) external view returns (bool) {
        return isDeployed[_account];
    }
}
