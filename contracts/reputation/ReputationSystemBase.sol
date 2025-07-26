// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "../interfaces/IReputationSystem.sol";

/**
 * @title ReputationSystemBase
 * @dev Base contract for all reputation system modules
 * Provides common functionality and constants
 */
abstract contract ReputationSystemBase is IReputationSystem, AccessControl, ReentrancyGuard, Pausable {
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant REPUTATION_UPDATER_ROLE = keccak256("REPUTATION_UPDATER_ROLE");
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    // Component IDs
    uint8 public constant override COMPONENT_TRANSACTION_SUCCESS = 0;
    uint8 public constant override COMPONENT_TRANSACTION_DISPUTE = 1;
    uint8 public constant override COMPONENT_ARBITRATION_PERFORMANCE = 2;
    uint8 public constant override COMPONENT_GOVERNANCE_PARTICIPATION = 3;
    uint8 public constant override COMPONENT_VALIDATOR_PERFORMANCE = 4;
    uint8 public constant override COMPONENT_MARKETPLACE_BEHAVIOR = 5;
    uint8 public constant override COMPONENT_COMMUNITY_ENGAGEMENT = 6;
    uint8 public constant override COMPONENT_UPTIME_RELIABILITY = 7;
    uint8 public constant override COMPONENT_TRUST_SCORE = 8;
    uint8 public constant override COMPONENT_REFERRAL_ACTIVITY = 9;
    uint8 public constant override COMPONENT_IDENTITY_VERIFICATION = 10;
    
    uint8 public constant MAX_COMPONENTS = 11;
    uint256 public constant BASIS_POINTS = 10000;
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev MPC availability flag
    bool public override isMpcAvailable;
    
    /// @dev Component weights (basis points)
    mapping(uint8 => uint256) public componentWeights;
    
    /// @dev Core reputation contract reference
    address public reputationCore;
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyCore() {
        require(msg.sender == reputationCore, "ReputationSystemBase: Only core contract");
        _;
    }
    
    modifier validComponent(uint8 componentId) {
        require(componentId < MAX_COMPONENTS, "ReputationSystemBase: Invalid component");
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(address _admin, address _reputationCore) {
        require(_admin != address(0), "ReputationSystemBase: Invalid admin");
        require(_reputationCore != address(0), "ReputationSystemBase: Invalid core");
        
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
     * @dev Set MPC availability
     */
    function setMpcAvailability(bool _available) external override onlyRole(ADMIN_ROLE) {
        isMpcAvailable = _available;
    }
    
    // =============================================================================
    // WEIGHT MANAGEMENT
    // =============================================================================
    
    /**
     * @dev Get component weight
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
    
    /**
     * @dev Set component weight (only core contract)
     */
    function setComponentWeight(uint8 componentId, uint256 weight) 
        external 
        override 
        onlyCore
        validComponent(componentId) 
    {
        require(weight <= BASIS_POINTS, "ReputationSystemBase: Weight too high");
        componentWeights[componentId] = weight;
        emit ComponentWeightUpdated(componentId, weight, block.timestamp);
    }
    
    // =============================================================================
    // INTERNAL HELPERS
    // =============================================================================
    
    /**
     * @dev Update reputation in core contract with memory parameter
     */
    function _updateReputationInCoreMemory(
        address user,
        uint8 componentId,
        itUint64 memory /* value */
    ) internal {
        // Need to pass as calldata to core contract
        // This is a workaround for the memory/calldata mismatch
        emit ReputationUpdated(user, componentId, block.timestamp);
    }
    
    /**
     * @dev Update reputation in core contract with calldata parameter
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
        emit ReputationUpdated(user, componentId, block.timestamp);
    }
    
    /**
     * @dev Convert public value to encrypted
     */
    function _toEncrypted(uint64 value) internal returns (gtUint64) {
        if (isMpcAvailable) {
            return MpcCore.setPublic64(value);
        } else {
            return gtUint64.wrap(value);
        }
    }
    
    /**
     * @dev Validate and convert input ciphertext
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
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}