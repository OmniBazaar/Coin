// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title ValidatorSync
 * @author OmniBazaar Team
 * @notice Manages synchronization between validator off-chain database and on-chain state
 * @dev Manages synchronization between validator off-chain database and on-chain state
 * 
 * Features:
 * - Periodic state root updates from validator consensus
 * - Merkle proof verification for state queries
 * - Batch state updates for gas efficiency
 * - Emergency pause mechanism
 */
contract ValidatorSync is RegistryAware, AccessControl, Pausable {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct StateUpdate {
        bytes32 stateRoot;
        uint256 blockNumber;
        uint256 timestamp;
        bool finalized;
        address[] validators;
        bytes[] signatures;
    }
    
    struct ValidatorSignature {
        address validator;
        bytes signature;
        uint256 timestamp;
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role identifier for validators who can propose and sign state updates
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    
    /// @notice Role identifier for sync managers who can update sync parameters
    bytes32 public constant SYNC_MANAGER_ROLE = keccak256("SYNC_MANAGER_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Current state root representing the latest synchronized state
    bytes32 public currentStateRoot;
    
    /// @notice Mapping of state update ID to update details
    mapping(uint256 => StateUpdate) public stateUpdates;
    
    /// @notice Counter for state updates, incremented for each new proposal
    uint256 public updateCounter;
    
    /// @notice Minimum validators required for state update to be finalized
    uint256 public requiredValidators;
    
    /// @notice Sync interval in seconds between allowed state updates
    uint256 public syncInterval;
    
    /// @notice Last sync timestamp when a state update was finalized
    uint256 public lastSyncTime;
    
    /// @notice Tracks which validators have signed a specific update
    mapping(uint256 => mapping(address => bool)) public hasSignedUpdate;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when the state root is updated
    /// @param updateId The ID of the state update
    /// @param newRoot The new state root
    /// @param previousRoot The previous state root
    /// @param timestamp The timestamp of the update
    event StateRootUpdated(
        uint256 indexed updateId,
        bytes32 indexed newRoot,
        bytes32 indexed previousRoot,
        uint256 timestamp
    );
    
    /// @notice Emitted when a validator adds their signature to a state update
    /// @param updateId The ID of the state update
    /// @param validator The address of the validator
    /// @param timestamp The timestamp when the signature was added
    event ValidatorSignatureAdded(
        uint256 indexed updateId,
        address indexed validator,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a state update is finalized with enough signatures
    /// @param updateId The ID of the state update
    /// @param stateRoot The finalized state root
    /// @param validatorCount The number of validators who signed
    event StateUpdateFinalized(
        uint256 indexed updateId,
        bytes32 indexed stateRoot,
        uint256 indexed validatorCount
    );
    
    /// @notice Emitted when the sync interval is updated
    /// @param oldInterval The previous sync interval
    /// @param newInterval The new sync interval
    event SyncIntervalUpdated(uint256 indexed oldInterval, uint256 indexed newInterval);
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error TooEarlyForUpdate();
    error InvalidStateRoot();
    error FutureBlockNotAllowed();
    error AlreadyFinalized();
    error AlreadySigned();
    error InvalidInterval();
    error InvalidRequirement();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /// @notice Initializes the ValidatorSync contract
    /// @param _registry The address of the registry contract
    /// @param _syncInterval The initial sync interval in seconds
    constructor(
        address _registry,
        uint256 _syncInterval
    ) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SYNC_MANAGER_ROLE, msg.sender);
        
        syncInterval = _syncInterval;
        requiredValidators = 3; // Default minimum
        // solhint-disable-next-line not-rely-on-time
        lastSyncTime = block.timestamp;
    }
    
    // =============================================================================
    // STATE UPDATE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Propose a new state root update
     * @dev Only validators can propose updates, subject to sync interval
     * @param newStateRoot The new state root hash
     * @param blockNumber The block number this state represents
     * @return updateId The ID of the newly created state update
     */
    function proposeStateUpdate(
        bytes32 newStateRoot,
        uint256 blockNumber
    ) external onlyRole(VALIDATOR_ROLE) whenNotPaused returns (uint256 updateId) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < lastSyncTime + syncInterval) revert TooEarlyForUpdate();
        if (newStateRoot == bytes32(0)) revert InvalidStateRoot();
        if (blockNumber > block.number) revert FutureBlockNotAllowed();
        
        updateId = updateCounter;
        ++updateCounter;
        
        stateUpdates[updateId] = StateUpdate({
            stateRoot: newStateRoot,
            blockNumber: blockNumber,
            // solhint-disable-next-line not-rely-on-time
            timestamp: block.timestamp,
            finalized: false,
            validators: new address[](0),
            signatures: new bytes[](0)
        });
        
        // Add proposer's signature
        _addValidatorSignature(updateId, msg.sender, "");
        
        return updateId;
    }
    
    /**
     * @notice Add validator signature to a state update
     * @dev Validators can sign pending updates to reach consensus
     * @param updateId The update ID to sign
     * @param signature The validator's signature
     */
    function signStateUpdate(
        uint256 updateId,
        bytes calldata signature
    ) external onlyRole(VALIDATOR_ROLE) whenNotPaused {
        StateUpdate storage update = stateUpdates[updateId];
        if (update.finalized) revert AlreadyFinalized();
        if (hasSignedUpdate[updateId][msg.sender]) revert AlreadySigned();
        
        _addValidatorSignature(updateId, msg.sender, signature);
        
        // Check if we have enough signatures to finalize
        if (update.validators.length > requiredValidators - 1) {
            _finalizeStateUpdate(updateId);
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update sync interval
     * @dev Only sync managers can update the interval
     * @param newInterval New sync interval in seconds
     */
    function updateSyncInterval(
        uint256 newInterval
    ) external onlyRole(SYNC_MANAGER_ROLE) {
        if (newInterval == 0) revert InvalidInterval();
        uint256 oldInterval = syncInterval;
        syncInterval = newInterval;
        emit SyncIntervalUpdated(oldInterval, newInterval);
    }
    
    /**
     * @notice Update required validators for consensus
     * @dev Only admin can update the required validator count
     * @param newRequired New number of required validators
     */
    function updateRequiredValidators(
        uint256 newRequired
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRequired == 0) revert InvalidRequirement();
        requiredValidators = newRequired;
    }
    
    /**
     * @notice Emergency pause
     * @dev Pauses all state update operations
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause
     * @dev Resumes all state update operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify a merkle proof against current state root
     * @dev Computes the merkle root from leaf and proof, compares with current state root
     * @param leaf The leaf value to verify
     * @param proof The merkle proof
     * @return valid True if the proof is valid, false otherwise
     */
    function verifyMerkleProof(
        bytes32 leaf,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement || computedHash == proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
            unchecked {
                ++i;
            }
        }
        
        valid = computedHash == currentStateRoot;
    }
    
    /**
     * @notice Get state update details
     * @dev Returns the complete state update information
     * @param updateId The update ID
     * @return stateRoot The state root of the update
     * @return blockNumber The block number of the update
     * @return timestamp The timestamp of the update
     * @return validators Array of validators who signed
     * @return finalized Whether the update is finalized
     */
    function getStateUpdate(uint256 updateId) external view returns (
        bytes32 stateRoot,
        uint256 blockNumber,
        uint256 timestamp,
        address[] memory validators,
        bool finalized
    ) {
        StateUpdate storage update = stateUpdates[updateId];
        return (
            update.stateRoot,
            update.blockNumber,
            update.timestamp,
            update.validators,
            update.finalized
        );
    }
    
    /**
     * @notice Check if we can propose a new update
     * @dev Returns true if enough time has passed since last sync
     * @return canPropose True if a new update can be proposed
     */
    function canProposeUpdate() external view returns (bool canPropose) {
        // solhint-disable-next-line not-rely-on-time
        canPropose = block.timestamp > lastSyncTime + syncInterval - 1;
    }
    
    /**
     * @notice Get time until next sync allowed
     * @dev Returns 0 if sync can happen now
     * @return timeRemaining Seconds until next sync is allowed
     */
    function timeUntilNextSync() external view returns (uint256 timeRemaining) {
        uint256 nextSyncTime = lastSyncTime + syncInterval;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > nextSyncTime - 1) {
            timeRemaining = 0;
        } else {
            // solhint-disable-next-line not-rely-on-time
            timeRemaining = nextSyncTime - block.timestamp;
        }
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Internal function to add validator signature
     * @dev Adds validator and signature to the state update arrays
     * @param updateId The ID of the state update
     * @param validator The address of the validator
     * @param signature The signature bytes
     */
    function _addValidatorSignature(
        uint256 updateId,
        address validator,
        bytes memory signature
    ) internal {
        StateUpdate storage update = stateUpdates[updateId];
        
        update.validators.push(validator);
        update.signatures.push(signature);
        hasSignedUpdate[updateId][validator] = true;
        
        // solhint-disable-next-line not-rely-on-time
        emit ValidatorSignatureAdded(updateId, validator, block.timestamp);
    }
    
    /**
     * @notice Finalize state update once enough signatures collected
     * @dev Updates the current state root and emits finalization events
     * @param updateId The ID of the state update to finalize
     */
    function _finalizeStateUpdate(uint256 updateId) internal {
        StateUpdate storage update = stateUpdates[updateId];
        if (update.finalized) revert AlreadyFinalized();
        
        bytes32 previousRoot = currentStateRoot;
        currentStateRoot = update.stateRoot;
        update.finalized = true;
        // solhint-disable-next-line not-rely-on-time
        lastSyncTime = block.timestamp;
        
        emit StateRootUpdated(
            updateId,
            update.stateRoot,
            previousRoot,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
        );
        
        emit StateUpdateFinalized(
            updateId,
            update.stateRoot,
            update.validators.length
        );
    }
}