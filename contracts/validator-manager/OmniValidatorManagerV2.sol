// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    ValidatorStatus,
    PChainOwner,
    ConversionData,
    InitialValidator
} from "./interfaces/IACP99Manager.sol";
import {ValidatorMessages} from "./libs/ValidatorMessages.sol";
import {IWarpMessenger, WarpMessage} from "./interfaces/IWarpMessenger.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title OmniValidatorManagerV2
 * @author OmniBazaar Team
 * @notice Production-ready validator manager for OmniCoin L1 with full P-Chain integration
 * @dev Extends Avalanche's ValidatorManager pattern with OmniCoin Proof of Participation
 *
 * Key Features:
 * - Full Warp messaging integration (ACP-77 compliant)
 * - P-Chain validator registration (sends RegisterL1ValidatorTx)
 * - OmniCoin Proof of Participation qualification checking
 * - Equal consensus weights for all validators (democratic, weight = 100)
 * - PoP-weighted reward distribution (handled off-chain in BlockRewardService)
 *
 * Architecture (Copied from Avalanche ValidatorManager):
 * 1. initializeValidatorSet() - Verify conversion data, set initial validators
 * 2. initiateValidatorRegistration() - Send RegisterL1ValidatorMessage to P-Chain
 * 3. completeValidatorRegistration() - Receive P-Chain acknowledgment, activate validator
 * 4. initiateValidatorRemoval() - Send weight=0 message to P-Chain
 * 5. completeValidatorRemoval() - Receive P-Chain acknowledgment, deactivate validator
 *
 * OmniCoin Enhancements:
 * - Qualification check via QualificationOracle (PoP >= 50, KYC tier >= 3, etc.)
 * - Permissionless registration (anyone qualified can register)
 * - Equal weights ensure democratic consensus (no whale dominance)
 * - PoP affects rewards only (computed off-chain)
 *
 * Security:
 * - UUPS upgradeable pattern
 * - Owner-only critical functions
 * - Warp message verification
 * - Churn rate limiting (prevents rapid validator turnover)
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract OmniValidatorManagerV2 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    // ========== CONSTANTS (Copied from Avalanche ValidatorManager) ==========

    /// @notice Warp precompile address (Subnet-EVM standard)
    IWarpMessenger public constant WARP_MESSENGER =
        IWarpMessenger(0x0200000000000000000000000000000000000005);

    /// @notice P-Chain blockchain ID (always 0x00...00)
    bytes32 public constant P_CHAIN_BLOCKCHAIN_ID = bytes32(0);

    /// @notice NodeID length (20 bytes - RIPEMD160 hash)
    uint32 public constant NODE_ID_LENGTH = 20;

    /// @notice BLS public key length (48 bytes compressed)
    uint8 public constant BLS_PUBLIC_KEY_LENGTH = 48;

    /// @notice Registration expiry duration (24 hours)
    uint64 public constant REGISTRATION_EXPIRY_LENGTH = 1 days;

    /// @notice Maximum churn period length (24 hours)
    uint64 public constant MAXIMUM_CHURN_PERIOD_LENGTH = REGISTRATION_EXPIRY_LENGTH;

    /// @notice Maximum churn percentage (20%)
    uint8 public constant MAXIMUM_CHURN_PERCENTAGE_LIMIT = 20;

    /// @notice Fixed consensus weight for ALL validators (OmniCoin: democratic)
    uint64 public constant VALIDATOR_WEIGHT = 100;

    // ========== STRUCTS (Must come before state variables per solhint ordering) ==========

    /**
     * @notice Validator information
     * @param status Current validator status
     * @param nodeID The NodeID of the validator
     * @param startingWeight Initial weight at registration
     * @param sentNonce Current nonce sent to P-Chain
     * @param receivedNonce Highest nonce received from P-Chain
     * @param weight Current validator weight
     * @param startTime Validation start timestamp
     * @param endTime Validation end timestamp
     */
    struct Validator {
        ValidatorStatus status;
        bytes nodeID;
        uint64 startingWeight;
        uint64 sentNonce;
        uint64 receivedNonce;
        uint64 weight;
        uint64 startTime;
        uint64 endTime;
    }

    /**
     * @notice Churn period tracker
     * @param startTime Period start timestamp
     * @param initialWeight Initial total weight
     * @param totalWeight Current total weight
     * @param churnAmount Amount of weight churned this period
     */
    struct ValidatorChurnPeriod {
        uint256 startTime;
        uint64 initialWeight;
        uint64 totalWeight;
        uint64 churnAmount;
    }

    // ========== STATE VARIABLES ==========

    /// @notice Subnet ID of this L1
    bytes32 public subnetID;

    /// @notice Qualification oracle contract address
    address public qualificationOracle;

    /// @notice Churn period duration in seconds
    uint64 public churnPeriodSeconds;

    /// @notice Maximum churn percentage per period
    uint8 public maximumChurnPercentage;

    /// @notice Whether initial validator set has been initialized
    bool public _initializedValidatorSet;

    /// @notice Current churn tracker
    ValidatorChurnPeriod public churnTracker;

    /// @notice Validator information by validation ID
    mapping(bytes32 => Validator) public validationPeriods;

    /// @notice NodeID to validation ID mapping (for active validators)
    mapping(bytes => bytes32) public registeredValidators;

    /// @notice Pending registration messages (for resending)
    mapping(bytes32 => bytes) public pendingRegisterValidationMessages;

    /// @notice Total weight of active validators
    uint64 public totalWeight;

    // ========== EVENTS (Copied from Avalanche + OmniCoin additions) ==========

    /**
     * @notice Emitted when an initial validator is registered from conversion data
     * @param validationID The unique ID of this validation period
     * @param nodeID The NodeID of the validator (fixed 20 bytes)
     * @param subnetID The subnet ID this validator is validating
     * @param weight The consensus weight assigned to this validator
     */
    event RegisteredInitialValidator(
        bytes32 indexed validationID,
        bytes20 indexed nodeID,
        bytes32 indexed subnetID,
        uint64 weight
    );

    /**
     * @notice Emitted when a new validator registration is initiated
     * @param validationID The unique ID assigned to this validation period
     * @param nodeID The NodeID of the validator (fixed 20 bytes)
     * @param registrationMessageID The Warp message ID sent to P-Chain
     * @param registrationExpiry The timestamp when registration expires
     * @param weight The consensus weight assigned to this validator
     */
    event InitiatedValidatorRegistration(
        bytes32 indexed validationID,
        bytes20 indexed nodeID,
        bytes32 indexed registrationMessageID,
        uint64 registrationExpiry,
        uint64 weight
    );

    /**
     * @notice Emitted when validator registration is acknowledged by P-Chain
     * @param validationID The validation ID that was activated
     * @param weight The validator's consensus weight
     */
    event CompletedValidatorRegistration(
        bytes32 indexed validationID,
        uint64 indexed weight
    );

    /**
     * @notice Emitted when validator removal is initiated
     * @param validationID The validation ID being removed
     * @param weightUpdateMessageID The Warp message ID sent to P-Chain
     * @param weight The validator's weight before removal
     * @param endTime The timestamp when removal was initiated
     */
    event InitiatedValidatorRemoval(
        bytes32 indexed validationID,
        bytes32 indexed weightUpdateMessageID,
        uint64 indexed weight,
        uint64 endTime
    );

    /**
     * @notice Emitted when validator removal is acknowledged by P-Chain
     * @param validationID The validation ID that was removed
     */
    event CompletedValidatorRemoval(bytes32 indexed validationID);

    /**
     * @notice Emitted when validator weight update is initiated
     * @param validationID The validation ID being updated
     * @param nonce The nonce of this weight update
     * @param weightUpdateMessageID The Warp message ID sent to P-Chain
     * @param weight The new validator weight
     */
    event InitiatedValidatorWeightUpdate(
        bytes32 indexed validationID,
        uint64 indexed nonce,
        bytes32 indexed weightUpdateMessageID,
        uint64 weight
    );

    /**
     * @notice Emitted when weight update is acknowledged by P-Chain
     * @param validationID The validation ID that was updated
     * @param nonce The nonce of the acknowledged update
     * @param weight The new validator weight
     */
    event CompletedValidatorWeightUpdate(
        bytes32 indexed validationID,
        uint64 indexed nonce,
        uint64 indexed weight
    );

    /**
     * @notice Emitted when qualification oracle address is updated
     * @param oldOracle The previous oracle address
     * @param newOracle The new oracle address
     */
    event QualificationOracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );

    // ========== ERRORS (Copied from Avalanche + OmniCoin additions) ==========

    error InvalidInitializationStatus();
    error InvalidConversionID(bytes32 actual, bytes32 expected);
    error InvalidValidatorManagerBlockchainID(bytes32 blockchainID);
    error InvalidValidatorManagerAddress(address managerAddress);
    error InvalidTotalWeight(uint64 weight);
    error NodeAlreadyRegistered(bytes nodeID);
    error InvalidNodeID(bytes nodeID);
    error InvalidBLSKeyLength(uint256 length);
    error InvalidPChainOwnerThreshold(uint32 threshold, uint256 addressesLength);
    error InvalidPChainOwnerAddresses();
    error ZeroAddress();
    error InvalidValidationID(bytes32 validationID);
    error InvalidValidatorStatus(ValidatorStatus status);
    error UnexpectedRegistrationStatus(bool status);
    error InvalidWarpMessage();
    error InvalidWarpSourceChainID(bytes32 sourceChainID);
    error InvalidWarpOriginSenderAddress(address originSenderAddress);
    error InvalidMaximumChurnPercentage(uint8 percentage);
    error InvalidChurnPeriodLength(uint64 length);
    error ExceededChurnLimit(uint64 churnAmount, uint64 churnLimit);
    error InvalidNonce(uint32 nonce);

    // OmniCoin-specific errors
    error NotQualified(address validator);
    error OracleNotSet();

    // ========== MODIFIERS ==========

    /**
     * @notice Ensure validator set has been initialized
     * @dev Copied from Avalanche ValidatorManager
     */
    modifier initializedValidatorSet() {
        if (!_initializedValidatorSet) {
            revert InvalidInitializationStatus();
        }
        _;
    }

    // ========== INITIALIZATION ==========

    /**
     * @notice Initialize the contract (UUPS pattern)
     * @param _subnetID The subnet ID of this L1
     * @param _qualificationOracle Address of qualification oracle
     * @param _churnPeriodSeconds Churn period duration
     * @param _maximumChurnPercentage Maximum churn per period
     */
    function initialize(
        bytes32 _subnetID,
        address _qualificationOracle,
        uint64 _churnPeriodSeconds,
        uint8 _maximumChurnPercentage
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        subnetID = _subnetID;
        qualificationOracle = _qualificationOracle;

        if (
            _maximumChurnPercentage > MAXIMUM_CHURN_PERCENTAGE_LIMIT ||
            _maximumChurnPercentage == 0
        ) {
            revert InvalidMaximumChurnPercentage(_maximumChurnPercentage);
        }
        if (_churnPeriodSeconds > MAXIMUM_CHURN_PERIOD_LENGTH) {
            revert InvalidChurnPeriodLength(_churnPeriodSeconds);
        }

        churnPeriodSeconds = _churnPeriodSeconds;
        maximumChurnPercentage = _maximumChurnPercentage;
    }

    /**
     * @notice Required by UUPS pattern
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Set qualification oracle
     * @param oracle Address of qualification oracle contract
     */
    function setQualificationOracle(address oracle) external onlyOwner {
        emit QualificationOracleUpdated(qualificationOracle, oracle);
        qualificationOracle = oracle;
    }

    // ========== VALIDATOR SET INITIALIZATION (Copied from Avalanche) ==========

    /**
     * @notice Initialize validator set by verifying SubnetToL1ConversionMessage from P-Chain
     * @dev This function MUST be called before any validators can be added/removed
     * @dev Copied from Avalanche ValidatorManager with minimal modifications
     * @dev Complex function required for Warp message verification (complexity justified)
     * @param conversionData The conversion data to verify
     * @param messageIndex The index of the Warp message containing conversion ID
     */
    /* solhint-disable code-complexity */
    function initializeValidatorSet(
        ConversionData calldata conversionData,
        uint32 messageIndex
    ) public onlyOwner {
        if (_initializedValidatorSet) {
            revert InvalidInitializationStatus();
        }

        // Verify blockchain ID and manager address match this contract
        if (conversionData.validatorManagerBlockchainID != WARP_MESSENGER.getBlockchainID()) {
            revert InvalidValidatorManagerBlockchainID(conversionData.validatorManagerBlockchainID);
        }
        if (address(conversionData.validatorManagerAddress) != address(this)) {
            revert InvalidValidatorManagerAddress(address(conversionData.validatorManagerAddress));
        }

        // Verify conversion ID from Warp message matches conversion data hash
        bytes32 conversionIDFromWarp = ValidatorMessages.unpackSubnetToL1ConversionMessage(
            _getPChainWarpMessage(messageIndex).payload
        );
        bytes memory encodedConversion = ValidatorMessages.packConversionData(conversionData);
        bytes32 encodedConversionID = sha256(encodedConversion);

        if (encodedConversionID != conversionIDFromWarp) {
            revert InvalidConversionID(encodedConversionID, conversionIDFromWarp);
        }

        // Register all initial validators
        uint256 numInitialValidators = conversionData.initialValidators.length;
        uint64 initialTotalWeight;

        for (uint32 i = 0; i < numInitialValidators; ++i) {
            InitialValidator memory initialValidator = conversionData.initialValidators[i];

            if (registeredValidators[initialValidator.nodeID] != bytes32(0)) {
                revert NodeAlreadyRegistered(initialValidator.nodeID);
            }
            if (initialValidator.nodeID.length != NODE_ID_LENGTH) {
                revert InvalidNodeID(initialValidator.nodeID);
            }

            // Validation ID for initial validators = SHA256(subnetID || index)
            bytes32 validationID = sha256(abi.encodePacked(conversionData.subnetID, i));

            // Register as active validator
            registeredValidators[initialValidator.nodeID] = validationID;
            validationPeriods[validationID] = Validator({
                status: ValidatorStatus.Active,
                nodeID: initialValidator.nodeID,
                startingWeight: initialValidator.weight,
                sentNonce: 0,
                receivedNonce: 0,
                weight: initialValidator.weight,
                // solhint-disable-next-line not-rely-on-time
                startTime: uint64(block.timestamp),
                endTime: 0
            });

            initialTotalWeight += initialValidator.weight;

            emit RegisteredInitialValidator(
                validationID,
                _fixedNodeID(initialValidator.nodeID),
                conversionData.subnetID,
                initialValidator.weight
            );
        }

        // Initialize churn tracker
        /* solhint-disable not-rely-on-time */
        churnTracker = ValidatorChurnPeriod({
            startTime: block.timestamp,
            initialWeight: initialTotalWeight,
            totalWeight: initialTotalWeight,
            churnAmount: 0
        });
        /* solhint-enable not-rely-on-time */
        totalWeight = initialTotalWeight;

        // Validate total weight is sufficient
        if (initialTotalWeight * maximumChurnPercentage < 100) {
            revert InvalidTotalWeight(initialTotalWeight);
        }

        _initializedValidatorSet = true;
    }
    /* solhint-enable code-complexity */

    // ========== VALIDATOR REGISTRATION (OmniCoin: Permissionless if Qualified) ==========

    /**
     * @notice Register as validator (permissionless if qualified)
     * @dev Extends Avalanche's initiateValidatorRegistration with PoP qualification check
     *
     * Requirements:
     * - Must be qualified (checked via QualificationOracle)
     * - Validator set must be initialized
     * - NodeID must be unique
     * - Must not exceed churn limits
     *
     * Flow:
     * 1. Check qualification via oracle
     * 2. Pack RegisterL1ValidatorMessage (ACP-77 format)
     * 3. Send via Warp precompile to P-Chain
     * 4. Store as PendingAdded status
     * 5. Wait for P-Chain to call completeValidatorRegistration
     *
     * @param nodeID The NodeID of the validator (20 bytes)
     * @param blsPublicKey The BLS public key (48 bytes)
     * @param remainingBalanceOwner P-Chain owner for remaining balance
     * @param disableOwner P-Chain owner for disabling validator
     *
     * @return validationID The validation ID assigned to this registration
     */
    function initiateValidatorRegistration(
        bytes calldata nodeID,
        bytes calldata blsPublicKey,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner
    ) public initializedValidatorSet returns (bytes32) {
        // OmniCoin: Check qualification via oracle
        if (qualificationOracle == address(0)) {
            revert OracleNotSet();
        }

        (bool success, bytes memory data) = qualificationOracle.staticcall(
            abi.encodeWithSignature("isQualified(address)", msg.sender)
        );

        if (!success || !abi.decode(data, (bool))) {
            revert NotQualified(msg.sender);
        }

        // Validate inputs (copied from Avalanche)
        if (nodeID.length != NODE_ID_LENGTH) {
            revert InvalidNodeID(nodeID);
        }
        if (blsPublicKey.length != BLS_PUBLIC_KEY_LENGTH) {
            revert InvalidBLSKeyLength(blsPublicKey.length);
        }
        if (registeredValidators[nodeID] != bytes32(0)) {
            revert NodeAlreadyRegistered(nodeID);
        }

        _validatePChainOwner(remainingBalanceOwner);
        _validatePChainOwner(disableOwner);

        // Check churn limits (prevent rapid validator turnover)
        _checkAndUpdateChurnTracker(VALIDATOR_WEIGHT, 0);

        // Registration expires in 24 hours
        // solhint-disable-next-line not-rely-on-time
        uint64 registrationExpiry = uint64(block.timestamp) + REGISTRATION_EXPIRY_LENGTH;

        // Pack RegisterL1ValidatorMessage (ACP-77 format)
        (bytes32 validationID, bytes memory registerL1ValidatorMessage) = ValidatorMessages
            .packRegisterL1ValidatorMessage(
            ValidatorMessages.ValidationPeriod({
                subnetID: subnetID,
                nodeID: nodeID,
                blsPublicKey: blsPublicKey,
                remainingBalanceOwner: remainingBalanceOwner,
                disableOwner: disableOwner,
                registrationExpiry: registrationExpiry,
                weight: VALIDATOR_WEIGHT
            })
        );

        // Ensure no collision
        if (validationPeriods[validationID].status != ValidatorStatus.Unknown) {
            revert InvalidValidatorStatus(validationPeriods[validationID].status);
        }

        // Store message for potential resending
        pendingRegisterValidationMessages[validationID] = registerL1ValidatorMessage;
        registeredValidators[nodeID] = validationID;

        // Send Warp message to P-Chain via precompile
        bytes32 messageID = WARP_MESSENGER.sendWarpMessage(registerL1ValidatorMessage);

        // Store validator as pending
        validationPeriods[validationID] = Validator({
            status: ValidatorStatus.PendingAdded,
            nodeID: nodeID,
            startingWeight: VALIDATOR_WEIGHT,
            sentNonce: 0,
            receivedNonce: 0,
            weight: VALIDATOR_WEIGHT,
            startTime: 0, // Set when registration completes
            endTime: 0
        });

        emit InitiatedValidatorRegistration(
            validationID,
            _fixedNodeID(nodeID),
            messageID,
            registrationExpiry,
            VALIDATOR_WEIGHT
        );

        return validationID;
    }

    /**
     * @notice Complete validator registration after P-Chain acknowledgment
     * @dev Copied from Avalanche ValidatorManager
     *
     * Flow:
     * 1. Receive L1ValidatorRegistrationMessage from P-Chain via Warp
     * 2. Verify message is valid and indicates success
     * 3. Update validator status to Active
     * 4. Set start time to current timestamp
     *
     * @param messageIndex The index of the Warp message
     * @return validationID The validation ID that was activated
     */
    function completeValidatorRegistration(
        uint32 messageIndex
    ) public onlyOwner returns (bytes32) {
        // Unpack P-Chain response
        (bytes32 validationID, bool validRegistration) = ValidatorMessages
            .unpackL1ValidatorRegistrationMessage(_getPChainWarpMessage(messageIndex).payload);

        if (!validRegistration) {
            revert UnexpectedRegistrationStatus(validRegistration);
        }

        // Verify we have a pending registration for this validation ID
        if (pendingRegisterValidationMessages[validationID].length == 0) {
            revert InvalidValidationID(validationID);
        }
        if (validationPeriods[validationID].status != ValidatorStatus.PendingAdded) {
            revert InvalidValidatorStatus(validationPeriods[validationID].status);
        }

        // Clean up pending message and activate validator
        delete pendingRegisterValidationMessages[validationID];
        validationPeriods[validationID].status = ValidatorStatus.Active;
        // solhint-disable-next-line not-rely-on-time
        validationPeriods[validationID].startTime = uint64(block.timestamp);

        emit CompletedValidatorRegistration(validationID, validationPeriods[validationID].weight);

        return validationID;
    }

    /**
     * @notice Resend registration message if original failed
     * @dev Copied from Avalanche ValidatorManager
     * @param validationID The validation ID to resend
     */
    function resendRegisterValidatorMessage(bytes32 validationID) external {
        if (pendingRegisterValidationMessages[validationID].length == 0) {
            revert InvalidValidationID(validationID);
        }
        if (validationPeriods[validationID].status != ValidatorStatus.PendingAdded) {
            revert InvalidValidatorStatus(validationPeriods[validationID].status);
        }

        WARP_MESSENGER.sendWarpMessage(pendingRegisterValidationMessages[validationID]);
    }

    // ========== VALIDATOR REMOVAL (Copied from Avalanche) ==========

    /**
     * @notice Initiate validator removal by sending weight=0 to P-Chain
     * @dev Copied from Avalanche ValidatorManager
     *
     * @param validationID The validation ID to remove
     */
    function initiateValidatorRemoval(bytes32 validationID) public onlyOwner {
        Validator memory validator = validationPeriods[validationID];

        if (validator.status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus(validator.status);
        }

        // Update status and end time
        validator.status = ValidatorStatus.PendingRemoved;
        // solhint-disable-next-line not-rely-on-time
        validator.endTime = uint64(block.timestamp);
        validationPeriods[validationID] = validator;

        // Send weight=0 message to P-Chain
        (, bytes32 messageID) = _initiateValidatorWeightUpdate(validationID, 0);

        // solhint-disable-next-line not-rely-on-time
        uint64 endTime = uint64(block.timestamp);
        emit InitiatedValidatorRemoval(
            validationID,
            messageID,
            validator.weight,
            endTime
        );
    }

    /**
     * @notice Complete validator removal after P-Chain acknowledgment
     * @dev Copied from Avalanche ValidatorManager
     *
     * @param messageIndex The index of the Warp message
     * @return validationID The validation ID that was removed
     */
    function completeValidatorRemoval(
        uint32 messageIndex
    ) public onlyOwner returns (bytes32) {
        (bytes32 validationID, bool registered) = ValidatorMessages
            .unpackL1ValidatorRegistrationMessage(_getPChainWarpMessage(messageIndex).payload);

        if (registered) {
            revert UnexpectedRegistrationStatus(registered);
        }

        Validator memory validator = validationPeriods[validationID];

        if (
            validator.status != ValidatorStatus.PendingRemoved &&
            validator.status != ValidatorStatus.PendingAdded
        ) {
            revert InvalidValidatorStatus(validator.status);
        }

        if (validator.status == ValidatorStatus.PendingRemoved) {
            validator.status = ValidatorStatus.Completed;
        } else {
            // Registration failed - remove weight from total without counting as churn
            totalWeight -= validator.weight;
            churnTracker.totalWeight -= validator.weight;
            validator.status = ValidatorStatus.Invalidated;
        }

        // Remove from active validators
        delete registeredValidators[validator.nodeID];
        validationPeriods[validationID] = validator;

        emit CompletedValidatorRemoval(validationID);

        return validationID;
    }

    /**
     * @notice Resend removal message if original failed
     * @dev Copied from Avalanche ValidatorManager
     * @param validationID The validation ID to resend
     */
    function resendValidatorRemovalMessage(bytes32 validationID) external {
        Validator memory validator = validationPeriods[validationID];

        if (validator.status != ValidatorStatus.PendingRemoved) {
            revert InvalidValidatorStatus(validator.status);
        }

        WARP_MESSENGER.sendWarpMessage(
            ValidatorMessages.packL1ValidatorWeightMessage(validationID, validator.sentNonce, 0)
        );
    }

    // ========== WEIGHT UPDATE (Copied from Avalanche) ==========

    /**
     * @notice Update validator weight
     * @dev Copied from Avalanche ValidatorManager
     *
     * @param validationID The validation ID
     * @param newWeight The new weight
     * @return nonce The nonce of this weight update
     * @return messageID The Warp message ID
     */
    function initiateValidatorWeightUpdate(
        bytes32 validationID,
        uint64 newWeight
    ) public onlyOwner returns (uint64, bytes32) {
        if (validationPeriods[validationID].status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus(validationPeriods[validationID].status);
        }

        return _initiateValidatorWeightUpdate(validationID, newWeight);
    }

    /**
     * @notice Complete weight update after P-Chain acknowledgment
     * @dev Copied from Avalanche ValidatorManager
     *
     * @param messageIndex The index of the Warp message
     * @return validationID The validation ID
     * @return nonce The nonce of the update
     */
    function completeValidatorWeightUpdate(
        uint32 messageIndex
    ) public onlyOwner returns (bytes32, uint64) {
        (bytes32 validationID, uint64 nonce, uint64 newWeight) = ValidatorMessages
            .unpackL1ValidatorWeightMessage(_getPChainWarpMessage(messageIndex).payload);

        Validator memory validator = validationPeriods[validationID];

        if (validator.status != ValidatorStatus.Active) {
            revert InvalidValidatorStatus(validator.status);
        }
        if (nonce != validator.sentNonce) {
            revert InvalidNonce(uint32(nonce));
        }

        validator.receivedNonce = nonce;
        uint64 oldWeight = validator.weight;
        validator.weight = newWeight;
        validationPeriods[validationID] = validator;

        // Update total weight
        totalWeight = totalWeight - oldWeight + newWeight;
        churnTracker.totalWeight = churnTracker.totalWeight - oldWeight + newWeight;

        emit CompletedValidatorWeightUpdate(validationID, nonce, newWeight);

        return (validationID, nonce);
    }

    // ========== INTERNAL FUNCTIONS (Copied from Avalanche) ==========

    /**
     * @notice Internal function to initiate weight update
     * @dev Copied from Avalanche ValidatorManager
     * @param validationID The validation ID to update
     * @param newWeight The new weight to assign
     * @return nonce The nonce of this weight update
     * @return messageID The Warp message ID sent to P-Chain
     */
    function _initiateValidatorWeightUpdate(
        bytes32 validationID,
        uint64 newWeight
    ) internal returns (uint64, bytes32) {
        Validator memory validator = validationPeriods[validationID];
        uint64 oldWeight = validator.weight;

        // Check churn limits
        _checkAndUpdateChurnTracker(newWeight, oldWeight);

        // Increment nonce
        ++validator.sentNonce;
        validationPeriods[validationID] = validator;

        // Pack and send weight update message
        bytes memory weightUpdateMessage = ValidatorMessages.packL1ValidatorWeightMessage(
            validationID,
            validator.sentNonce,
            newWeight
        );

        bytes32 messageID = WARP_MESSENGER.sendWarpMessage(weightUpdateMessage);

        emit InitiatedValidatorWeightUpdate(
            validationID,
            validator.sentNonce,
            messageID,
            newWeight
        );

        return (validator.sentNonce, messageID);
    }

    /**
     * @notice Validate P-Chain owner structure
     * @dev Copied from Avalanche ValidatorManager
     * @param pChainOwner The P-Chain owner struct to validate
     */
    function _validatePChainOwner(PChainOwner memory pChainOwner) internal pure {
        if (pChainOwner.threshold == 0 && pChainOwner.addresses.length != 0) {
            revert InvalidPChainOwnerThreshold(pChainOwner.threshold, pChainOwner.addresses.length);
        }
        if (pChainOwner.threshold > pChainOwner.addresses.length) {
            revert InvalidPChainOwnerThreshold(pChainOwner.threshold, pChainOwner.addresses.length);
        }
        if (pChainOwner.addresses.length > 0 && pChainOwner.addresses[0] == address(0)) {
            revert ZeroAddress();
        }
        for (uint256 i = 1; i < pChainOwner.addresses.length; ++i) {
            if (
                pChainOwner.addresses[i] < pChainOwner.addresses[i - 1] ||
                pChainOwner.addresses[i] == pChainOwner.addresses[i - 1]
            ) {
                revert InvalidPChainOwnerAddresses();
            }
        }
    }

    /**
     * @notice Get and verify Warp message from P-Chain
     * @dev Copied from Avalanche ValidatorManager
     * @param messageIndex The index of the Warp message to retrieve
     * @return warpMessage The verified Warp message from P-Chain
     */
    function _getPChainWarpMessage(uint32 messageIndex) internal view returns (WarpMessage memory) {
        (WarpMessage memory warpMessage, bool valid) =
            WARP_MESSENGER.getVerifiedWarpMessage(messageIndex);

        if (!valid) {
            revert InvalidWarpMessage();
        }
        if (warpMessage.sourceChainID != P_CHAIN_BLOCKCHAIN_ID) {
            revert InvalidWarpSourceChainID(warpMessage.sourceChainID);
        }
        if (warpMessage.originSenderAddress != address(0)) {
            revert InvalidWarpOriginSenderAddress(warpMessage.originSenderAddress);
        }

        return warpMessage;
    }

    /**
     * @notice Check and update churn tracker to prevent rapid turnover
     * @dev Copied from Avalanche ValidatorManager
     * @param newWeight The new weight being added/updated to
     * @param oldWeight The old weight being removed/updated from
     */
    function _checkAndUpdateChurnTracker(uint64 newWeight, uint64 oldWeight) internal {
        // Reset churn period if expired
        /* solhint-disable not-rely-on-time */
        if (
            block.timestamp > churnTracker.startTime + churnPeriodSeconds ||
            block.timestamp == churnTracker.startTime + churnPeriodSeconds
        ) {
            churnTracker.startTime = block.timestamp;
            /* solhint-enable not-rely-on-time */
            churnTracker.initialWeight = churnTracker.totalWeight;
            churnTracker.churnAmount = 0;
        }

        // Calculate weight delta
        uint64 weightDelta;
        if (newWeight > oldWeight) {
            weightDelta = newWeight - oldWeight;
        } else {
            weightDelta = oldWeight - newWeight;
        }

        // Check if this would exceed churn limit
        uint64 newChurnAmount = churnTracker.churnAmount + weightDelta;
        uint64 churnLimit = (churnTracker.initialWeight * maximumChurnPercentage) / 100;

        if (newChurnAmount > churnLimit) {
            revert ExceededChurnLimit(newChurnAmount, churnLimit);
        }

        // Update churn tracker
        churnTracker.churnAmount = newChurnAmount;
        churnTracker.totalWeight = churnTracker.totalWeight - oldWeight + newWeight;
        totalWeight = totalWeight - oldWeight + newWeight;
    }

    /**
     * @notice Convert variable-length nodeID to fixed 20-byte representation
     * @dev Copied from Avalanche ValidatorManager
     * @param nodeID The variable-length NodeID to convert
     * @return fixedNodeID The fixed 20-byte representation
     */
    function _fixedNodeID(bytes memory nodeID) internal pure returns (bytes20) {
        bytes20 fixedNodeID;
        for (uint256 i = 0; i < NODE_ID_LENGTH; ++i) {
            fixedNodeID |= bytes20(bytes1(nodeID[i])) >> (i * 8);
        }
        return fixedNodeID;
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get validator info by validation ID
     * @param validationID The validation ID
     * @return validator The validator information
     */
    function getValidator(bytes32 validationID) public view returns (Validator memory) {
        return validationPeriods[validationID];
    }

    /**
     * @notice Get validation ID from NodeID
     * @param nodeID The NodeID to look up
     * @return validationID The validation ID (0 if not registered)
     */
    function getNodeValidationID(bytes calldata nodeID) public view returns (bytes32) {
        return registeredValidators[nodeID];
    }

    /**
     * @notice Check if validator is currently active
     * @param nodeID The NodeID to check
     * @return active True if validator is active
     */
    function isActive(bytes calldata nodeID) public view returns (bool) {
        bytes32 validationID = registeredValidators[nodeID];
        if (validationID == bytes32(0)) {
            return false;
        }
        return validationPeriods[validationID].status == ValidatorStatus.Active;
    }

    /**
     * @notice Get total active validator weight
     * @return weight The total weight
     */
    function l1TotalWeight() public view returns (uint64) {
        return totalWeight;
    }

    /**
     * @notice Check if validator set has been initialized
     * @return initialized True if initialized
     */
    function isValidatorSetInitialized() public view returns (bool) {
        return _initializedValidatorSet;
    }

    /**
     * @notice Get current churn tracker information
     * @return churnPeriod The churn period in seconds
     * @return maxChurnPct The maximum churn percentage
     * @return tracker The current churn tracker
     */
    function getChurnTracker() public view returns (
        uint64 churnPeriod,
        uint8 maxChurnPct,
        ValidatorChurnPeriod memory tracker
    ) {
        return (churnPeriodSeconds, maximumChurnPercentage, churnTracker);
    }
}
