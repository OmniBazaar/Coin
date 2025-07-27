// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OmniCoin} from "./OmniCoin.sol";

/**
 * @title OmniCoinAccount
 * @author OmniCoin Development Team
 * @notice ERC-4337 compliant account abstraction implementation
 * @dev Provides account abstraction with payment integration for OmniCoin ecosystem
 */
contract OmniCoinAccount is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // =============================================================================
    // STRUCTS
    // =============================================================================
    
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

    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
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
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Nonce tracking for user operations
    mapping(address => uint256) public nonces;
    
    /// @notice Account deployment status
    mapping(address => bool) public isDeployed;
    
    /// @notice Account initialization code storage
    mapping(address => bytes) public initCode;
    
    /// @notice Privacy mode status for accounts
    mapping(address => bool) public privacyEnabled;
    
    /// @notice Staking amounts per account
    mapping(address => uint256) public stakingAmount;
    
    /// @notice Reputation scores per account
    mapping(address => uint256) public reputationScore;
    
    /// @notice Gas limit for entry point operations
    uint256 public entryPointGasLimit;
    
    /// @notice Entry point contract address
    address public entryPoint;
    
    /// @notice OmniCoin token contract
    OmniCoin public omniCoin;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when an account is deployed
     * @param account Address of the deployed account
     * @param initCode Initialization code used
     */
    event AccountDeployed(address indexed account, bytes initCode);
    
    /**
     * @notice Emitted when an operation is executed
     * @param account Account that executed the operation
     * @param nonce Operation nonce
     * @param success Whether the operation succeeded
     */
    event OperationExecuted(
        address indexed account,
        uint256 indexed nonce,
        bool indexed success
    );
    
    /**
     * @notice Emitted when entry point is updated
     * @param newEntryPoint New entry point address
     */
    event EntryPointUpdated(address indexed newEntryPoint);
    
    /**
     * @notice Emitted when gas limit is updated
     * @param newGasLimit New gas limit value
     */
    event GasLimitUpdated(uint256 indexed newGasLimit);
    
    /**
     * @notice Emitted when privacy mode is toggled
     * @param account Account address
     * @param enabled Whether privacy is enabled
     */
    event PrivacyToggled(address indexed account, bool enabled);
    
    /**
     * @notice Emitted when staking amount is updated
     * @param account Account address
     * @param amount New staking amount
     */
    event StakingUpdated(address indexed account, uint256 amount);
    
    /**
     * @notice Emitted when reputation score is updated
     * @param account Account address
     * @param score New reputation score
     */
    event ReputationUpdated(address indexed account, uint256 score);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the account contract
     * @dev Called once during deployment
     * @param _entryPoint Entry point contract address
     * @param _omniCoin OmniCoin token contract address
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
     * @notice Validate a user operation for ERC-4337 compliance
     * @dev Called by the entry point to validate user operations
     * @param userOp User operation to validate
     * @param userOpHash Hash of the user operation
     * @param missingAccountFunds Funds needed for the operation
     * @return validationData Validation result (0 for success)
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
        ++nonces[userOp.sender];

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
