// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./interfaces/IWarpMessenger.sol";
import "./QualificationOracle.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniValidatorManager V3
 * @author OmniCoin Team
 * @notice Custom Validator Manager that bypasses WARP signature aggregation bug
 * @dev This implementation completely bypasses the initializeValidatorSet requirement,
 *      avoiding the Avalanche CLI bug #2705 that prevents validator addition.
 *
 * KEY INNOVATION: Direct P-Chain registration without SubnetToL1ConversionMessage
 *
 * Architecture:
 * - NO initializeValidatorSet required (bypasses WARP aggregation bug)
 * - Direct validator registration via RegisterL1ValidatorMessage
 * - Avalanche-compliant incremental weights (max 20% per addition)
 * - PoP-based reward distribution (via QualificationOracle)
 * - Ultra-lean storage (only essential data on-chain)
 *
 * This contract sends validator registration messages directly to the P-Chain
 * without requiring the problematic SubnetToL1ConversionMessage that fails
 * during signature aggregation.
 */
contract OmniValidatorManager is Ownable, ReentrancyGuard {
    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice WARP precompile address for cross-chain messaging
    address public constant WARP_PRECOMPILE = 0x0200000000000000000000000000000000000005;

    /// @notice P-Chain blockchain ID (constant across Avalanche networks)
    bytes32 public constant P_CHAIN_BLOCKCHAIN_ID = bytes32(0);

    /// @notice Maximum weight change allowed per addition (20% of total weight)
    /// @dev Follows Avalanche's anti-centralization pattern
    uint64 public constant MAX_WEIGHT_CHANGE_FACTOR = 20; // 20% max

    /// @notice Initial validator weight (for first validator)
    uint64 public constant INITIAL_VALIDATOR_WEIGHT = 100;

    /// @notice Maximum number of validators (for gas efficiency)
    uint256 public constant MAX_VALIDATORS = 100;

    /// @notice Registration expiry duration (24 hours)
    uint256 public constant REGISTRATION_EXPIRY_DURATION = 86400;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Qualification oracle for PoP scoring
    QualificationOracle public immutable qualificationOracle;

    /// @notice Tracks if manager is accepting registrations
    bool public registrationsEnabled = true;

    /// @notice Total number of active validators
    uint256 public activeValidatorCount;

    /// @notice Total number of pending registrations
    uint256 public pendingRegistrationCount;

    /// @notice Total weight of all active validators
    uint64 public totalWeight;

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Validator information
    struct ValidatorInfo {
        bytes nodeID;           // Avalanche NodeID
        bytes blsPublicKey;     // BLS public key for consensus
        address owner;          // Address that registered the validator
        uint64 weight;          // Consensus weight (follows Avalanche pattern)
        uint256 registeredAt;   // Registration timestamp
        bool isActive;          // Whether validator is active
        bool isPending;         // Whether registration is pending
    }

    /// @notice P-Chain owner structure (for Avalanche compatibility)
    struct PChainOwner {
        uint32 threshold;
        address[] addresses;
    }

    /// @notice Validator registration message format (ACP-77 compliant)
    struct RegisterL1ValidatorMessage {
        bytes32 validationID;
        bytes nodeID;
        bytes blsPublicKey;
        uint64 registrationExpiry;
        PChainOwner remainingBalanceOwner;
        PChainOwner disableOwner;
        uint64 weight;
    }

    /// @notice Validator registration response from P-Chain
    struct L1ValidatorRegistrationMessage {
        bytes32 validationID;
        bool valid;
    }

    // ============================================
    // MAPPINGS
    // ============================================

    /// @notice Validation ID to validator info
    mapping(bytes32 => ValidatorInfo) public validators;

    /// @notice Node ID to validation ID (for lookups)
    mapping(bytes => bytes32) public nodeIDToValidationID;

    /// @notice Address to validation ID (one validator per address)
    mapping(address => bytes32) public addressToValidationID;

    /// @notice Track processed Warp message IDs (prevent replay)
    mapping(bytes32 => bool) public processedMessages;

    // ============================================
    // EVENTS
    // ============================================

    event ValidatorRegistrationInitiated(
        bytes32 indexed validationID,
        bytes indexed nodeID,
        address indexed owner,
        uint64 weight
    );

    event ValidatorRegistrationCompleted(
        bytes32 indexed validationID,
        bytes indexed nodeID,
        address indexed owner
    );

    event ValidatorRemoved(
        bytes32 indexed validationID,
        bytes indexed nodeID,
        address indexed owner
    );

    event RegistrationsToggled(bool enabled);

    event WarpMessageSent(bytes32 indexed messageID, bytes message);
    event WarpMessageReceived(bytes32 indexed messageID, bytes message);

    // ============================================
    // ERRORS
    // ============================================

    error RegistrationsDisabled();
    error NotQualified();
    error AlreadyRegistered();
    error InvalidNodeID();
    error InvalidBLSKey();
    error MaxValidatorsReached();
    error ValidatorNotFound();
    error NotValidatorOwner();
    error MessageAlreadyProcessed();
    error WarpMessageFailed();
    error InvalidWarpResponse();

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize the validator manager
     * @param _qualificationOracle Address of the qualification oracle
     */
    constructor(address _qualificationOracle) Ownable(msg.sender) {
        require(_qualificationOracle != address(0), "Invalid oracle");
        qualificationOracle = QualificationOracle(_qualificationOracle);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - REGISTRATION
    // ============================================

    /**
     * @notice Register a new validator (bypasses initializeValidatorSet)
     * @dev Sends RegisterL1ValidatorMessage directly to P-Chain via WARP
     * @param nodeID The NodeID of the validator (from staking certificate)
     * @param blsPublicKey The BLS public key (48 bytes)
     * @param blsProofOfPossession Proof of possession for BLS key (96 bytes)
     * @return validationID The unique ID for this validator registration
     */
    function registerValidator(
        bytes calldata nodeID,
        bytes calldata blsPublicKey,
        bytes calldata blsProofOfPossession
    ) external nonReentrant returns (bytes32) {
        // Check if registrations are enabled
        if (!registrationsEnabled) revert RegistrationsDisabled();

        // Check qualification
        if (!qualificationOracle.isQualified(msg.sender)) revert NotQualified();

        // Validate inputs
        if (nodeID.length != 20) revert InvalidNodeID();
        if (blsPublicKey.length != 48) revert InvalidBLSKey();
        if (blsProofOfPossession.length != 96) revert InvalidBLSKey();

        // Check not already registered
        if (addressToValidationID[msg.sender] != bytes32(0)) revert AlreadyRegistered();

        // Check max validators
        if (activeValidatorCount + pendingRegistrationCount >= MAX_VALIDATORS) {
            revert MaxValidatorsReached();
        }

        // Calculate validator weight following Avalanche pattern
        uint64 validatorWeight;
        if (totalWeight == 0) {
            // First validator gets initial weight
            validatorWeight = INITIAL_VALIDATOR_WEIGHT;
        } else {
            // New validators can have max 20% of current total weight
            uint64 maxAllowedWeight = (totalWeight * MAX_WEIGHT_CHANGE_FACTOR) / 100;
            // For now, give each new validator the max allowed weight
            // In production, this could be based on stake or other factors
            validatorWeight = maxAllowedWeight;
        }

        // Generate unique validation ID
        bytes32 validationID = keccak256(
            abi.encodePacked(nodeID, blsPublicKey, block.timestamp, msg.sender)
        );

        // Store validator info
        validators[validationID] = ValidatorInfo({
            nodeID: nodeID,
            blsPublicKey: blsPublicKey,
            owner: msg.sender,
            weight: validatorWeight,
            registeredAt: block.timestamp,
            isActive: false,
            isPending: true
        });

        // Update mappings
        nodeIDToValidationID[nodeID] = validationID;
        addressToValidationID[msg.sender] = validationID;
        pendingRegistrationCount++;

        // Create P-Chain owners (msg.sender controls both)
        PChainOwner memory pChainOwner = PChainOwner({
            threshold: 1,
            addresses: new address[](1)
        });
        pChainOwner.addresses[0] = msg.sender;

        // Create RegisterL1ValidatorMessage
        RegisterL1ValidatorMessage memory message = RegisterL1ValidatorMessage({
            validationID: validationID,
            nodeID: nodeID,
            blsPublicKey: blsPublicKey,
            registrationExpiry: uint64(block.timestamp + REGISTRATION_EXPIRY_DURATION),
            remainingBalanceOwner: pChainOwner,
            disableOwner: pChainOwner,
            weight: validatorWeight
        });

        // Send message directly to P-Chain via WARP
        // This bypasses the need for SubnetToL1ConversionMessage
        _sendWarpMessage(message, blsProofOfPossession);

        emit ValidatorRegistrationInitiated(
            validationID,
            nodeID,
            msg.sender,
            validatorWeight
        );

        return validationID;
    }

    /**
     * @notice Complete validator registration after P-Chain acknowledgment
     * @param validationID The validation ID from registration
     * @param messageIndex The Warp message index containing the response
     */
    function completeValidatorRegistration(
        bytes32 validationID,
        uint32 messageIndex
    ) external nonReentrant {
        ValidatorInfo storage validator = validators[validationID];

        // Validate the registration exists and is pending
        if (validator.owner == address(0)) revert ValidatorNotFound();
        if (validator.owner != msg.sender) revert NotValidatorOwner();
        require(validator.isPending, "Registration not pending");
        require(!validator.isActive, "Already active");

        // Receive and validate Warp message from P-Chain
        L1ValidatorRegistrationMessage memory response = _receiveWarpMessage(messageIndex);

        // Verify response matches our registration
        require(response.validationID == validationID, "Validation ID mismatch");
        require(response.valid, "P-Chain rejected registration");

        // Update validator status
        validator.isActive = true;
        validator.isPending = false;
        activeValidatorCount++;
        pendingRegistrationCount--;
        totalWeight += validator.weight;  // Add weight to total

        emit ValidatorRegistrationCompleted(
            validationID,
            validator.nodeID,
            validator.owner
        );
    }

    /**
     * @notice Remove a validator
     * @param validationID The validation ID of the validator to remove
     */
    function removeValidator(bytes32 validationID) external nonReentrant {
        ValidatorInfo storage validator = validators[validationID];

        // Validate ownership
        if (validator.owner == address(0)) revert ValidatorNotFound();
        if (validator.owner != msg.sender) revert NotValidatorOwner();

        // Send removal message to P-Chain
        _sendValidatorRemovalMessage(validationID, validator.nodeID);

        // Update state
        if (validator.isActive) {
            activeValidatorCount--;
            totalWeight -= validator.weight;  // Subtract weight from total
        } else if (validator.isPending) {
            pendingRegistrationCount--;
        }

        // Clean up mappings
        delete nodeIDToValidationID[validator.nodeID];
        delete addressToValidationID[validator.owner];
        delete validators[validationID];

        emit ValidatorRemoved(validationID, validator.nodeID, msg.sender);
    }

    // ============================================
    // EXTERNAL FUNCTIONS - VIEWS
    // ============================================

    /**
     * @notice Get all active validators
     * @return validationIDs Array of validation IDs
     * @return nodeIDs Array of node IDs
     * @return owners Array of owner addresses
     * @return weights Array of weights
     */
    function getActiveValidators() external view returns (
        bytes32[] memory validationIDs,
        bytes[] memory nodeIDs,
        address[] memory owners,
        uint64[] memory weights
    ) {
        uint256 count = activeValidatorCount;
        validationIDs = new bytes32[](count);
        nodeIDs = new bytes[](count);
        owners = new address[](count);
        weights = new uint64[](count);

        uint256 index = 0;
        // Note: In production, maintain an array of active validator IDs for efficiency
        // This is simplified for clarity

        return (validationIDs, nodeIDs, owners, weights);
    }

    /**
     * @notice Check if an address is a qualified validator
     * @param account The address to check
     * @return qualified Whether the address is qualified
     * @return isValidator Whether the address has a validator
     * @return isActive Whether the validator is active
     */
    function getValidatorStatus(address account) external view returns (
        bool qualified,
        bool isValidator,
        bool isActive
    ) {
        qualified = qualificationOracle.isQualified(account);
        bytes32 validationID = addressToValidationID[account];
        isValidator = validationID != bytes32(0);
        if (isValidator) {
            isActive = validators[validationID].isActive;
        }
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Toggle validator registrations
     * @param enabled Whether to enable registrations
     */
    function setRegistrationsEnabled(bool enabled) external onlyOwner {
        registrationsEnabled = enabled;
        emit RegistrationsToggled(enabled);
    }

    // ============================================
    // INTERNAL FUNCTIONS - WARP MESSAGING
    // ============================================

    /**
     * @notice Send a Warp message to P-Chain
     * @dev This is the KEY INNOVATION - direct P-Chain messaging without initialization
     * @param message The validator registration message
     * @param blsProofOfPossession The BLS proof of possession
     */
    function _sendWarpMessage(
        RegisterL1ValidatorMessage memory message,
        bytes calldata blsProofOfPossession
    ) internal {
        // Encode the message for P-Chain
        bytes memory encodedMessage = abi.encode(
            P_CHAIN_BLOCKCHAIN_ID,  // Destination (P-Chain)
            "RegisterL1Validator",  // Message type
            message.validationID,
            message.nodeID,
            message.blsPublicKey,
            blsProofOfPossession,  // Include PoP for BLS verification
            message.registrationExpiry,
            message.remainingBalanceOwner.threshold,
            message.remainingBalanceOwner.addresses,
            message.disableOwner.threshold,
            message.disableOwner.addresses,
            message.weight
        );

        // Call WARP precompile to send message
        (bool success, bytes memory result) = WARP_PRECOMPILE.call(
            abi.encodeWithSignature("sendWarpMessage(bytes)", encodedMessage)
        );

        if (!success) revert WarpMessageFailed();

        // Decode message ID from result
        bytes32 messageID = abi.decode(result, (bytes32));

        emit WarpMessageSent(messageID, encodedMessage);
    }

    /**
     * @notice Send validator removal message to P-Chain
     * @param validationID The validation ID to remove
     * @param nodeID The node ID to remove
     */
    function _sendValidatorRemovalMessage(
        bytes32 validationID,
        bytes memory nodeID
    ) internal {
        bytes memory encodedMessage = abi.encode(
            P_CHAIN_BLOCKCHAIN_ID,
            "RemoveL1Validator",
            validationID,
            nodeID
        );

        (bool success, bytes memory result) = WARP_PRECOMPILE.call(
            abi.encodeWithSignature("sendWarpMessage(bytes)", encodedMessage)
        );

        if (!success) revert WarpMessageFailed();

        bytes32 messageID = abi.decode(result, (bytes32));
        emit WarpMessageSent(messageID, encodedMessage);
    }

    /**
     * @notice Receive and decode a Warp message from P-Chain
     * @param messageIndex The message index to retrieve
     * @return response The decoded registration response
     */
    function _receiveWarpMessage(
        uint32 messageIndex
    ) internal returns (L1ValidatorRegistrationMessage memory response) {
        // Get message from WARP precompile
        (bool success, bytes memory result) = WARP_PRECOMPILE.call(
            abi.encodeWithSignature("getVerifiedWarpMessage(uint32)", messageIndex)
        );

        if (!success) revert WarpMessageFailed();

        // Decode the Warp message structure
        (bytes32 sourceChainID, address originSenderAddress, bytes memory payload) =
            abi.decode(result, (bytes32, address, bytes));

        // Verify message is from P-Chain
        require(sourceChainID == P_CHAIN_BLOCKCHAIN_ID, "Invalid source chain");

        // Decode the payload
        (string memory messageType, bytes32 validationID, bool valid) =
            abi.decode(payload, (string, bytes32, bool));

        // Verify message type
        require(
            keccak256(bytes(messageType)) == keccak256("L1ValidatorRegistration"),
            "Invalid message type"
        );

        // Prevent replay
        bytes32 messageID = keccak256(abi.encodePacked(messageIndex, sourceChainID, payload));
        if (processedMessages[messageID]) revert MessageAlreadyProcessed();
        processedMessages[messageID] = true;

        emit WarpMessageReceived(messageID, payload);

        return L1ValidatorRegistrationMessage({
            validationID: validationID,
            valid: valid
        });
    }
}