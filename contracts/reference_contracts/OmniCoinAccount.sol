// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OmniCoin} from "./OmniCoin.sol";
// import {PrivateOmniCoin} from "./PrivateOmniCoin.sol"; // Unused - commented for future use
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OmniCoinRegistry} from "./OmniCoinRegistry.sol";

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
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Nonce tracking for user operations
    mapping(address => uint256) public nonces;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Registry contract for dynamic lookups
    OmniCoinRegistry public registry;
    
    /// @notice Account deployment status
    mapping(address => bool) public isDeployed;
    
    /// @notice Account initialization code storage
    mapping(address => bytes) public initCode;
    
    /// @notice Privacy mode status for accounts
    mapping(address => bool) public privacyEnabled;
    
    /// @notice Staking amounts per account (public OmniCoin)
    mapping(address => uint256) public stakingAmount;
    
    /// @notice Private staking amounts per account (PrivateOmniCoin)
    mapping(address => uint256) public privateStakingAmount;
    
    /// @notice Reputation scores per account
    mapping(address => uint256) public reputationScore;
    
    /// @notice Gas limit for entry point operations
    uint256 public entryPointGasLimit;
    
    /// @notice Entry point contract address
    address public entryPoint;
    
    /// @notice OmniCoin token contract
    OmniCoin public omniCoin;
    
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
    event PrivacyToggled(address indexed account, bool indexed enabled);
    
    /**
     * @notice Emitted when staking amount is updated
     * @param account Account address
     * @param amount New staking amount
     */
    event StakingUpdated(address indexed account, uint256 indexed amount);
    
    /**
     * @notice Emitted when reputation score is updated
     * @param account Account address
     * @param score New reputation score
     */
    event ReputationUpdated(address indexed account, uint256 indexed score);

    /**
     * @notice Constructor for the upgradeable contract
     * @dev Disables initializers to prevent implementation contract initialization
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Get contract address from registry
     * @param identifier The contract identifier
     * @return The contract address
     */
    function _getContract(bytes32 identifier) internal view returns (address) {
        return registry.getContract(identifier);
    }

    /**
     * @notice Initialize the account contract
     * @dev Called once during deployment
     * @param _registry Registry contract address
     * @param _entryPoint Entry point contract address
     * @param _omniCoin OmniCoin token contract address (deprecated, use registry)
     */
    function initialize(
        address _registry,
        address _entryPoint,
        address _omniCoin
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        
        // Store registry address
        registry = OmniCoinRegistry(_registry);
        
        entryPoint = _entryPoint;
        
        // For backwards compatibility
        if (_omniCoin != address(0)) {
            omniCoin = OmniCoin(_omniCoin);
        }
        
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
     * @notice Executes a user operation
     * @dev Called by the entry point to execute validated operations
     * @param userOp User operation to execute
     * @return result Execution result containing success status and return data
     */
    function executeUserOp(
        UserOperation calldata userOp
    ) external nonReentrant returns (ExecutionResult memory result) {
        if (msg.sender != entryPoint) revert NotEntryPoint();
        if (!isDeployed[userOp.sender]) revert AccountNotDeployed();

        // Execute the operation
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = userOp.sender.call{
            gas: userOp.callGasLimit
        }(userOp.callData);

        result.success = success;
        result.returnData = returnData;

        emit OperationExecuted(userOp.sender, userOp.nonce, success);
    }

    /**
     * @notice Toggle privacy for an account
     * @dev Allows users to enable/disable privacy mode for their account
     */
    function togglePrivacy() external {
        privacyEnabled[msg.sender] = !privacyEnabled[msg.sender];
        emit PrivacyToggled(msg.sender, privacyEnabled[msg.sender]);
    }

    /**
     * @notice Update staking amount for an account
     * @dev Handles both increasing and decreasing stake amounts
     * @param amount New staking amount to set
     * @param usePrivacy Whether to use PrivateOmniCoin for staking
     */
    function updateStaking(uint256 amount, bool usePrivacy) external nonReentrant {
        address token;
        uint256 currentStake;
        
        if (usePrivacy) {
            token = _getContract(registry.PRIVATE_OMNICOIN());
            currentStake = privateStakingAmount[msg.sender];
        } else {
            token = _getContract(registry.OMNICOIN());
            if (token == address(0) && address(omniCoin) != address(0)) {
                token = address(omniCoin); // Backwards compatibility
            }
            currentStake = stakingAmount[msg.sender];
        }
        
        if (token == address(0)) revert InvalidAddress();
        
        if (amount > currentStake) {
            uint256 additionalStake = amount - currentStake;
            // Update state before transfer to prevent reentrancy
            if (usePrivacy) {
                privateStakingAmount[msg.sender] = amount;
            } else {
                stakingAmount[msg.sender] = amount;
            }
            if (!IERC20(token).transferFrom(
                    msg.sender,
                    address(this),
                    additionalStake
                )) revert TransferFailed();
        } else if (amount < currentStake) {
            uint256 returnStake = currentStake - amount;
            // Update state before transfer to prevent reentrancy
            if (usePrivacy) {
                privateStakingAmount[msg.sender] = amount;
            } else {
                stakingAmount[msg.sender] = amount;
            }
            if (!IERC20(token).transfer(msg.sender, returnStake))
                revert TransferFailed();
        } else {
            // No change in stake amount
            if (usePrivacy) {
                privateStakingAmount[msg.sender] = amount;
            } else {
                stakingAmount[msg.sender] = amount;
            }
        }
        
        emit StakingUpdated(msg.sender, amount);
    }

    /**
     * @notice Update reputation score for an account
     * @dev Restricted to contract owner
     * @param score New reputation score to set
     */
    function updateReputation(uint256 score) external {
        if (msg.sender != owner()) revert NotWhitelisted();
        reputationScore[msg.sender] = score;
        emit ReputationUpdated(msg.sender, score);
    }

    /**
     * @notice Updates the entry point address
     * @dev Restricted to contract owner
     * @param _newEntryPoint New entry point contract address
     */
    function updateEntryPoint(address _newEntryPoint) external onlyOwner {
        if (_newEntryPoint == address(0)) revert InvalidAddress();
        entryPoint = _newEntryPoint;
        emit EntryPointUpdated(_newEntryPoint);
    }

    /**
     * @notice Updates the gas limit
     * @dev Restricted to contract owner
     * @param _newGasLimit New gas limit for entry point operations
     */
    function updateGasLimit(uint256 _newGasLimit) external onlyOwner {
        entryPointGasLimit = _newGasLimit;
        emit GasLimitUpdated(_newGasLimit);
    }

    /**
     * @notice Returns account status and settings
     * @dev Provides comprehensive account information in a single call
     * @param _account Address of the account to query
     * @return deployed Whether the account is deployed
     * @return nonce Current nonce for the account
     * @return init Initialization code for the account
     * @return privacy Whether privacy mode is enabled
     * @return stake Current staking amount (public)
     * @return privateStake Current staking amount (private)
     * @return reputation Current reputation score
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
            uint256 privateStake,
            uint256 reputation
        )
    {
        return (
            isDeployed[_account],
            nonces[_account],
            initCode[_account],
            privacyEnabled[_account],
            stakingAmount[_account],
            privateStakingAmount[_account],
            reputationScore[_account]
        );
    }

    /**
     * @notice Returns the current nonce for an account
     * @dev Used for transaction ordering and replay protection
     * @param _account Address of the account to query
     * @return nonce Current nonce value
     */
    function getNonce(address _account) external view returns (uint256 nonce) {
        return nonces[_account];
    }

    /**
     * @notice Returns whether an account is deployed
     * @dev Checks deployment status for ERC-4337 compliance
     * @param _account Address of the account to check
     * @return deployed True if the account is deployed
     */
    function isAccountDeployed(address _account) external view returns (bool deployed) {
        return isDeployed[_account];
    }
}
