// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OmniCoinRegistry} from "./OmniCoinRegistry.sol";

/**
 * @title OmniWalletRecovery
 * @author OmniBazaar Team
 * @notice Comprehensive wallet recovery system with social recovery, multi-sig, and backup features
 * @dev Essential for wallet security and user account recovery, supporting multiple recovery methods
 */
contract OmniWalletRecovery is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ECDSA for bytes32;

    // Recovery method types
    enum RecoveryMethod {
        SOCIAL_RECOVERY,
        MULTISIG_RECOVERY,
        TIME_LOCKED_RECOVERY,
        EMERGENCY_RECOVERY
    }

    enum RecoveryStatus {
        PENDING,
        APPROVED,
        EXECUTED,
        CANCELLED,
        EXPIRED
    }

    // Core structures
    struct WalletRecoveryConfig {
        address walletAddress;          // 20 bytes
        address backupAddress;          // 20 bytes  
        uint256 threshold;              // 32 bytes
        uint256 recoveryDelay;          // 32 bytes
        uint256 lastUpdate;             // 32 bytes
        address[] guardians;            // 32 bytes (dynamic array, separate slot)
        RecoveryMethod preferredMethod; // 1 byte
        bool isActive;                  // 1 byte
        // Total: ~6 storage slots (addresses + fixed-size + packed small types)
    }

    struct RecoveryRequest {
        uint256 requestId;
        address walletAddress;
        address newOwner;
        address initiator;
        RecoveryMethod method;
        uint256 timestamp;
        uint256 approvals;
        uint256 requiredApprovals;
        RecoveryStatus status;
        bytes32 dataHash;
        mapping(address => bool) guardianApprovals;
        address[] approvers;
    }

    struct GuardianInfo {
        address guardian;               // 20 bytes
        uint256 reputation;             // 32 bytes
        uint256 joinedAt;               // 32 bytes  
        string name;                    // 32 bytes (dynamic)
        string contact;                 // 32 bytes (dynamic)
        bool isActive;                  // 1 byte (packed with address)
        // Total: ~5 storage slots (optimized packing)
    }

    struct BackupData {
        bytes32 backupHash;
        string encryptedData;
        uint256 timestamp;
        address[] authorizedRecoverers;
        bool isActive;
    }

    // State variables

    /// @notice Registry contract for accessing other OmniCoin contracts
    OmniCoinRegistry public registry;

    /// @notice Recovery configuration for each wallet address
    mapping(address => WalletRecoveryConfig) public walletConfigs;
    /// @notice Recovery requests by request ID
    mapping(uint256 => RecoveryRequest) public recoveryRequests;
    /// @notice Guardian information by guardian address
    mapping(address => GuardianInfo) public guardians;
    /// @notice List of recovery request IDs for each wallet
    mapping(address => uint256[]) public walletRequests;
    /// @notice List of wallets protected by each guardian
    mapping(address => address[]) public walletsByGuardian;
    /// @notice Backup data storage by backup hash
    mapping(bytes32 => BackupData) public backups;
    /// @notice List of backup hashes for each wallet
    mapping(address => bytes32[]) public walletBackups;

    /// @notice Counter for generating unique recovery request IDs
    uint256 public requestCounter;
    /// @notice Minimum number of guardians required for recovery configuration
    uint256 public minGuardians;
    /// @notice Maximum number of guardians allowed for recovery configuration
    uint256 public maxGuardians;
    /// @notice Default time delay before recovery can be executed
    uint256 public defaultRecoveryDelay;
    /// @notice Maximum allowed recovery delay
    uint256 public maxRecoveryDelay;
    /// @notice Minimum reputation score required for guardians
    uint256 public guardianReputationThreshold;

    // Events
    /// @notice Emitted when a wallet's recovery settings are configured
    /// @param wallet The wallet address being configured
    /// @param guardians List of guardian addresses
    /// @param threshold Number of approvals required
    /// @param method Preferred recovery method
    event RecoveryConfigured(
        address indexed wallet,
        address[] guardians,
        uint256 threshold,
        RecoveryMethod method
    );
    /// @notice Emitted when a recovery request is initiated
    /// @param requestId Unique identifier for the recovery request
    /// @param wallet The wallet being recovered
    /// @param newOwner The proposed new owner address
    /// @param method Recovery method being used
    event RecoveryRequested(
        uint256 indexed requestId,
        address indexed wallet,
        address newOwner,
        RecoveryMethod method
    );
    /// @notice Emitted when a guardian approves a recovery request
    /// @param requestId The recovery request being approved
    /// @param guardian The guardian providing approval
    event RecoveryApproved(uint256 indexed requestId, address indexed guardian);
    /// @notice Emitted when a recovery is successfully executed
    /// @param requestId The executed recovery request
    /// @param wallet The recovered wallet
    /// @param newOwner The new owner of the wallet
    event RecoveryExecuted(
        uint256 indexed requestId,
        address indexed wallet,
        address indexed newOwner
    );
    /// @notice Emitted when a recovery request is cancelled
    /// @param requestId The cancelled recovery request
    event RecoveryCancelled(uint256 indexed requestId);
    /// @notice Emitted when a guardian is added to a wallet
    /// @param wallet The wallet address
    /// @param guardian The added guardian address
    event GuardianAdded(address indexed wallet, address indexed guardian);
    /// @notice Emitted when a guardian is removed from a wallet
    /// @param wallet The wallet address
    /// @param guardian The removed guardian address
    event GuardianRemoved(address indexed wallet, address indexed guardian);
    /// @notice Emitted when a backup is created
    /// @param wallet The wallet creating the backup
    /// @param backupHash Hash identifier for the backup
    event BackupCreated(address indexed wallet, bytes32 backupHash);
    /// @notice Emitted when a backup is accessed
    /// @param wallet The wallet whose backup was accessed
    /// @param backupHash The accessed backup hash
    /// @param accessor The address accessing the backup
    event BackupAccessed(
        address indexed wallet,
        bytes32 backupHash,
        address indexed accessor
    );

    // Custom errors
    error InvalidGuardianCount();
    error InvalidThreshold();
    error InvalidRecoveryDelay();
    error InvalidGuardianAddress();
    error CannotBeSelfGuardian();
    error GuardianReputationTooLow();
    error RecoveryNotConfigured();
    error InvalidNewOwner();
    error SameAsCurrentOwner();
    error NotAuthorizedToInitiate();
    error RecoveryNotPending();
    error AlreadyApproved();
    error NotAGuardian();
    error RecoveryNotApproved();
    error RecoveryDelayNotElapsed();
    error NotAuthorizedToCancel();
    error RecoveryNotCancellable();
    error BackupNotActive();
    error NotAuthorized();
    error AlreadyAGuardian();
    error TooManyGuardians();
    error TooFewGuardians();
    error GuardianNotFound();

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Disables initializers to ensure the contract can only be initialized through a proxy
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
     * @notice Initialize the recovery contract
     * @dev Sets up the contract with default parameters and registry
     * @param _registry Address of the OmniCoinRegistry contract
     */
    function initialize(address _registry) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        // Store registry reference
        registry = OmniCoinRegistry(_registry);

        requestCounter = 0;
        minGuardians = 2;
        maxGuardians = 10;
        defaultRecoveryDelay = 48 hours;
        maxRecoveryDelay = 30 days;
        guardianReputationThreshold = 80;
    }

    /**
     * @notice Configure recovery settings for a wallet
     * @dev Sets up guardians, threshold, and recovery parameters for the caller's wallet
     * @param _guardians Array of guardian addresses
     * @param _threshold Number of guardian approvals required
     * @param _method Preferred recovery method
     * @param _recoveryDelay Time delay before recovery can be executed
     * @param _backupAddress Emergency backup address for recovery
     */
    function configureRecovery(
        address[] calldata _guardians,
        uint256 _threshold,
        RecoveryMethod _method,
        uint256 _recoveryDelay,
        address _backupAddress
    ) external {
        if (_guardians.length < minGuardians || _guardians.length > maxGuardians)
            revert InvalidGuardianCount();
        if (_threshold == 0 || _threshold > _guardians.length)
            revert InvalidThreshold();
        if (_recoveryDelay < 24 hours || _recoveryDelay > maxRecoveryDelay)
            revert InvalidRecoveryDelay();

        // Validate guardians
        for (uint256 i = 0; i < _guardians.length; ++i) {
            if (_guardians[i] == address(0)) revert InvalidGuardianAddress();
            if (_guardians[i] == msg.sender) revert CannotBeSelfGuardian();

            // Check guardian reputation if exists
            if (guardians[_guardians[i]].guardian != address(0)) {
                if (guardians[_guardians[i]].reputation < guardianReputationThreshold)
                    revert GuardianReputationTooLow();
            }
        }

        walletConfigs[msg.sender] = WalletRecoveryConfig({
            walletAddress: msg.sender,
            guardians: _guardians,
            threshold: _threshold,
            recoveryDelay: _recoveryDelay,
            isActive: true,
            preferredMethod: _method,
            backupAddress: _backupAddress,
            lastUpdate: block.timestamp // solhint-disable-line not-rely-on-time
        });

        // Update guardian mappings
        for (uint256 i = 0; i < _guardians.length; ++i) {
            walletsByGuardian[_guardians[i]].push(msg.sender);

            if (guardians[_guardians[i]].guardian == address(0)) {
                guardians[_guardians[i]] = GuardianInfo({
                    guardian: _guardians[i],
                    name: "",
                    contact: "",
                    isActive: true,
                    reputation: 100,
                    joinedAt: block.timestamp // solhint-disable-line not-rely-on-time
                });
            }
        }

        emit RecoveryConfigured(msg.sender, _guardians, _threshold, _method);
    }

    /**
     * @notice Initiate wallet recovery
     * @dev Starts the recovery process for a wallet, requiring guardian approvals
     * @param walletAddress The wallet to recover
     * @param newOwner The proposed new owner address
     * @param method Recovery method to use
     * @param evidence Supporting evidence for the recovery request
     * @return requestId Unique identifier for the recovery request
     */
    function initiateRecovery(
        address walletAddress,
        address newOwner,
        RecoveryMethod method,
        bytes calldata evidence
    ) external nonReentrant returns (uint256 requestId) {
        WalletRecoveryConfig storage config = walletConfigs[walletAddress];
        if (!config.isActive) revert RecoveryNotConfigured();
        if (newOwner == address(0)) revert InvalidNewOwner();
        if (newOwner == walletAddress) revert SameAsCurrentOwner();

        // Check if initiator is authorized
        bool isAuthorized = false;
        if (method == RecoveryMethod.SOCIAL_RECOVERY) {
            for (uint256 i = 0; i < config.guardians.length; ++i) {
                if (config.guardians[i] == msg.sender) {
                    isAuthorized = true;
                    break;
                }
            }
        } else if (method == RecoveryMethod.EMERGENCY_RECOVERY) {
            isAuthorized = (msg.sender == config.backupAddress);
        }
        if (!isAuthorized) revert NotAuthorizedToInitiate();

        requestId = ++requestCounter;
        bytes32 dataHash = keccak256(
            abi.encodePacked(walletAddress, newOwner, evidence)
        );

        RecoveryRequest storage request = recoveryRequests[requestId];
        request.requestId = requestId;
        request.walletAddress = walletAddress;
        request.newOwner = newOwner;
        request.initiator = msg.sender;
        request.method = method;
        request.timestamp = block.timestamp; // solhint-disable-line not-rely-on-time
        request.approvals = 0;
        request.requiredApprovals = _getRequiredApprovals(method, config);
        request.status = RecoveryStatus.PENDING;
        request.dataHash = dataHash;

        walletRequests[walletAddress].push(requestId);

        // Auto-approve if initiator is guardian
        if (method == RecoveryMethod.SOCIAL_RECOVERY) {
            _approveRecovery(requestId, msg.sender);
        }

        emit RecoveryRequested(requestId, walletAddress, newOwner, method);
    }

    /**
     * @notice Approve a recovery request
     * @dev Allows a guardian to approve a pending recovery request
     * @param requestId The recovery request to approve
     */
    function approveRecovery(uint256 requestId) external nonReentrant {
        RecoveryRequest storage request = recoveryRequests[requestId];
        WalletRecoveryConfig storage config = walletConfigs[
            request.walletAddress
        ];

        if (request.status != RecoveryStatus.PENDING)
            revert RecoveryNotPending();
        if (request.guardianApprovals[msg.sender]) revert AlreadyApproved();

        // Verify guardian authorization
        bool isGuardian = false;
        for (uint256 i = 0; i < config.guardians.length; ++i) {
            if (config.guardians[i] == msg.sender) {
                isGuardian = true;
                break;
            }
        }
        if (!isGuardian) revert NotAGuardian();

        _approveRecovery(requestId, msg.sender);
    }

    /**
     * @notice Internal function to approve recovery
     * @dev Handles the approval logic and checks if threshold is met
     * @param requestId The recovery request being approved
     * @param approver The address providing approval
     */
    function _approveRecovery(uint256 requestId, address approver) internal {
        RecoveryRequest storage request = recoveryRequests[requestId];

        request.guardianApprovals[approver] = true;
        request.approvers.push(approver);
        ++request.approvals;

        emit RecoveryApproved(requestId, approver);

        // Check if threshold is met
        if (request.approvals == request.requiredApprovals) {
            request.status = RecoveryStatus.APPROVED;
        }
    }

    /**
     * @notice Execute approved recovery
     * @dev Executes a recovery after approval threshold is met and delay has passed
     * @param requestId The recovery request to execute
     */
    function executeRecovery(uint256 requestId) external nonReentrant {
        RecoveryRequest storage request = recoveryRequests[requestId];
        WalletRecoveryConfig storage config = walletConfigs[
            request.walletAddress
        ];

        if (request.status != RecoveryStatus.APPROVED)
            revert RecoveryNotApproved();
        if (block.timestamp < request.timestamp + config.recoveryDelay) // solhint-disable-line not-rely-on-time
            revert RecoveryDelayNotElapsed();

        // Execute the recovery by updating wallet ownership
        // This would typically interact with the wallet contract to transfer ownership
        request.status = RecoveryStatus.EXECUTED;

        // Update guardian reputations
        for (uint256 i = 0; i < request.approvers.length; ++i) {
            GuardianInfo storage guardian = guardians[request.approvers[i]];
            if (guardian.reputation < 100) {
                ++guardian.reputation;
            }
        }

        emit RecoveryExecuted(
            requestId,
            request.walletAddress,
            request.newOwner
        );
    }

    /**
     * @notice Cancel recovery request
     * @dev Allows authorized parties to cancel a pending or approved recovery
     * @param requestId The recovery request to cancel
     */
    function cancelRecovery(uint256 requestId) external {
        RecoveryRequest storage request = recoveryRequests[requestId];

        if (msg.sender != request.initiator &&
            msg.sender != request.walletAddress &&
            msg.sender != owner())
            revert NotAuthorizedToCancel();
        if (request.status != RecoveryStatus.PENDING &&
            request.status != RecoveryStatus.APPROVED)
            revert RecoveryNotCancellable();

        request.status = RecoveryStatus.CANCELLED;
        emit RecoveryCancelled(requestId);
    }

    /**
     * @notice Create encrypted backup
     * @dev Creates an encrypted backup of wallet data with authorized recoverers
     * @param encryptedData The encrypted wallet data
     * @param authorizedRecoverers Addresses authorized to access the backup
     * @return backupHash Unique hash identifier for the backup
     */
    function createBackup(
        string calldata encryptedData,
        address[] calldata authorizedRecoverers
    ) external returns (bytes32 backupHash) {
        backupHash = keccak256(
            abi.encodePacked(msg.sender, encryptedData, block.timestamp) // solhint-disable-line not-rely-on-time
        );

        backups[backupHash] = BackupData({
            backupHash: backupHash,
            encryptedData: encryptedData,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            authorizedRecoverers: authorizedRecoverers,
            isActive: true
        });

        walletBackups[msg.sender].push(backupHash);
        emit BackupCreated(msg.sender, backupHash);
    }

    /**
     * @notice Access backup data
     * @dev Retrieves encrypted backup data for authorized users
     * @param backupHash The backup identifier
     * @param walletAddress The wallet associated with the backup
     * @return encryptedData The encrypted backup data
     */
    function accessBackup(
        bytes32 backupHash,
        address walletAddress
    ) external view returns (string memory encryptedData) {
        BackupData storage backup = backups[backupHash];
        if (!backup.isActive) revert BackupNotActive();

        // Check authorization
        bool authorized = false;
        for (uint256 i = 0; i < backup.authorizedRecoverers.length; ++i) {
            if (backup.authorizedRecoverers[i] == msg.sender) {
                authorized = true;
                break;
            }
        }

        WalletRecoveryConfig storage config = walletConfigs[walletAddress];
        for (uint256 i = 0; i < config.guardians.length; ++i) {
            if (config.guardians[i] == msg.sender) {
                authorized = true;
                break;
            }
        }

        if (!authorized && msg.sender != walletAddress) revert NotAuthorized();
        return backup.encryptedData;
    }

    /**
     * @notice Add guardian to wallet
     * @dev Adds a new guardian to the caller's wallet recovery configuration
     * @param guardian The guardian address to add
     */
    function addGuardian(address guardian) external {
        WalletRecoveryConfig storage config = walletConfigs[msg.sender];
        if (!config.isActive) revert RecoveryNotConfigured();
        if (config.guardians.length == maxGuardians)
            revert TooManyGuardians();
        if (guardian == address(0)) revert InvalidGuardianAddress();
        if (guardian == msg.sender) revert CannotBeSelfGuardian();

        // Check if already a guardian
        for (uint256 i = 0; i < config.guardians.length; ++i) {
            if (config.guardians[i] == guardian) revert AlreadyAGuardian();
        }

        config.guardians.push(guardian);
        walletsByGuardian[guardian].push(msg.sender);

        if (guardians[guardian].guardian == address(0)) {
            guardians[guardian] = GuardianInfo({
                guardian: guardian,
                name: "",
                contact: "",
                isActive: true,
                reputation: 100,
                joinedAt: block.timestamp // solhint-disable-line not-rely-on-time
            });
        }

        emit GuardianAdded(msg.sender, guardian);
    }

    /**
     * @notice Remove guardian from wallet
     * @dev Removes a guardian from the caller's wallet recovery configuration
     * @param guardian The guardian address to remove
     */
    function removeGuardian(address guardian) external {
        WalletRecoveryConfig storage config = walletConfigs[msg.sender];
        if (!config.isActive) revert RecoveryNotConfigured();
        if (config.guardians.length == minGuardians)
            revert TooFewGuardians();

        // Find and remove guardian
        for (uint256 i = 0; i < config.guardians.length; ++i) {
            if (config.guardians[i] == guardian) {
                config.guardians[i] = config.guardians[
                    config.guardians.length - 1
                ];
                config.guardians.pop();
                break;
            }
        }

        // Adjust threshold if necessary
        if (config.threshold > config.guardians.length) {
            config.threshold = config.guardians.length;
        }

        emit GuardianRemoved(msg.sender, guardian);
    }

    /**
     * @notice Get required approvals based on method
     * @dev Calculates the number of approvals needed for a recovery method
     * @param method The recovery method being used
     * @param config The wallet's recovery configuration
     * @return Number of required approvals
     */
    function _getRequiredApprovals(
        RecoveryMethod method,
        WalletRecoveryConfig storage config
    ) internal view returns (uint256) {
        if (method == RecoveryMethod.SOCIAL_RECOVERY) {
            return config.threshold;
        } else if (method == RecoveryMethod.MULTISIG_RECOVERY) {
            return (config.guardians.length * 2) / 3; // 2/3 majority
        } else if (method == RecoveryMethod.EMERGENCY_RECOVERY) {
            return 1; // Only backup address needed
        }
        return config.threshold;
    }

    /**
     * @notice Get wallet recovery configuration
     * @dev Retrieves the recovery configuration for a specific wallet
     * @param wallet The wallet address to query
     * @return guardianList Array of guardian addresses
     * @return threshold Number of approvals required
     * @return recoveryDelay Time delay before recovery execution
     * @return isActive Whether recovery is configured
     * @return preferredMethod The preferred recovery method
     */
    function getWalletConfig(
        address wallet
    )
        external
        view
        returns (
            address[] memory guardianList,
            uint256 threshold,
            uint256 recoveryDelay,
            bool isActive,
            RecoveryMethod preferredMethod
        )
    {
        WalletRecoveryConfig storage config = walletConfigs[wallet];
        return (
            config.guardians,
            config.threshold,
            config.recoveryDelay,
            config.isActive,
            config.preferredMethod
        );
    }

    /**
     * @notice Get recovery requests for wallet
     * @dev Returns all recovery request IDs associated with a wallet
     * @param wallet The wallet address to query
     * @return Array of recovery request IDs
     */
    function getWalletRequests(
        address wallet
    ) external view returns (uint256[] memory) {
        return walletRequests[wallet];
    }

    /**
     * @notice Get wallets guarded by address
     * @dev Returns all wallets where the address is a guardian
     * @param guardian The guardian address to query
     * @return Array of wallet addresses
     */
    function getGuardedWallets(
        address guardian
    ) external view returns (address[] memory) {
        return walletsByGuardian[guardian];
    }

    /**
     * @notice Update recovery parameters (owner only)
     * @dev Updates global recovery parameters for the contract
     * @param _minGuardians New minimum guardian requirement
     * @param _maxGuardians New maximum guardian limit
     * @param _defaultRecoveryDelay New default recovery delay
     * @param _guardianReputationThreshold New reputation threshold
     */
    function updateRecoveryParameters(
        uint256 _minGuardians,
        uint256 _maxGuardians,
        uint256 _defaultRecoveryDelay,
        uint256 _guardianReputationThreshold
    ) external onlyOwner {
        minGuardians = _minGuardians;
        maxGuardians = _maxGuardians;
        defaultRecoveryDelay = _defaultRecoveryDelay;
        guardianReputationThreshold = _guardianReputationThreshold;
    }
}
