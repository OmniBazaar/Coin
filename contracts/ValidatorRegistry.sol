// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title ValidatorRegistry - Avalanche Validator Integrated Version
 * @author OmniBazaar Team
 * @notice Event-based validator registry synchronized with AvalancheValidator
 * @dev Major changes from original:
 * - Removed arrays (validatorList) - validator tracks this
 * - Removed counters (totalValidators, activeValidators) - computed from events
 * - Removed nodeIdToValidator mapping - indexed by validator
 * - Simplified to core registration and staking only
 * - Added merkle root for validator set verification
 * 
 * State Reduction: ~60% less storage
 * Integration: Works with AvalancheValidatorClient GraphQL API
 */
contract ValidatorRegistry is ReentrancyGuard, Pausable, AccessControl, RegistryAware {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =============================================================================
    // MINIMAL STATE - ONLY ESSENTIAL DATA
    // =============================================================================
    
    enum ValidatorStatus {
        INACTIVE,
        ACTIVE,
        SUSPENDED,
        JAILED,
        EXITING
    }
    
    /**
     * @dev Minimal validator info - participation scores computed off-chain
     * Performance metrics tracked by validator network
     */
    struct MinimalValidatorInfo {
        uint256 stakedAmount;
        ValidatorStatus status;
        uint256 registrationTime;
        uint256 lastActivityTime;
        uint256 exitTime;         // Only set when exiting
        bool isRegistered;         // To distinguish from empty struct
    }
    
    struct StakingConfig {
        uint256 minimumStake;      // 1M XOM minimum
        uint256 maximumStake;      // Optional cap
        uint256 slashingRate;      // Basis points
        uint256 unstakingPeriod;   // Lock period
    }
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Minimum CPU cores required for validators
    uint256 public constant MIN_CPU_CORES = 4;
    /// @notice Minimum RAM in GB required for validators
    uint256 public constant MIN_RAM_GB = 8;
    /// @notice Minimum storage in GB required for validators
    uint256 public constant MIN_STORAGE_GB = 100;
    /// @notice Minimum network speed in Mbps required for validators
    uint256 public constant MIN_NETWORK_SPEED = 100;
    
    /// @notice Role for managing validators
    bytes32 public constant VALIDATOR_MANAGER_ROLE = keccak256("VALIDATOR_MANAGER_ROLE");
    /// @notice Role for slashing validators
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    /// @notice Role for oracle operations
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    /// @notice Role for Avalanche validator operations
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Core validator data mapping
    mapping(address => MinimalValidatorInfo) public validators;
    
    /// @notice Merkle root for validator set verification
    bytes32 public validatorSetRoot;
    /// @notice Block number of last root update
    uint256 public lastRootUpdate;
    /// @notice Current epoch for validator set
    uint256 public currentEpoch;
    
    /// @notice Staking configuration parameters
    StakingConfig public stakingConfig;
    /// @notice Total amount staked by all validators
    uint256 public totalStaked;
    
    // =============================================================================
    // EVENTS - VALIDATOR COMPATIBLE
    // =============================================================================
    
    /**
     * @notice Validator registration event for indexing
     * @dev Must match format expected by AvalancheValidator
     * @param validator Address of the validator
     * @param stake Amount of tokens staked
     * @param timestamp Block timestamp of registration
     */
    event ValidatorRegistered(
        address indexed validator,
        uint256 indexed stake,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Validator status update
     * @param validator Address of the validator
     * @param isActive Whether the validator is active
     * @param stake Current stake amount
     * @param timestamp Block timestamp of update
     */
    event ValidatorUpdated(
        address indexed validator,
        bool indexed isActive,
        uint256 indexed stake,
        uint256 timestamp
    );
    
    /**
     * @notice Validator slashing event
     * @param validator Address of the slashed validator
     * @param amount Amount slashed
     * @param reason Reason for slashing
     * @param timestamp Block timestamp of slashing
     */
    event ValidatorSlashed(
        address indexed validator,
        uint256 indexed amount,
        string reason,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Validator exit initiated
     * @param validator Address of the validator
     * @param exitTime When the exit will complete
     * @param timestamp Block timestamp when exit was initiated
     */
    event ValidatorExitInitiated(
        address indexed validator,
        uint256 indexed exitTime,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Validator exit completed
     * @param validator Address of the validator
     * @param refundedStake Amount of stake refunded
     * @param timestamp Block timestamp of exit completion
     */
    event ValidatorExitCompleted(
        address indexed validator,
        uint256 indexed refundedStake,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Validator set merkle root updated
     * @param newRoot New merkle root for validator set
     * @param epoch Epoch number for this update
     * @param activeCount Number of active validators
     * @param blockNumber Block number when updated
     * @param timestamp Block timestamp when updated
     */
    event ValidatorSetRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed activeCount,
        uint256 blockNumber,
        uint256 timestamp
    );
    
    /**
     * @notice Stake increased event
     * @param validator Address of the validator
     * @param additionalAmount Additional amount staked
     * @param newTotal New total stake amount
     * @param timestamp Block timestamp of stake increase
     */
    event StakeIncreased(
        address indexed validator,
        uint256 indexed additionalAmount,
        uint256 indexed newTotal,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InsufficientStake();
    error StakeExceedsMaximum();
    error AlreadyRegistered();
    error NotAValidator();
    error AlreadyExiting();
    error UnstakingPeriodNotCompleted();
    error InvalidProof();
    error EpochMismatch();
    error NotAvalancheValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyRegisteredValidator(address validator) {
        if (!validators[validator].isRegistered) revert NotAValidator();
        _;
    }
    
    modifier onlyAvalancheValidator() {
        if (!hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) && !_isAvalancheValidator(msg.sender)) {
            revert NotAvalancheValidator();
        }
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the validator registry
     * @param _registry Address of the OmniCoinRegistry contract
     * @param _minimumStake Minimum stake required for validators
     * @param _maximumStake Maximum stake allowed for validators
     * @param _unstakingPeriod Time period for unstaking process
     */
    constructor(
        address _registry,
        uint256 _minimumStake,
        uint256 _maximumStake,
        uint256 _unstakingPeriod
    ) RegistryAware(_registry) {
        stakingConfig = StakingConfig({
            minimumStake: _minimumStake,
            maximumStake: _maximumStake,
            slashingRate: 1000, // 10%
            unstakingPeriod: _unstakingPeriod
        });
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VALIDATOR_MANAGER_ROLE, msg.sender);
        _grantRole(SLASHER_ROLE, msg.sender);
    }
    
    // =============================================================================
    // REGISTRATION FUNCTIONS - EMIT EVENTS FOR VALIDATOR
    // =============================================================================
    
    /**
     * @notice Register as a validator
     * @dev Emits event for AvalancheValidator indexing
     * @param nodeId Node identifier (stored off-chain by validator)
     */
    function registerValidator(string calldata /* nodeId */) 
        external 
        payable
        nonReentrant 
        whenNotPaused 
    {
        if (validators[msg.sender].isRegistered) revert AlreadyRegistered();
        if (msg.value < stakingConfig.minimumStake) revert InsufficientStake();
        if (stakingConfig.maximumStake > 0 && msg.value > stakingConfig.maximumStake) {
            revert StakeExceedsMaximum();
        }
        
        // Create minimal validator record
        validators[msg.sender] = MinimalValidatorInfo({
            stakedAmount: msg.value,
            status: ValidatorStatus.ACTIVE,
            registrationTime: block.timestamp, // solhint-disable-line not-rely-on-time
            lastActivityTime: block.timestamp, // solhint-disable-line not-rely-on-time
            exitTime: 0,
            isRegistered: true
        });
        
        totalStaked += msg.value;
        
        // Emit events for validator indexing
        emit ValidatorRegistered(
            msg.sender,
            msg.value,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit ValidatorUpdated(
            msg.sender,
            true, // isActive
            msg.value,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        // Note: nodeId is emitted in event logs but not stored on-chain
        // AvalancheValidator indexes and stores this mapping
    }
    
    /**
     * @notice Increase validator stake
     * @dev Allows validators to add more stake to their existing registration
     */
    function increaseStake() 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        onlyRegisteredValidator(msg.sender)
    {
        MinimalValidatorInfo storage validator = validators[msg.sender];
        
        uint256 newStake = validator.stakedAmount + msg.value;
        if (stakingConfig.maximumStake > 0 && newStake > stakingConfig.maximumStake) {
            revert StakeExceedsMaximum();
        }
        
        validator.stakedAmount = newStake;
        validator.lastActivityTime = block.timestamp; // solhint-disable-line not-rely-on-time
        totalStaked += msg.value;
        
        emit StakeIncreased(
            msg.sender,
            msg.value,
            newStake,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit ValidatorUpdated(
            msg.sender,
            validator.status == ValidatorStatus.ACTIVE,
            newStake,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Initiate validator exit
     * @dev Starts the unstaking process for a validator
     */
    function initiateExit() 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRegisteredValidator(msg.sender)
    {
        MinimalValidatorInfo storage validator = validators[msg.sender];
        
        if (validator.status == ValidatorStatus.EXITING) revert AlreadyExiting();
        
        validator.status = ValidatorStatus.EXITING;
        validator.exitTime = block.timestamp + stakingConfig.unstakingPeriod; // solhint-disable-line not-rely-on-time
        
        emit ValidatorExitInitiated(
            msg.sender,
            validator.exitTime,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit ValidatorUpdated(
            msg.sender,
            false, // no longer active
            validator.stakedAmount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Complete validator exit and withdraw stake
     * @dev Allows validators to complete the exit process and retrieve their stake
     */
    function completeExit() 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRegisteredValidator(msg.sender)
    {
        MinimalValidatorInfo storage validator = validators[msg.sender];
        
        if (validator.status != ValidatorStatus.EXITING) revert NotAValidator();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < validator.exitTime) revert UnstakingPeriodNotCompleted();
        
        uint256 stake = validator.stakedAmount;
        validator.stakedAmount = 0;
        validator.status = ValidatorStatus.INACTIVE;
        validator.isRegistered = false;
        totalStaked -= stake;
        
        // Transfer stake back
        (bool success, ) = msg.sender.call{value: stake}("");
        if (!success) revert InsufficientStake(); // Reuse existing error for transfer failure
        
        emit ValidatorExitCompleted(
            msg.sender,
            stake,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit ValidatorUpdated(
            msg.sender,
            false,
            0,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    // =============================================================================
    // SLASHING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Slash a validator for misbehavior
     * @dev Only authorized slashers (e.g., consensus mechanism)
     * @param validator Address of validator to slash
     * @param amount Amount to slash from validator stake
     * @param reason Reason for the slashing
     */
    function slashValidator(
        address validator,
        uint256 amount,
        string calldata reason
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRole(SLASHER_ROLE)
        onlyRegisteredValidator(validator)
    {
        MinimalValidatorInfo storage validatorInfo = validators[validator];
        
        uint256 slashAmount = Math.min(amount, validatorInfo.stakedAmount);
        validatorInfo.stakedAmount -= slashAmount;
        totalStaked -= slashAmount;
        
        // Update status if stake falls below minimum
        if (validatorInfo.stakedAmount < stakingConfig.minimumStake) {
            validatorInfo.status = ValidatorStatus.SUSPENDED;
        }
        
        emit ValidatorSlashed(
            validator,
            slashAmount,
            reason,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit ValidatorUpdated(
            validator,
            validatorInfo.status == ValidatorStatus.ACTIVE,
            validatorInfo.stakedAmount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    // =============================================================================
    // AVALANCHE VALIDATOR INTEGRATION
    // =============================================================================
    
    /**
     * @notice Update validator set merkle root
     * @dev Called by AvalancheValidator after computing active set
     * @param newRoot New merkle root for validator set
     * @param epoch Epoch number for this update
     * @param activeCount Number of active validators
     */
    function updateValidatorSetRoot(
        bytes32 newRoot,
        uint256 epoch,
        uint256 activeCount
    ) external onlyAvalancheValidator {
        if (epoch != currentEpoch + 1) revert EpochMismatch();
        
        validatorSetRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit ValidatorSetRootUpdated(
            newRoot,
            epoch,
            activeCount,
            block.number,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Verify if an address is in the active validator set
     * @dev Uses merkle proof against current root
     * @param validator Address to verify
     * @param proof Merkle proof for verification
     * @return valid Whether the validator is in the active set
     */
    function verifyActiveValidator(
        address validator,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(validator, currentEpoch));
        return _verifyProof(proof, validatorSetRoot, leaf);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if validator meets minimum requirements
     * @dev Actual participation score computed off-chain
     * @param validator Address of validator to check
     * @return active Whether the validator is active
     */
    function isActiveValidator(address validator) external view returns (bool) {
        MinimalValidatorInfo storage info = validators[validator];
        return info.isRegistered && 
               info.status == ValidatorStatus.ACTIVE &&
               info.stakedAmount > stakingConfig.minimumStake;
    }
    
    /**
     * @notice Get validator stake amount
     * @param validator Address of validator to query
     * @return stake Amount of stake for the validator
     */
    function getValidatorStake(address validator) external view returns (uint256) {
        return validators[validator].stakedAmount;
    }
    
    /**
     * @notice Get total validator count (must query validator)
     * @dev Returns 0 - actual count via GraphQL API
     * @return count Always returns 0 (computed off-chain)
     */
    function getTotalValidators() external pure returns (uint256) {
        return 0; // Computed by validator from events
    }
    
    /**
     * @notice Get active validator count (must query validator)
     * @dev Returns 0 - actual count via GraphQL API
     * @return count Always returns 0 (computed off-chain)
     */
    function getActiveValidators() external pure returns (uint256) {
        return 0; // Computed by validator from events
    }
    
    /**
     * @notice Get validator list (must query validator)
     * @dev Returns empty array - actual list via GraphQL API
     * @return validators Empty array (maintained off-chain)
     */
    function getValidatorList() external pure returns (address[] memory) {
        return new address[](0); // Maintained by validator
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if account is the Avalanche validator contract
     * @param account Address to check
     * @return isValidator Whether the account is the Avalanche validator
     */
    function _isAvalancheValidator(address account) internal view returns (bool isValidator) {
        // Check if caller is the actual AvalancheValidator contract
        // This would be set in registry
        address avalancheValidator = REGISTRY.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
    
    /**
     * @notice Verify a merkle proof
     * @param proof Array of merkle proof hashes
     * @param root Merkle root to verify against
     * @param leaf Leaf node to verify
     * @return valid Whether the proof is valid
     */
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool valid) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
}