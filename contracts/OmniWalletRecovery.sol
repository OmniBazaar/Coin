// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OmniCoinCore} from "./OmniCoinCore.sol";

/**
 * @title OmniWalletRecovery
 * @dev Comprehensive wallet recovery system with social recovery, multi-sig, and backup features
 * Essential for wallet security and user account recovery
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
        address walletAddress;
        address[] guardians;
        uint256 threshold;
        uint256 recoveryDelay;
        bool isActive;
        RecoveryMethod preferredMethod;
        address backupAddress;
        uint256 lastUpdate;
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
        address guardian;
        string name;
        string contact;
        bool isActive;
        uint256 reputation;
        uint256 joinedAt;
    }

    struct BackupData {
        bytes32 backupHash;
        string encryptedData;
        uint256 timestamp;
        address[] authorizedRecoverers;
        bool isActive;
    }

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

    // State variables
    OmniCoinCore public omniCoin;

    mapping(address => WalletRecoveryConfig) public walletConfigs;
    mapping(uint256 => RecoveryRequest) public recoveryRequests;
    mapping(address => GuardianInfo) public guardians;
    mapping(address => uint256[]) public walletRequests;
    mapping(address => address[]) public walletsByGuardian;
    mapping(bytes32 => BackupData) public backups;
    mapping(address => bytes32[]) public walletBackups;

    uint256 public requestCounter;
    uint256 public minGuardians;
    uint256 public maxGuardians;
    uint256 public defaultRecoveryDelay;
    uint256 public maxRecoveryDelay;
    uint256 public guardianReputationThreshold;

    // Events
    event RecoveryConfigured(
        address indexed wallet,
        address[] guardians,
        uint256 threshold,
        RecoveryMethod method
    );
    event RecoveryRequested(
        uint256 indexed requestId,
        address indexed wallet,
        address newOwner,
        RecoveryMethod method
    );
    event RecoveryApproved(uint256 indexed requestId, address indexed guardian);
    event RecoveryExecuted(
        uint256 indexed requestId,
        address indexed wallet,
        address newOwner
    );
    event RecoveryCancelled(uint256 indexed requestId);
    event GuardianAdded(address indexed wallet, address indexed guardian);
    event GuardianRemoved(address indexed wallet, address indexed guardian);
    event BackupCreated(address indexed wallet, bytes32 backupHash);
    event BackupAccessed(
        address indexed wallet,
        bytes32 backupHash,
        address accessor
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the recovery contract
     */
    function initialize(address _omniCoin) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        omniCoin = OmniCoinCore(_omniCoin);
        requestCounter = 0;
        minGuardians = 2;
        maxGuardians = 10;
        defaultRecoveryDelay = 48 hours;
        maxRecoveryDelay = 30 days;
        guardianReputationThreshold = 80;
    }

    /**
     * @dev Configure recovery settings for a wallet
     */
    function configureRecovery(
        address[] memory _guardians,
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
            lastUpdate: block.timestamp
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
                    joinedAt: block.timestamp
                });
            }
        }

        emit RecoveryConfigured(msg.sender, _guardians, _threshold, _method);
    }

    /**
     * @dev Initiate wallet recovery
     */
    function initiateRecovery(
        address walletAddress,
        address newOwner,
        RecoveryMethod method,
        bytes memory evidence
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
        request.timestamp = block.timestamp;
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
     * @dev Approve a recovery request
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
     * @dev Internal function to approve recovery
     */
    function _approveRecovery(uint256 requestId, address approver) internal {
        RecoveryRequest storage request = recoveryRequests[requestId];

        request.guardianApprovals[approver] = true;
        request.approvers.push(approver);
        ++request.approvals;

        emit RecoveryApproved(requestId, approver);

        // Check if threshold is met
        if (request.approvals >= request.requiredApprovals) {
            request.status = RecoveryStatus.APPROVED;
        }
    }

    /**
     * @dev Execute approved recovery
     */
    function executeRecovery(uint256 requestId) external nonReentrant {
        RecoveryRequest storage request = recoveryRequests[requestId];
        WalletRecoveryConfig storage config = walletConfigs[
            request.walletAddress
        ];

        if (request.status != RecoveryStatus.APPROVED)
            revert RecoveryNotApproved();
        if (block.timestamp < request.timestamp + config.recoveryDelay)
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
     * @dev Cancel recovery request
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
     * @dev Create encrypted backup
     */
    function createBackup(
        string memory encryptedData,
        address[] memory authorizedRecoverers
    ) external returns (bytes32 backupHash) {
        backupHash = keccak256(
            abi.encodePacked(msg.sender, encryptedData, block.timestamp)
        );

        backups[backupHash] = BackupData({
            backupHash: backupHash,
            encryptedData: encryptedData,
            timestamp: block.timestamp,
            authorizedRecoverers: authorizedRecoverers,
            isActive: true
        });

        walletBackups[msg.sender].push(backupHash);
        emit BackupCreated(msg.sender, backupHash);
    }

    /**
     * @dev Access backup data
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
     * @dev Add guardian to wallet
     */
    function addGuardian(address guardian) external {
        WalletRecoveryConfig storage config = walletConfigs[msg.sender];
        if (!config.isActive) revert RecoveryNotConfigured();
        if (config.guardians.length >= maxGuardians)
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
                joinedAt: block.timestamp
            });
        }

        emit GuardianAdded(msg.sender, guardian);
    }

    /**
     * @dev Remove guardian from wallet
     */
    function removeGuardian(address guardian) external {
        WalletRecoveryConfig storage config = walletConfigs[msg.sender];
        if (!config.isActive) revert RecoveryNotConfigured();
        if (config.guardians.length <= minGuardians)
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
     * @dev Get required approvals based on method
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
     * @dev Get wallet recovery configuration
     */
    function getWalletConfig(
        address wallet
    )
        external
        view
        returns (
            address[] memory guardians,
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
     * @dev Get recovery requests for wallet
     */
    function getWalletRequests(
        address wallet
    ) external view returns (uint256[] memory) {
        return walletRequests[wallet];
    }

    /**
     * @dev Get wallets guarded by address
     */
    function getGuardedWallets(
        address guardian
    ) external view returns (address[] memory) {
        return walletsByGuardian[guardian];
    }

    /**
     * @dev Update recovery parameters (owner only)
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
