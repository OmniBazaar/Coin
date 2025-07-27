// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title ValidatorSync
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
        address[] validators;
        bytes[] signatures;
        bool finalized;
    }
    
    struct ValidatorSignature {
        address validator;
        bytes signature;
        uint256 timestamp;
    }
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    bytes32 public constant SYNC_MANAGER_ROLE = keccak256("SYNC_MANAGER_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev Current state root
    bytes32 public currentStateRoot;
    
    /// @dev Mapping of state update ID to update details
    mapping(uint256 => StateUpdate) public stateUpdates;
    
    /// @dev Counter for state updates
    uint256 public updateCounter;
    
    /// @dev Minimum validators required for state update
    uint256 public requiredValidators;
    
    /// @dev Sync interval in seconds
    uint256 public syncInterval;
    
    /// @dev Last sync timestamp
    uint256 public lastSyncTime;
    
    /// @dev Pending state update signatures
    mapping(uint256 => mapping(address => bool)) public hasSignedUpdate;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event StateRootUpdated(
        uint256 indexed updateId,
        bytes32 indexed newRoot,
        bytes32 indexed previousRoot,
        uint256 timestamp
    );
    
    event ValidatorSignatureAdded(
        uint256 indexed updateId,
        address indexed validator,
        uint256 timestamp
    );
    
    event StateUpdateFinalized(
        uint256 indexed updateId,
        bytes32 stateRoot,
        uint256 validatorCount
    );
    
    event SyncIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    
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
    
    constructor(
        address _registry,
        uint256 _syncInterval
    ) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SYNC_MANAGER_ROLE, msg.sender);
        
        syncInterval = _syncInterval;
        requiredValidators = 3; // Default minimum
        lastSyncTime = block.timestamp;
    }
    
    // =============================================================================
    // STATE UPDATE FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Propose a new state root update
     * @param newStateRoot The new state root hash
     * @param blockNumber The block number this state represents
     */
    function proposeStateUpdate(
        bytes32 newStateRoot,
        uint256 blockNumber
    ) external onlyRole(VALIDATOR_ROLE) whenNotPaused returns (uint256) {
        if (block.timestamp < lastSyncTime + syncInterval) revert TooEarlyForUpdate();
        if (newStateRoot == bytes32(0)) revert InvalidStateRoot();
        if (blockNumber > block.number) revert FutureBlockNotAllowed();
        
        uint256 updateId = updateCounter;
        ++updateCounter;
        
        stateUpdates[updateId] = StateUpdate({
            stateRoot: newStateRoot,
            blockNumber: blockNumber,
            timestamp: block.timestamp,
            validators: new address[](0),
            signatures: new bytes[](0),
            finalized: false
        });
        
        // Add proposer's signature
        _addValidatorSignature(updateId, msg.sender, "");
        
        return updateId;
    }
    
    /**
     * @dev Add validator signature to a state update
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
        if (update.validators.length >= requiredValidators) {
            _finalizeStateUpdate(updateId);
        }
    }
    
    /**
     * @dev Internal function to add validator signature
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
        
        emit ValidatorSignatureAdded(updateId, validator, block.timestamp);
    }
    
    /**
     * @dev Finalize state update once enough signatures collected
     */
    function _finalizeStateUpdate(uint256 updateId) internal {
        StateUpdate storage update = stateUpdates[updateId];
        if (update.finalized) revert AlreadyFinalized();
        
        bytes32 previousRoot = currentStateRoot;
        currentStateRoot = update.stateRoot;
        update.finalized = true;
        lastSyncTime = block.timestamp;
        
        emit StateRootUpdated(
            updateId,
            update.stateRoot,
            previousRoot,
            block.timestamp
        );
        
        emit StateUpdateFinalized(
            updateId,
            update.stateRoot,
            update.validators.length
        );
    }
    
    // =============================================================================
    // MERKLE PROOF VERIFICATION
    // =============================================================================
    
    /**
     * @dev Verify a merkle proof against current state root
     * @param leaf The leaf value to verify
     * @param proof The merkle proof
     */
    function verifyMerkleProof(
        bytes32 leaf,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == currentStateRoot;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Update sync interval
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
     * @dev Update required validators for consensus
     * @param newRequired New number of required validators
     */
    function updateRequiredValidators(
        uint256 newRequired
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRequired == 0) revert InvalidRequirement();
        requiredValidators = newRequired;
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get state update details
     * @param updateId The update ID
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
     * @dev Check if we can propose a new update
     */
    function canProposeUpdate() external view returns (bool) {
        return block.timestamp >= lastSyncTime + syncInterval;
    }
    
    /**
     * @dev Get time until next sync allowed
     */
    function timeUntilNextSync() external view returns (uint256) {
        uint256 nextSyncTime = lastSyncTime + syncInterval;
        if (block.timestamp >= nextSyncTime) {
            return 0;
        }
        return nextSyncTime - block.timestamp;
    }
}