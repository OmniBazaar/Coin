// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ERC2771ContextUpgradeable
} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title OmniCore
 * @author OmniCoin Development Team
 * @notice Upgradeable core contract with UUPS proxy pattern
 * @dev Ultra-lean core contract consolidating registry, validators, and minimal staking.
 *
 * SECURITY (H-01): The ADMIN_ROLE holder should be a TimelockController
 * (48-hour minimum delay) controlled by a multi-sig wallet (3-of-5) to
 * prevent instant abuse of UUPS upgrade, service registry, and validator
 * management functions. This is an operational deployment requirement,
 * not enforced in code since AccessControl already gates all admin calls.
 *
 * M-04: PausableUpgradeable added for emergency stops without requiring
 * a full UUPS upgrade. Applied to stake, unlock, deposit, withdraw,
 * and legacy claim functions.
 *
 * V3 Upgrade (2026-03):
 * - Added Bootstrap.sol integration for enumerable active node list
 * - getActiveNodes() returns gateways + service nodes from Bootstrap
 * - isValidator() falls back to Bootstrap if not in mapping
 * - reinitializeV3() sets bootstrapContract address
 *
 * @dev max-states-count disabled: Need 21+ states for comprehensive functionality.
 *      ordering disabled: Upgradeable contracts follow specific ordering pattern.
 */
/**
 * @title IBootstrap
 * @author OmniBazaar Team
 * @notice Minimal interface for Bootstrap.sol node registry
 * @dev Used by OmniCore V3 to enumerate active validators.
 *      Bootstrap.sol maintains an on-chain registry of gateway
 *      (type 0), computation (type 1), and listing (type 2) nodes.
 */
interface IBootstrap {
    /// @notice Check if a node is active and get its type
    /// @param nodeAddress Address of the node to check
    /// @return isActive Whether the node is currently active
    /// @return nodeType Node type (0=gateway, 1=computation, 2=listing)
    function isNodeActive(
        address nodeAddress
    ) external view returns (bool isActive, uint8 nodeType);

    /// @notice Get active nodes of a specific type
    /// @param nodeType Type of nodes to retrieve (0=gateway, 1=computation)
    /// @param limit Maximum number of nodes to return (0 = no limit)
    /// @return nodes Array of active node addresses
    function getActiveNodes(
        uint8 nodeType,
        uint256 limit
    ) external view returns (address[] memory nodes);
}

/* solhint-disable max-states-count, ordering */
// solhint-disable-next-line use-natspec
contract OmniCore is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    // Type declarations
    /// @notice Minimal stake information
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    // Constants
    /// @notice Admin role for governance operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for Avalanche validators
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");

    /// @notice Fee percentage for ODDAO (70% = 7000 basis points)
    uint256 public constant ODDAO_FEE_BPS = 7000;

    /// @notice Fee percentage for staking pool (20% = 2000 basis points)
    uint256 public constant STAKING_FEE_BPS = 2000;

    /// @notice Fee percentage for validator (10% = 1000 basis points)
    uint256 public constant VALIDATOR_FEE_BPS = 1000;

    /// @notice Total basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum number of validator signatures for multi-sig
    uint256 public constant MAX_REQUIRED_SIGNATURES = 5;

    /// @notice Maximum valid staking tier (H-02 remediation)
    uint256 public constant MAX_TIER = 5;

    /// @notice Number of valid lock duration options (0, 30d, 180d, 730d)
    uint256 public constant DURATION_COUNT = 4;

    // State variables (STORAGE LAYOUT - DO NOT REORDER!)
    /// @notice OmniCoin (XOM) ERC20 token contract reference
    /// @dev Variable name kept uppercase for backward compatibility.
    // solhint-disable-next-line var-name-mixedcase, use-natspec
    IERC20 public OMNI_COIN;

    /// @notice Service registry mapping service names to addresses
    mapping(bytes32 => address) public services;

    /// @notice Validator registry for active validators
    mapping(address => bool) public validators;

    /// @notice DEPRECATED: kept for UUPS storage layout compatibility. Do not use.
    bytes32 public masterRoot;

    /// @notice DEPRECATED: kept for UUPS storage layout compatibility. Do not use.
    uint256 public lastRootUpdate;

    /// @notice User stakes - minimal on-chain data
    mapping(address => Stake) public stakes;

    /// @notice Total staked amount for security
    uint256 public totalStaked;

    /// @notice DEX balances for settlement (user => token => amount)
    mapping(address => mapping(address => uint256)) public dexBalances;

    /// @notice ODDAO address for receiving 70% of DEX fees
    address public oddaoAddress;

    /// @notice Staking pool address for receiving 20% of DEX fees
    address public stakingPoolAddress;

    // Legacy Migration State (added 2025-08-06)
    /// @notice Reserved legacy usernames (username hash => reserved)
    mapping(bytes32 => bool) public legacyUsernames;

    /// @notice Legacy balances to be claimed (username hash => amount in 18 decimals)
    mapping(bytes32 => uint256) public legacyBalances;

    /// @notice Claimed legacy accounts (username hash => claim address)
    mapping(bytes32 => address) public legacyClaimed;

    /// @notice Legacy user account public keys (username hash => public key)
    mapping(bytes32 => bytes) public legacyAccounts;

    /// @notice Total legacy tokens to distribute
    uint256 public totalLegacySupply;

    /// @notice Total legacy tokens claimed so far
    uint256 public totalLegacyClaimed;

    /// @notice Required validator signatures for legacy claims (M-of-N multi-sig)
    uint256 public requiredSignatures;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Used legacy claim nonces (M-01: prevents signature replay)
    /// @dev Tracks nonces submitted via claimLegacyBalance() to prevent
    ///      reuse of validator-signed claim messages if the function is
    ///      ever repurposed in a future upgrade.
    mapping(bytes32 => bool) private _usedClaimNonces;

    /// @notice Checkpointed staking amounts for governance snapshot queries
    /// @dev Used by OmniGovernance.getVotingPowerAt() for flash-loan
    ///      protection. Writes on stake() and unlock().
    mapping(address => Checkpoints.Trace224) private _stakeCheckpoints;

    /// @notice Bootstrap.sol contract for enumerable active node registry
    /// @dev V3: Set via reinitializeV3(). Provides getActiveNodes() and
    ///      isNodeActive() for validator enumeration and type lookups.
    address public bootstrapContract;

    /// @notice Pending admin address for two-step admin transfer
    /// @dev V3 M-05 fix: Set by proposeAdminTransfer(), claimed via
    ///      acceptAdminTransfer(). Prevents accidental admin lockout.
    address public pendingAdmin;

    /// @notice Timestamp after which pending admin transfer can be accepted
    /// @dev V3: Must wait ADMIN_TRANSFER_DELAY (48h) after proposal
    uint256 public adminTransferEta;

    /// @notice Address of the admin who proposed the current pending transfer
    /// @dev V3 H-01 fix: Stored at proposal time so acceptAdminTransfer() can
    ///      revoke ADMIN_ROLE and DEFAULT_ADMIN_ROLE from the old admin.
    address public adminTransferProposer;

    /// @notice Storage gap for future upgrades (reserve 42 slots)
    /// @dev Reduced from 47 to 42: bootstrapContract + pendingAdmin
    ///      + adminTransferEta + adminTransferProposer + _usedClaimNonces
    uint256[42] private __gap;

    // Events
    /// @notice Emitted when a service is registered or updated
    /// @param name Service identifier
    /// @param serviceAddress Address of the service contract
    /// @param timestamp Block timestamp of update
    event ServiceUpdated(
        bytes32 indexed name,
        address indexed serviceAddress,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a validator is added or removed
    /// @param validator Address of the validator
    /// @param active Whether validator is active
    /// @param timestamp Block timestamp of change
    event ValidatorUpdated(
        address indexed validator,
        bool indexed active,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a legacy balance is claimed
    /// @param username Legacy username being claimed
    /// @param claimAddress Address receiving the tokens
    /// @param amount Amount of tokens claimed (18 decimals)
    /// @param timestamp Block timestamp of claim
    event LegacyBalanceClaimed(
        string indexed username,
        address indexed claimAddress,
        uint256 indexed amount,
        uint256 timestamp
    );

    /// @notice Emitted when legacy users are registered
    /// @param count Number of users registered
    /// @param totalAmount Total amount reserved for distribution
    event LegacyUsersRegistered(
        uint256 indexed count,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when tokens are staked
    /// @param user Address of the staker
    /// @param amount Amount of tokens staked
    /// @param tier Staking tier selected
    /// @param duration Lock duration in seconds
    event TokensStaked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed tier,
        uint256 duration
    );

    /// @notice Emitted when tokens are unlocked
    /// @param user Address of the staker
    /// @param amount Amount of tokens unlocked
    /// @param timestamp Block timestamp of unlock
    event TokensUnlocked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed timestamp
    );

    /// @notice Emitted when DEX trade is settled
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param token Token traded
    /// @param amount Amount traded
    /// @param orderId Off-chain order ID
    event DEXSettlement(
        address indexed buyer,
        address indexed seller,
        address indexed token,
        uint256 amount,
        bytes32 orderId
    );

    /// @notice Emitted when batch settlement occurs
    /// @param batchId Batch identifier
    /// @param count Number of settlements
    event BatchSettlement(
        bytes32 indexed batchId,
        uint256 indexed count
    );

    /// @notice Emitted when a settlement is skipped due to insufficient balance
    /// @param seller Seller address with insufficient balance
    /// @param token Token address
    /// @param amount Requested amount
    /// @param available Available balance
    event SettlementSkipped(
        address indexed seller,
        address indexed token,
        uint256 indexed amount,
        uint256 available
    );

    /// @notice Emitted when private DEX trade is settled
    /// @param buyer Buyer address (public)
    /// @param seller Seller address (public)
    /// @param token Token address on COTI (pXOM)
    /// @param encryptedAmount Encrypted amount (ctUint64 as bytes32)
    /// @param cotiTxHash COTI transaction hash
    /// @param cotiBlockNumber COTI block number
    event PrivateDEXSettlement(
        address indexed buyer,
        address indexed seller,
        address indexed token,
        bytes32 encryptedAmount,
        bytes32 cotiTxHash,
        uint256 cotiBlockNumber
    );

    /// @notice Emitted when batch private settlement occurs
    /// @param batchId Batch identifier
    /// @param count Number of settlements
    /// @param cotiBlockNumber COTI block number
    event BatchPrivateSettlement(
        bytes32 indexed batchId,
        uint256 indexed count,
        uint256 indexed cotiBlockNumber
    );

    /// @notice Emitted when required signatures count is updated
    /// @param newCount New required signature count
    event RequiredSignaturesUpdated(uint256 indexed newCount);

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when the ODDAO fee recipient address is updated
    /// @param oldAddress Previous ODDAO address
    /// @param newAddress New ODDAO address
    event OddaoAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    /// @notice Emitted when the staking pool fee recipient address is updated
    /// @param oldAddress Previous staking pool address
    /// @param newAddress New staking pool address
    event StakingPoolAddressUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    /// @notice Emitted when an admin transfer is proposed
    /// @param currentAdmin Address proposing the transfer
    /// @param newAdmin Proposed new admin address
    /// @param effectiveTimestamp When the transfer can be accepted
    event AdminTransferProposed(
        address indexed currentAdmin,
        address indexed newAdmin,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when an admin transfer is accepted
    /// @param oldAdmin Previous admin address
    /// @param newAdmin New admin address
    event AdminTransferAccepted(
        address indexed oldAdmin,
        address indexed newAdmin
    );

    /// @notice Emitted when a pending admin transfer is cancelled
    event AdminTransferCancelled();

    // Custom errors
    error InvalidAddress();
    error InvalidAmount();
    error InvalidSignature();
    error StakeNotFound();
    error StakeLocked();
    error Unauthorized();
    error DuplicateSigner();
    error InsufficientSignatures();
    /// @notice Thrown when staking tier does not match the staked amount
    error InvalidStakingTier();
    /// @notice Thrown when lock duration is not one of the valid options
    error InvalidDuration();
    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();
    /// @notice Thrown when admin transfer conditions are not met
    error AdminTransferNotReady();
    /// @notice Thrown when caller is not the pending admin
    error NotPendingAdmin();

    /**
     * @notice Constructor that disables initializers for the implementation contract
     * @dev Prevents the implementation contract from being initialized.
     *      Sets the trusted forwarder address as an immutable (stored in bytecode,
     *      not proxy storage). Pass address(0) to disable meta-transaction support.
     * @param trustedForwarder_ Address of the OmniForwarder contract for gasless relay
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the upgradeable OmniCore
     * @dev Replaces constructor, can only be called once
     * @param admin Address to grant admin role
     * @param _omniCoin Address of OmniCoin token
     * @param _oddaoAddress ODDAO fee recipient (70% of fees)
     * @param _stakingPoolAddress Staking pool fee recipient (20% of fees)
     */
    function initialize(
        address admin,
        address _omniCoin,
        address _oddaoAddress,
        address _stakingPoolAddress
    ) public initializer {
        if (admin == address(0) || _omniCoin == address(0) ||
            _oddaoAddress == address(0) || _stakingPoolAddress == address(0)) {
            revert InvalidAddress();
        }

        // Initialize inherited contracts
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Initialize state
        OMNI_COIN = IERC20(_omniCoin);
        oddaoAddress = _oddaoAddress;
        stakingPoolAddress = _stakingPoolAddress;
        requiredSignatures = 1;
    }

    /**
     * @notice V2 initializer — sets new state added after initial deployment
     * @dev Called once after upgradeProxy to initialize requiredSignatures.
     *      reinitializer(2) ensures it can only run once and cannot re-run initialize().
     *      Access restricted to ADMIN_ROLE to prevent front-running (M-05 remediation).
     */
    function initializeV2() external onlyRole(ADMIN_ROLE) reinitializer(2) {
        requiredSignatures = 1;
    }

    /**
     * @notice V3 initializer — sets Bootstrap.sol contract reference
     * @dev Called once via upgradeToAndCall() to set the bootstrap contract
     *      address for enumerable active node queries. Bootstrap provides
     *      getActiveNodes() and isNodeActive() replacing the non-enumerable
     *      validators mapping for node listing purposes.
     * @param _bootstrap Address of the Bootstrap.sol contract on L1
     */
    function reinitializeV3(
        address _bootstrap
    ) external onlyRole(ADMIN_ROLE) reinitializer(3) {
        if (_bootstrap == address(0)) revert InvalidAddress();
        bootstrapContract = _bootstrap;
    }

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Authorize contract upgrades
     * @dev Required by UUPSUpgradeable, only admin can upgrade.
     *      Reverts if contract is ossified.
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
    }

    // =============================================================================
    // Two-Step Admin Transfer (V3 M-05 fix)
    // =============================================================================

    /// @notice Delay for admin transfer (48 hours)
    uint256 public constant ADMIN_TRANSFER_DELAY = 48 hours;

    /**
     * @notice Propose transfer of ADMIN_ROLE to a new address
     * @dev V3 M-05 fix: Two-step admin transfer with 48h delay.
     *      Step 1: Current admin calls proposeAdminTransfer(newAdmin).
     *      Step 2: After 48h, newAdmin calls acceptAdminTransfer().
     *      Can be cancelled by current admin before acceptance.
     *      H-01 fix: Stores proposer address so acceptAdminTransfer()
     *      can revoke roles from the old admin.
     *      M-03: Uses msg.sender explicitly (not _msgSender()) to prevent
     *      admin operations from being relayed through the trusted forwarder.
     *      Admin operations must be signed directly by the admin key.
     * @param newAdmin Address to receive admin role
     */
    function proposeAdminTransfer(
        address newAdmin
    ) external onlyRole(ADMIN_ROLE) {
        if (newAdmin == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time
        uint256 eta = block.timestamp + ADMIN_TRANSFER_DELAY;
        pendingAdmin = newAdmin;
        adminTransferEta = eta;
        // M-03: Use msg.sender explicitly -- admin operations must not be relayed
        adminTransferProposer = msg.sender;
        emit AdminTransferProposed(msg.sender, newAdmin, eta);
    }

    /**
     * @notice Accept pending admin role transfer
     * @dev Must be called by the pending admin after the 48h delay.
     *      Grants both DEFAULT_ADMIN_ROLE and ADMIN_ROLE to the new
     *      admin (caller), then revokes both roles from the previous
     *      admin who proposed the transfer (H-01 fix).
     *      M-03: Uses msg.sender explicitly (not _msgSender()) to prevent
     *      admin transfer acceptance from being relayed through the forwarder.
     */
    function acceptAdminTransfer() external {
        // M-03: Use msg.sender explicitly -- admin operations must not be relayed
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < adminTransferEta) {
            revert AdminTransferNotReady();
        }

        address oldAdmin = adminTransferProposer;
        pendingAdmin = address(0);
        adminTransferEta = 0;
        adminTransferProposer = address(0);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _revokeRole(ADMIN_ROLE, oldAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);

        emit AdminTransferAccepted(oldAdmin, msg.sender);
    }

    /**
     * @notice Cancel a pending admin transfer
     * @dev Can only be called by current admin before acceptance.
     *      Clears all pending transfer state including the proposer.
     */
    function cancelAdminTransfer()
        external
        onlyRole(ADMIN_ROLE)
    {
        pendingAdmin = address(0);
        adminTransferEta = 0;
        adminTransferProposer = address(0);
        emit AdminTransferCancelled();
    }

    // =============================================================================
    // Service Registry & Validator Management
    // =============================================================================

    /**
     * @notice Register or update a service in the registry
     * @dev Only admin can update services
     * @param name Service identifier
     * @param serviceAddress Address of the service contract
     */
    function setService(bytes32 name, address serviceAddress) external onlyRole(ADMIN_ROLE) {
        if (serviceAddress == address(0)) revert InvalidAddress();
        services[name] = serviceAddress;
        emit ServiceUpdated(name, serviceAddress, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Add or remove a validator
     * @dev Only admin can manage validators
     * @param validator Address of the validator
     * @param active Whether validator should be active
     */
    function setValidator(address validator, bool active) external onlyRole(ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        validators[validator] = active;

        if (active) {
            _grantRole(AVALANCHE_VALIDATOR_ROLE, validator);
        } else {
            _revokeRole(AVALANCHE_VALIDATOR_ROLE, validator);
        }

        emit ValidatorUpdated(validator, active, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Set required number of validator signatures for legacy claims
     * @dev Only admin can change the multi-sig threshold
     * @param count Number of required signatures (1 to MAX_REQUIRED_SIGNATURES)
     */
    function setRequiredSignatures(uint256 count) external onlyRole(ADMIN_ROLE) {
        if (count == 0 || count > MAX_REQUIRED_SIGNATURES) revert InvalidAmount();
        requiredSignatures = count;
        emit RequiredSignaturesUpdated(count);
    }

    /**
     * @notice Update the ODDAO fee recipient address
     * @dev Only admin can change. Used during Pioneer Phase to replace
     *      temporary deployer address with real ODDAO treasury multisig.
     * @param newOddaoAddress New ODDAO address (must be non-zero)
     */
    function setOddaoAddress(address newOddaoAddress) external onlyRole(ADMIN_ROLE) {
        if (newOddaoAddress == address(0)) revert InvalidAddress();
        address oldAddress = oddaoAddress;
        oddaoAddress = newOddaoAddress;
        emit OddaoAddressUpdated(oldAddress, newOddaoAddress);
    }

    /**
     * @notice Update the staking pool fee recipient address
     * @dev Only admin can change. Used during Pioneer Phase to set the
     *      StakingRewardPool contract address after deployment.
     * @param newStakingPoolAddress New staking pool address (must be non-zero)
     */
    function setStakingPoolAddress(address newStakingPoolAddress) external onlyRole(ADMIN_ROLE) {
        if (newStakingPoolAddress == address(0)) revert InvalidAddress();
        address oldAddress = stakingPoolAddress;
        stakingPoolAddress = newStakingPoolAddress;
        emit StakingPoolAddressUpdated(oldAddress, newStakingPoolAddress);
    }

    /**
     * @notice Pause all staking, DEX, and legacy claim operations
     * @dev Only admin can pause. M-04 remediation: enables emergency stops
     *      without requiring a full UUPS upgrade.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause all operations
     * @dev Only admin can unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =============================================================================
    // Staking Functions
    // =============================================================================

    /**
     * @notice Stake tokens with minimal on-chain data
     * @dev Locks tokens on-chain, reward calculation done by StakingRewardPool.
     *      Validates tier against amount thresholds and duration against valid
     *      lock periods per OmniBazaar tokenomics (H-02 remediation).
     *
     * Tier thresholds (18-decimal XOM):
     *   Tier 1: >= 1 XOM           (5% APR)
     *   Tier 2: >= 1,000,000 XOM   (6% APR)
     *   Tier 3: >= 10,000,000 XOM  (7% APR)
     *   Tier 4: >= 100,000,000 XOM (8% APR)
     *   Tier 5: >= 1,000,000,000 XOM (9% APR)
     *
     * Valid durations: 0 (no commitment), 30 days, 180 days, 730 days
     *
     * @param amount Amount of tokens to stake
     * @param tier Staking tier (1-5, must match amount thresholds)
     * @param duration Lock duration in seconds (must be a valid duration option)
     */
    function stake(
        uint256 amount,
        uint256 tier,
        uint256 duration
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        address caller = _msgSender();
        if (stakes[caller].active) revert InvalidAmount();

        // H-02: Validate tier is within range and amount matches tier thresholds
        _validateStakingTier(amount, tier);

        // H-02: Validate duration is one of the allowed lock periods
        _validateDuration(duration);

        // Transfer tokens from user
        OMNI_COIN.safeTransferFrom(caller, address(this), amount);

        // Store minimal stake data
        stakes[caller] = Stake({
            amount: amount,
            tier: tier,
            duration: duration,
            lockTime: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            active: true
        });

        totalStaked += amount;

        // Write staking checkpoint for governance snapshot
        _stakeCheckpoints[caller].push(
            SafeCast.toUint32(block.number),
            SafeCast.toUint224(amount)
        );

        emit TokensStaked(caller, amount, tier, duration);
    }

    /**
     * @notice Unlock staked tokens after lock period
     * @dev Returns principal only. Rewards handled by StakingRewardPool contract.
     *      Call StakingRewardPool.snapshotRewards() BEFORE this to preserve rewards.
     */
    function unlock() external nonReentrant whenNotPaused {
        address caller = _msgSender();
        Stake storage userStake = stakes[caller];

        if (!userStake.active) revert StakeNotFound();
        if (block.timestamp < userStake.lockTime) revert StakeLocked(); // solhint-disable-line not-rely-on-time

        uint256 amount = userStake.amount;

        // Clear stake fully (L-05: clear all fields for storage hygiene)
        userStake.active = false;
        userStake.amount = 0;
        userStake.tier = 0;
        userStake.duration = 0;
        userStake.lockTime = 0;
        totalStaked -= amount;

        // Write zero checkpoint for governance snapshot
        _stakeCheckpoints[caller].push(
            SafeCast.toUint32(block.number),
            0
        );

        // Transfer tokens back
        OMNI_COIN.safeTransfer(caller, amount);

        emit TokensUnlocked(caller, amount, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // =============================================================================
    // DEX Settlement Functions
    // @deprecated Use DEXSettlement.sol for trustless EIP-712 settlement instead.
    //             These functions are kept for storage layout safety (dexBalances)
    //             and backward compatibility during migration.
    // =============================================================================

    /**
     * @notice Settle a DEX trade
     * @dev All order matching happens off-chain in validators
     * @param buyer Buyer address
     * @param seller Seller address
     * @param token Token being traded
     * @param amount Amount of tokens
     * @param orderId Off-chain order identifier
     * @dev DEPRECATED: Use DEXSettlement.sol settleTrade() with EIP-712 signatures
     */
    function settleDEXTrade(
        address buyer,
        address seller,
        address token,
        uint256 amount,
        bytes32 orderId
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) whenNotPaused {
        if (buyer == address(0) || seller == address(0) || token == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) revert InvalidAmount();

        // Simple balance transfer
        if (dexBalances[seller][token] < amount) revert InvalidAmount();

        dexBalances[seller][token] -= amount;
        dexBalances[buyer][token] += amount;

        emit DEXSettlement(buyer, seller, token, amount, orderId);
    }

    /**
     * @notice Batch settle multiple DEX trades
     * @dev Efficient batch processing for gas optimization
     * @param buyers Array of buyer addresses
     * @param sellers Array of seller addresses
     * @param tokens Array of token addresses
     * @param amounts Array of amounts
     * @param batchId Batch identifier
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless settlement
     */
    function batchSettleDEX(
        address[] calldata buyers,
        address[] calldata sellers,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32 batchId
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) whenNotPaused {
        uint256 length = buyers.length;
        if (length == 0 || length != sellers.length ||
            length != tokens.length || length != amounts.length) {
            revert InvalidAmount();
        }

        uint256 settled = 0;
        for (uint256 i = 0; i < length; ++i) {
            uint256 available = dexBalances[sellers[i]][tokens[i]];
            // solhint-disable-next-line gas-strict-inequalities
            if (available >= amounts[i]) {
                dexBalances[sellers[i]][tokens[i]] -= amounts[i];
                dexBalances[buyers[i]][tokens[i]] += amounts[i];
                ++settled;
            } else {
                emit SettlementSkipped(sellers[i], tokens[i], amounts[i], available);
            }
        }

        emit BatchSettlement(batchId, settled);
    }

    /**
     * @notice Distribute DEX fees
     * @dev Called by validators to distribute fees according to tokenomics
     * @param token Fee token
     * @param totalFee Total fee amount
     * @param validator Validator processing the transaction
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless fee distribution
     */
    function distributeDEXFees(
        address token,
        uint256 totalFee,
        address validator
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) whenNotPaused {
        if (totalFee == 0) return;

        // Calculate fee splits using basis points for precision
        uint256 oddaoFee = (totalFee * ODDAO_FEE_BPS) / BASIS_POINTS;
        uint256 stakingFee = (totalFee * STAKING_FEE_BPS) / BASIS_POINTS;
        uint256 validatorFee = totalFee - oddaoFee - stakingFee;

        if (oddaoFee > 0) {
            dexBalances[oddaoAddress][token] += oddaoFee;
        }
        if (stakingFee > 0) {
            dexBalances[stakingPoolAddress][token] += stakingFee;
        }
        if (validatorFee > 0) {
            dexBalances[validator][token] += validatorFee;
        }
    }

    // =============================================================================
    // Private DEX Settlement Functions (COTI V2 Integration)
    // @deprecated Use DEXSettlement.sol for trustless settlement
    // =============================================================================

    /**
     * @notice Settle a private DEX trade from COTI chain
     * @dev Called by validators after COTI PrivateDEX executes MPC matching
     * @param buyer Buyer address (public)
     * @param seller Seller address (public)
     * @param token Token address on COTI (pXOM)
     * @param encryptedAmount Encrypted trade amount from COTI MPC (ctUint64 as bytes32)
     * @param cotiTxHash Transaction hash on COTI chain (proof of execution)
     * @param cotiBlockNumber Block number on COTI chain
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless settlement
     */
    function settlePrivateDEXTrade(
        address buyer,
        address seller,
        address token,
        bytes32 encryptedAmount,
        bytes32 cotiTxHash,
        uint256 cotiBlockNumber
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) whenNotPaused {
        if (buyer == address(0) || seller == address(0)) revert InvalidAddress();
        if (token == address(0)) revert InvalidAddress();
        if (cotiTxHash == bytes32(0)) revert InvalidSignature();

        emit PrivateDEXSettlement(
            buyer,
            seller,
            token,
            encryptedAmount,
            cotiTxHash,
            cotiBlockNumber
        );
    }

    /**
     * @notice Batch settle multiple private DEX trades from COTI
     * @dev Gas optimization for multiple private trades in one transaction
     * @param buyers Array of buyer addresses
     * @param sellers Array of seller addresses
     * @param tokens Array of token addresses
     * @param encryptedAmounts Array of encrypted amounts
     * @param cotiTxHashes Array of COTI transaction hashes
     * @param cotiBlockNumber COTI block number containing all trades
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless settlement
     */
    function batchSettlePrivateDEX(
        address[] calldata buyers,
        address[] calldata sellers,
        address[] calldata tokens,
        bytes32[] calldata encryptedAmounts,
        bytes32[] calldata cotiTxHashes,
        uint256 cotiBlockNumber
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) whenNotPaused {
        uint256 count = buyers.length;
        if (
            sellers.length != count ||
            tokens.length != count ||
            encryptedAmounts.length != count ||
            cotiTxHashes.length != count
        ) revert InvalidAmount();

        for (uint256 i = 0; i < count; ++i) {
            if (buyers[i] == address(0) || sellers[i] == address(0)) revert InvalidAddress();
            if (tokens[i] == address(0)) revert InvalidAddress();

            emit PrivateDEXSettlement(
                buyers[i],
                sellers[i],
                tokens[i],
                encryptedAmounts[i],
                cotiTxHashes[i],
                cotiBlockNumber
            );
        }

        bytes32 batchId = keccak256(abi.encodePacked(
            block.number,
            cotiBlockNumber,
            count
        ));

        emit BatchPrivateSettlement(batchId, count, cotiBlockNumber);
    }

    /**
     * @notice Deposit tokens to DEX
     * @dev Simple deposit for trading
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToDEX(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        address caller = _msgSender();
        // M-03: Use balance-before/after pattern to handle
        // fee-on-transfer tokens correctly.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(caller, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;

        dexBalances[caller][token] += received;
    }

    /**
     * @notice Withdraw tokens from DEX
     * @dev Simple withdrawal
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawFromDEX(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        address caller = _msgSender();
        if (dexBalances[caller][token] < amount) revert InvalidAmount();

        dexBalances[caller][token] -= amount;
        IERC20(token).safeTransfer(caller, amount);
    }

    // =============================================================================
    // View Functions
    // =============================================================================

    /**
     * @notice Get service address by name
     * @param name Service identifier
     * @return serviceAddress Address of the service
     */
    function getService(bytes32 name) external view returns (address serviceAddress) {
        return services[name];
    }

    /**
     * @notice Check if an address is an active validator
     * @dev V3: Falls back to Bootstrap.sol if not in the validators mapping.
     *      Checks node types 0 (gateway) and 1 (computation) as both
     *      are valid validators. Existing setValidator() entries still work.
     * @param validator Address to check
     * @return active Whether the address is an active validator
     */
    function isValidator(address validator) external view returns (bool active) {
        if (validators[validator]) return true;

        // V3: Fallback to Bootstrap.sol if configured
        if (bootstrapContract != address(0)) {
            try IBootstrap(bootstrapContract).isNodeActive(validator)
                returns (bool isActive, uint8 nodeType)
            {
                // Gateway (0) and computation (1) nodes are validators
                return isActive && nodeType < 2;
            } catch {
                return false;
            }
        }

        return false;
    }

    /**
     * @notice Get all active validator nodes from Bootstrap.sol
     * @dev V3: Queries Bootstrap for gateway (type 0) and computation (type 1)
     *      nodes, interleaves them for fair representation.
     *      Used by OmniValidatorRewards for epoch reward distribution.
     *      No per-type limit — Bootstrap.MAX_NODES (1000) bounds the total.
     *      Interleaving ensures both node types get equal representation
     *      when OmniValidatorRewards' MAX_VALIDATORS_PER_EPOCH truncates
     *      the list. Reverts with InvalidAddress if Bootstrap is not set.
     * @return nodes Interleaved array of active gateway + computation addresses
     */
    function getActiveNodes() external view returns (address[] memory nodes) {
        if (bootstrapContract == address(0)) revert InvalidAddress();

        IBootstrap bootstrap = IBootstrap(bootstrapContract);

        // Fetch all active gateways (type 0) and computation nodes (type 1).
        // No artificial per-type limit — Bootstrap.MAX_NODES (1000) is
        // the only cap. OmniValidatorRewards applies its own
        // MAX_VALIDATORS_PER_EPOCH cap during epoch processing.
        address[] memory gateways = bootstrap.getActiveNodes(0, 0);
        address[] memory serviceNodes = bootstrap.getActiveNodes(1, 0);

        uint256 gLen = gateways.length;
        uint256 sLen = serviceNodes.length;

        // V2 M-03 fix: Interleave gateways and computation nodes
        // for fair representation when MAX_VALIDATORS_PER_EPOCH
        // truncates the list. Pattern: [g0, s0, g1, s1, ...].
        // If one type has more nodes, its extras appear at the end.
        nodes = new address[](gLen + sLen);
        uint256 idx;
        uint256 maxLen = gLen > sLen ? gLen : sLen;
        for (uint256 i = 0; i < maxLen;) {
            if (i < gLen) {
                nodes[idx] = gateways[i];
                ++idx;
            }
            if (i < sLen) {
                nodes[idx] = serviceNodes[i];
                ++idx;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Get stake information for a user
     * @param user Address of the staker
     * @return Stake information
     */
    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    /**
     * @notice Get staked amount at a specific past block number
     * @dev Used by OmniGovernance for snapshot-based voting power.
     *      Returns the most recent checkpoint at or before the given block.
     * @param user Address of the staker
     * @param blockNumber Block number to query
     * @return Staked amount at the given block (0 if none)
     */
    function getStakedAt(
        address user,
        uint256 blockNumber
    ) external view returns (uint256) {
        return _stakeCheckpoints[user].upperLookup(
            SafeCast.toUint32(blockNumber)
        );
    }

    /**
     * @notice Get DEX balance for a user
     * @param user User address
     * @param token Token address
     * @return balance DEX balance
     */
    function getDEXBalance(address user, address token) external view returns (uint256 balance) {
        return dexBalances[user][token];
    }

    // =============================================================================
    // Legacy Migration Functions (Added 2025-08-06)
    // =============================================================================

    /**
     * @notice Register legacy users and their balances
     * @dev Only callable by admin during initialization
     * @param usernames Array of legacy usernames to reserve
     * @param balances Array of balances in 18 decimal precision
     * @param publicKeys Array of legacy user account public keys
     */
    function registerLegacyUsers(
        string[] calldata usernames,
        uint256[] calldata balances,
        bytes[] calldata publicKeys
    ) external onlyRole(ADMIN_ROLE) {
        if (usernames.length != balances.length || usernames.length != publicKeys.length) {
            revert InvalidAmount();
        }
        if (usernames.length > 100) revert InvalidAmount(); // Gas limit protection

        uint256 totalAmount = 0;

        for (uint256 i = 0; i < usernames.length; ++i) {
            bytes32 usernameHash = keccak256(abi.encodePacked(usernames[i]));

            // Skip if already registered
            if (legacyUsernames[usernameHash]) continue;

            // Reserve username and store balance and public key
            legacyUsernames[usernameHash] = true;
            legacyBalances[usernameHash] = balances[i];
            legacyAccounts[usernameHash] = publicKeys[i];
            totalAmount += balances[i];
        }

        totalLegacySupply += totalAmount;

        emit LegacyUsersRegistered(usernames.length, totalAmount);
    }

    /**
     * @notice Claim legacy balance with M-of-N validator signatures
     * @dev Validators verify legacy credentials off-chain; multiple signatures required
     * @param username Legacy username
     * @param claimAddress Address to receive the tokens
     * @param nonce Unique nonce to prevent replay
     * @param signatures Array of validator signatures authorizing the claim
     */
    function claimLegacyBalance(
        string calldata username,
        address claimAddress,
        bytes32 nonce,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        if (claimAddress == address(0)) revert InvalidAddress();
        if (signatures.length < requiredSignatures) revert InsufficientSignatures();

        // M-01: Track nonce on-chain to prevent signature replay
        if (_usedClaimNonces[nonce]) revert InvalidSignature();
        _usedClaimNonces[nonce] = true;

        bytes32 usernameHash = keccak256(abi.encodePacked(username));

        // Check username is registered and not claimed
        if (!legacyUsernames[usernameHash]) revert InvalidAddress();
        if (legacyClaimed[usernameHash] != address(0)) revert InvalidAmount();

        // Compute and verify validator signatures
        _verifyClaimSignatures(
            username, claimAddress, nonce, signatures
        );

        // Get balance and mark as claimed (L-02: reject zero balances)
        uint256 amount = legacyBalances[usernameHash];
        if (amount == 0) revert InvalidAmount();
        legacyClaimed[usernameHash] = claimAddress;
        totalLegacyClaimed += amount;

        // Transfer tokens (must be pre-minted to this contract)
        OMNI_COIN.safeTransfer(claimAddress, amount);

        emit LegacyBalanceClaimed(
            username,
            claimAddress,
            amount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Check if a legacy username is available
     * @param username Username to check
     * @return available True if not reserved by legacy system
     */
    function isUsernameAvailable(string calldata username) external view returns (bool available) {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        return !legacyUsernames[usernameHash];
    }

    /**
     * @notice Get legacy migration status for a username
     * @param username Legacy username
     * @return reserved Whether username is reserved
     * @return balance Legacy balance to claim
     * @return claimed Whether balance has been claimed
     * @return claimAddress Address that claimed (if any)
     * @return publicKey Legacy account public key
     */
    function getLegacyStatus(string calldata username) external view returns (
        bool reserved,
        uint256 balance,
        bool claimed,
        address claimAddress,
        bytes memory publicKey
    ) {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        reserved = legacyUsernames[usernameHash];
        balance = legacyBalances[usernameHash];
        claimAddress = legacyClaimed[usernameHash];
        claimed = (claimAddress != address(0));
        publicKey = legacyAccounts[usernameHash];
    }

    // =============================================================================
    // Internal Functions
    // =============================================================================

    /**
     * @notice Verify M-of-N validator signatures for a legacy claim
     * @dev Computes the EIP-191 signed message hash and verifies each
     *      signature is from a unique active validator.
     * @param username Legacy username being claimed
     * @param claimAddress Address that will receive the tokens
     * @param nonce Unique nonce to prevent replay
     * @param signatures Array of validator signatures
     */
    function _verifyClaimSignatures(
        string calldata username,
        address claimAddress,
        bytes32 nonce,
        bytes[] calldata signatures
    ) internal view {
        // M-02: Use abi.encode instead of abi.encodePacked to prevent
        // hash collision risk with the dynamic-length username string.
        bytes32 messageHash = keccak256(abi.encode(
            username,
            claimAddress,
            nonce,
            address(this),
            block.chainid
        ));

        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        uint256 sigCount = signatures.length;
        address[] memory signers = new address[](sigCount);

        for (uint256 i = 0; i < sigCount; ++i) {
            address signer = _recoverSigner(
                ethSignedMessageHash, signatures[i]
            );
            if (!validators[signer]) revert InvalidSignature();

            // Check for duplicate signers
            for (uint256 j = 0; j < i; ++j) {
                if (signers[j] == signer) revert DuplicateSigner();
            }
            signers[i] = signer;
        }
    }

    /**
     * @notice Validate that the staking tier matches the amount thresholds
     * @dev Tier minimums per OmniBazaar tokenomics. Tier must be 1-5 and the
     *      staked amount must meet the minimum for that tier.
     * @param amount Amount of tokens being staked (18 decimals)
     * @param tier Staking tier claimed by the user (1-5)
     */
    function _validateStakingTier(
        uint256 amount,
        uint256 tier
    ) internal pure {
        if (tier == 0 || tier > MAX_TIER) revert InvalidStakingTier();

        // Tier minimum thresholds in 18-decimal XOM
        uint256[5] memory tierMinimums = [
            uint256(1 ether),                // Tier 1: >= 1 XOM
            uint256(1_000_000 ether),        // Tier 2: >= 1,000,000 XOM
            uint256(10_000_000 ether),       // Tier 3: >= 10,000,000 XOM
            uint256(100_000_000 ether),      // Tier 4: >= 100,000,000 XOM
            uint256(1_000_000_000 ether)     // Tier 5: >= 1,000,000,000 XOM
        ];

        if (amount < tierMinimums[tier - 1]) revert InvalidStakingTier();
    }

    /**
     * @notice Validate that the lock duration is one of the allowed options
     * @dev Valid durations: 0 (no lock), 30 days, 180 days, 730 days
     * @param duration Lock duration in seconds
     */
    function _validateDuration(uint256 duration) internal pure {
        if (
            duration != 0 &&
            duration != 30 days &&
            duration != 180 days &&
            duration != 730 days
        ) {
            revert InvalidDuration();
        }
    }

    /**
     * @notice Internal function to recover signer from signature
     * @dev Uses OpenZeppelin ECDSA.recover() to prevent signature
     *      malleability attacks (M-01 remediation). ECDSA.recover
     *      enforces that s is in the lower half of the secp256k1
     *      curve order and rejects non-standard v values.
     * @param messageHash Hash of the signed message
     * @param signature Signature bytes (65 bytes: r + s + v)
     * @return signer Recovered signer address
     */
    function _recoverSigner(
        bytes32 messageHash,
        bytes memory signature
    ) internal pure returns (address signer) {
        signer = ECDSA.recover(messageHash, signature);
        if (signer == address(0)) revert InvalidSignature();
    }

    // =============================================================================
    // ERC2771Context Overrides (resolve diamond with AccessControl/Pausable Context)
    // =============================================================================

    /**
     * @notice Resolve _msgSender between ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev Returns the original user address when called through the trusted forwarder.
     *      Used by user-facing functions (stake, unlock, deposit, withdraw) to identify
     *      the actual user. Admin functions still use role-based access control.
     * @return The original transaction signer when relayed, or msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolve _msgData between ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev Strips the appended sender address from calldata when relayed
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev Returns 20 (address length) for ERC2771 context suffix stripping
     * @return The number of bytes appended to calldata by the forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
