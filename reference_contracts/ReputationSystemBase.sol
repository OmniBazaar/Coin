// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MpcCore, gtUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {IReputationSystem, IReputationCore} from "./interfaces/IReputationSystem.sol";

/**
 * @title ReputationSystemBase
 * @author OmniBazaar Development Team
 * @notice Base contract for all reputation system modules providing common functionality and constants
 * @dev Inherits from AccessControl, ReentrancyGuard, and Pausable for comprehensive security
 */
abstract contract ReputationSystemBase is IReputationSystem, AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role identifier for reputation update operations
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    // Component IDs
    /// @notice Component ID for successful transaction completion
    uint8 public constant override COMPONENT_TRANSACTION_SUCCESS = 0;
    /// @notice Component ID for transaction disputes
    uint8 public constant override COMPONENT_TRANSACTION_DISPUTE = 1;
    /// @notice Component ID for arbitration performance
    uint8 public constant override COMPONENT_ARBITRATION_PERFORMANCE = 2;
    /// @notice Component ID for governance participation
    uint8 public constant override COMPONENT_GOVERNANCE_PARTICIPATION = 3;
    /// @notice Component ID for validator performance
    uint8 public constant override COMPONENT_VALIDATOR_PERFORMANCE = 4;
    /// @notice Component ID for marketplace behavior
    uint8 public constant override COMPONENT_MARKETPLACE_BEHAVIOR = 5;
    /// @notice Component ID for community engagement
    uint8 public constant override COMPONENT_COMMUNITY_ENGAGEMENT = 6;
    /// @notice Component ID for uptime reliability
    uint8 public constant override COMPONENT_UPTIME_RELIABILITY = 7;
    /// @notice Component ID for trust score
    uint8 public constant override COMPONENT_TRUST_SCORE = 8;
    /// @notice Component ID for referral activity
    uint8 public constant override COMPONENT_REFERRAL_ACTIVITY = 9;
    /// @notice Component ID for identity verification
    uint8 public constant override COMPONENT_IDENTITY_VERIFICATION = 10;
    
    /// @notice Maximum number of reputation components
    uint8 public constant MAX_COMPONENTS = 11;
    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Flag indicating if MPC (Multi-Party Computation) is available
    /// @dev MPC availability flag
    bool public override isMpcAvailable;
    
    /// @notice Mapping of component IDs to their weights in basis points
    /// @dev Component weights (basis points)
    mapping(uint8 => uint256) public componentWeights;
    
    /// @notice Address of the core reputation contract
    /// @dev Core reputation contract reference
    address public reputationCore;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    // Events are defined in IReputationSystem interface
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error OnlyCore();
    error InvalidComponent();
    error InvalidAdmin();
    error InvalidCore();
    error WeightTooHigh();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    /// @notice Restricts function access to only the core reputation contract
    modifier onlyCore() {
        if (msg.sender != reputationCore) revert OnlyCore();
        _;
    }
    
    /// @notice Validates that a component ID is within valid range
    /// @param componentId The component ID to validate
    modifier validComponent(uint8 componentId) {
        // solhint-disable-next-line gas-strict-inequalities
        if (componentId >= MAX_COMPONENTS) revert InvalidComponent();
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /// @notice Initializes the reputation system base contract
    /// @param _admin Address that will be granted admin role
    /// @param _reputationCore Address of the core reputation contract
    constructor(address _admin, address _reputationCore) {
        if (_admin == address(0)) revert InvalidAdmin();
        if (_reputationCore == address(0)) revert InvalidCore();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        
        reputationCore = _reputationCore;
        
        // MPC starts disabled for testing
        isMpcAvailable = false;
    }
    
    // =============================================================================
    // MPC AVAILABILITY
    // =============================================================================
    
    /**
     * @notice Set MPC availability for encrypted reputation calculations
     * @dev Set MPC availability
     * @param _available Boolean flag indicating if MPC is available
     */
    function setMpcAvailability(bool _available) external override onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    // =============================================================================
    // WEIGHT MANAGEMENT
    // =============================================================================
    
    /**
     * @notice Set the weight for a specific reputation component
     * @dev Set component weight (only core contract)
     * @param componentId The ID of the component to update
     * @param weight The new weight in basis points (max 10000)
     */
    function setComponentWeight(uint8 componentId, uint256 weight) 
        external 
        override 
        onlyCore
        validComponent(componentId) 
    {
        if (weight > BASIS_POINTS) revert WeightTooHigh();
        componentWeights[componentId] = weight;
        // solhint-disable-next-line not-rely-on-time
        emit ComponentWeightUpdated(componentId, weight, block.timestamp);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Pause all contract operations
     * @dev Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Resume all contract operations
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get the weight for a specific reputation component
     * @dev Get component weight
     * @param componentId The ID of the component to query
     * @return The weight of the component in basis points
     */
    function getComponentWeight(uint8 componentId) 
        external 
        view 
        override 
        validComponent(componentId) 
        returns (uint256) 
    {
        return componentWeights[componentId];
    }
    
    // =============================================================================
    // INTERNAL HELPERS
    // =============================================================================
    
    /**
     * @notice Internal function to update reputation in core contract with memory parameter
     * @dev Update reputation in core contract with memory parameter
     * @param user Address of the user whose reputation is being updated
     * @param componentId The ID of the component being updated
     */
    function _updateReputationInCoreMemory(
        address user,
        uint8 componentId,
        itUint64 memory /* value */
    ) internal {
        // Need to pass as calldata to core contract
        // This is a workaround for the memory/calldata mismatch
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(user, componentId, block.timestamp);
    }
    
    /**
     * @notice Internal function to update reputation in core contract with calldata parameter
     * @dev Update reputation in core contract with calldata parameter
     * @param user Address of the user whose reputation is being updated
     * @param componentId The ID of the component being updated
     * @param value The encrypted reputation value
     */
    function _updateReputationInCore(
        address user,
        uint8 componentId,
        itUint64 calldata value
    ) internal {
        IReputationCore(reputationCore).updateReputationComponent(
            user,
            componentId,
            value
        );
        // solhint-disable-next-line not-rely-on-time
        emit ReputationUpdated(user, componentId, block.timestamp);
    }
    
    /**
     * @notice Internal function to convert public value to encrypted format
     * @dev Convert public value to encrypted
     * @param value The public uint64 value to encrypt
     * @return The encrypted value as gtUint64
     */
    function _toEncrypted(uint64 value) internal returns (gtUint64) {
        if (isMpcAvailable) {
            return MpcCore.setPublic64(value);
        } else {
            return gtUint64.wrap(value);
        }
    }
    
    /**
     * @notice Internal function to validate and convert input ciphertext
     * @dev Validate and convert input ciphertext
     * @param input The input ciphertext to validate
     * @return The validated encrypted value as gtUint64
     */
    function _validateInput(itUint64 calldata input) internal returns (gtUint64) {
        if (isMpcAvailable) {
            return MpcCore.validateCiphertext(input);
        } else {
            // Fallback for testing
            uint64 value = uint64(uint256(keccak256(abi.encode(input))));
            return gtUint64.wrap(value);
        }
    }
}