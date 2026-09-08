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
import {IStakingRewardPool} from "./interfaces/IStakingRewardPool.sol";

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

    /// @notice Role permitted to slash validator stake (VT-09)
    /// @dev Held by the AttestationFraudHandler (and the deployer during
    ///      Pioneer). Grants the fraud handler a narrow, purpose-built
    ///      authority over `stakes[].amount` — nothing else.
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    /// @notice Role for Avalanche validators
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");

    /// @notice Role for ValidatorProvisioner contract to manage validators
    bytes32 public constant PROVISIONER_ROLE = keccak256("PROVISIONER_ROLE");

    /// @notice Fee percentage for ODDAO (70% = 7000 basis points)
    uint256 public constant ODDAO_FEE_BPS = 7000;

    /// @notice Fee percentage for staking pool (20% = 2000 basis points)
    uint256 public constant STAKING_FEE_BPS = 2000;

    /// @notice Fee percentage for protocol treasury (10% = 1000 basis points)
    uint256 public constant PROTOCOL_FEE_BPS = 1000;

    /// @notice Total basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum number of validator signatures for multi-sig
    uint256 public constant MAX_REQUIRED_SIGNATURES = 5;

    /// @notice Maximum valid staking tier (H-02 remediation)
    uint256 public constant MAX_TIER = 5;

    /// @notice Number of valid lock duration options (0, 30d, 180d, 730d)
    uint256 public constant DURATION_COUNT = 4;

    /// @notice Cooldown between `requestUnlock` and `unlock`.
    /// @dev Closes VP-22 (flash-stake) and partially closes M-Biz-Stake
    ///      (attest-then-unstake race) per internal audit
    ///      follow-up #6. A staker must call `requestUnlock` first; the
    ///      principal can only be withdrawn via `unlock` once
    ///      `block.timestamp >= unstakeRequestedAt[user] + UNSTAKE_COOLDOWN`
    ///      AND the original lock has expired. 48 hours mirrors the
    ///      ADMIN_TRANSFER_DELAY cadence — long enough for protocol
    ///      detection of an in-progress validator exit, short enough not
    ///      to drive honest stakers away on UX grounds.
    ///      OMNICORE-DECENT (2026-05-24): lowered from the original 7-day
    ///      figure to 48h after the design walk-through concluded the
    ///      auto-eligibility + per-epoch reward zeroing in
    ///      `OmniRegistration.recordEquivocation` already absorbs the
    ///      attest-then-exit attack window; preserving 7 days only added
    ///      UX friction with no marginal security benefit.
    uint256 public constant UNSTAKE_COOLDOWN = 48 hours;

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

    /// @notice Protocol treasury address for receiving 10% of DEX fees
    /// @dev V4: Replaces the per-call validator parameter in distributeDEXFees().
    ///      The 10% fee share goes to the protocol treasury, not individual validators.
    address public protocolTreasuryAddress;

    /// @notice Whether legacy DEX settlement functions are permanently disabled
    /// @dev M-01 audit: One-way flag set by disableDEXSettlement(). Once true,
    ///      depositToDEX, withdrawFromDEX, and all deprecated settlement
    ///      functions revert with DEXSettlementDisabled(). Cannot be unset.
    bool public dexSettlementDisabled;

    /// @notice Per-staker timestamp of the most recent `requestUnlock` call.
    /// @dev Zero = no pending request. Reset to zero when the staker
    ///      successfully calls `unlock` or after the stake slot is
    ///      cleared by any future migration. Together with the
    ///      `UNSTAKE_COOLDOWN` constant this implements the
    ///      VP-22 + M-Biz-Stake remediation: principal withdrawal
    ///      requires a two-step ceremony separated by the cooldown so
    ///      same-block flash-stake and attest-then-unstake races are
    ///      impossible at the contract layer.
    ///
    ///      Slot added 2026-05-23; corresponding `__gap` reduced from
    ///      50 to 49 below to keep total reserved layout space stable.
    mapping(address => uint256) public unstakeRequestedAt;

    /// @notice Tracks all ADMIN_ROLE holders for clean revocation
    ///         during admin transfer. Maintained by overridden
    ///         _grantRole / _revokeRole.
    address[] private _adminRoleHolders;

    /// @notice Storage gap for future upgrades
    /// @dev Pre-mainnet: started at 50. `unstakeRequestedAt` (Phase 3
    ///      VP-22 / M-Biz-Stake remediation) consumed one slot.
    ///      `_adminRoleHolders` consumed one slot.
    ///      Reduce gap by N when adding N new state variables.
    uint256[48] private __gap;

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

    /// @notice Emitted when a validator's stake is slashed (VT-09).
    /// @param validator Validator whose stake was reduced.
    /// @param amount Amount slashed (transferred to the slasher).
    /// @param remaining Stake remaining after the slash.
    event TokensSlashed(
        address indexed validator,
        uint256 indexed amount,
        uint256 remaining
    );

    /// @notice Emitted when a staker schedules a future unlock.
    /// @param user Address that called `requestUnlock`.
    /// @param availableAt Earliest block timestamp at which `unlock`
    ///        will succeed (still subject to the original lock expiry).
    event UnlockRequested(
        address indexed user,
        uint256 indexed availableAt
    );

    /// @notice Emitted when a staker cancels a pending unlock request.
    /// @dev OMNICORE-DECENT ergonomics: lets a staker abort an in-flight
    ///      `requestUnlock` (e.g., changed their mind) without waiting for
    ///      the cooldown to expire. A fresh `requestUnlock` starts the
    ///      48h clock again.
    /// @param user Address that called `cancelUnstakeRequest`.
    event UnlockRequestCancelled(address indexed user);

    /// @notice Emitted when `unlock` swallowed a `snapshotRewards` revert.
    /// @dev OMNICORE-DECENT post-audit remediation (audit finding F-7 /
    ///      M-4 — silent reward loss when the staking-pool reverts during
    ///      unstake). The principal still ships; this event is the
    ///      off-chain reward distributor's signal to investigate / re-run
    ///      the snapshot via a direct pool call before crediting the
    ///      staker.
    /// @param user Staker whose snapshot failed.
    /// @param pool Pool address the snapshot was attempted against.
    event RewardSnapshotFailed(address indexed user, address indexed pool);

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

    /// @notice Emitted when the protocol treasury fee recipient address is updated
    /// @param oldAddress Previous protocol treasury address
    /// @param newAddress New protocol treasury address
    event ProtocolTreasuryAddressUpdated(
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

    /// @notice Emitted when DEX settlement functions are permanently disabled
    /// @dev M-01 audit: Once emitted, depositToDEX, withdrawFromDEX, and all
    ///      deprecated settlement functions are permanently non-callable.
    event DEXSettlementPermanentlyDisabled();

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
    /// @notice Thrown when a deprecated function is called (M-01 remediation)
    error DeprecatedFunction();
    /// @notice Thrown when DEX settlement is permanently disabled (M-01 audit)
    error DEXSettlementDisabled();
    /// @notice Thrown when `unlock` is called before `requestUnlock`
    /// @dev VP-22 / M-Biz-Stake: stakers must schedule their exit via
    ///      `requestUnlock` and wait `UNSTAKE_COOLDOWN`.
    error UnstakeNotRequested();
    /// @notice Thrown when `unlock` is called before the cooldown elapses
    error UnstakeCooldownActive();
    /// @notice Thrown when `requestUnlock` is called with an existing request pending
    /// @dev Re-requesting is blocked so a staker cannot accidentally
    ///      reset their own cooldown timer and pay it again.
    error UnstakeAlreadyRequested();

    /// @notice Thrown when one of the fee-recipient setters is handed an EOA.
    /// @dev GOV-XSYS-15 (OMNICORE-DECENT): the ODDAO, staking-pool, and
    ///      protocol-treasury addresses receive on-chain protocol payouts
    ///      and are expected to be governance- or DAO-controlled contracts.
    ///      An EOA in any of those three slots can sweep funds in one
    ///      transaction without a timelock or multisig review, which
    ///      removes the entire trustless-payout guarantee. Sanity check
    ///      requires `addr.code.length > 0` at setter time.
    error RecipientMustBeContract();

    /**
     * @notice Constructor that disables initializers for the implementation contract
     * @dev Prevents the implementation contract from being initialized.
     *      Sets the trusted forwarder address as an immutable (stored in bytecode,
     *      not proxy storage). Pass address(0) to disable meta-transaction support.
     * @param trustedForwarder_ Address of the OmniForwarder contract for gasless relay
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
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
     * @param _protocolTreasuryAddress Protocol treasury fee recipient
     *        (10% of fees)
     */
    function initialize(
        address admin,
        address _omniCoin,
        address _oddaoAddress,
        address _stakingPoolAddress,
        address _protocolTreasuryAddress
    ) public initializer {
        if (admin == address(0) || _omniCoin == address(0) ||
            _oddaoAddress == address(0) || _stakingPoolAddress == address(0) ||
            _protocolTreasuryAddress == address(0)) {
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
        protocolTreasuryAddress = _protocolTreasuryAddress;
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
     * @notice V4 initializer — repoints Bootstrap.sol to the current registry
     * @dev Called once via upgradeToAndCall() to update the bootstrap contract
     *      address after the Bootstrap.sol registry was redeployed. Mirrors
     *      reinitializeV3 (zero-check + write) so the storage layout and prior
     *      upgrade history stay consistent. reinitializer(4) ensures it runs
     *      exactly once and cannot re-run initialize/initializeV2/reinitializeV3.
     * @param _bootstrap Address of the current Bootstrap.sol contract on L1
     */
    function reinitializeV4(
        address _bootstrap
    ) external onlyRole(ADMIN_ROLE) reinitializer(4) {
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
    //
    // OMNICORE-DECENT (2026-05-24): the original V3 design encoded a 48-hour
    // hardcoded delay between `proposeAdminTransfer` and `acceptAdminTransfer`
    // (constant `ADMIN_TRANSFER_DELAY`). Per the project's "no built-in
    // contract time-locks" rule (`feedback_no_builtin_timelocks.md`), that
    // delay is admin-side friction the rule explicitly bans — friction
    // belongs in the EXTERNAL `OmniTimelockController` that the admin role
    // can be assigned to, never inside this functional contract.
    //
    // The two-step structure (propose → accept) is RETAINED — it's
    // typo protection (the new admin must actively claim the role), not a
    // time-lock. The DELAY component is removed: `acceptAdminTransfer` can
    // now be called in the same block as `proposeAdminTransfer`. The
    // `adminTransferEta` storage slot is preserved for UUPS storage-layout
    // safety and is now set to `block.timestamp` (always-met sentinel) so
    // legacy off-chain consumers reading `adminTransferEta` don't break.

    /// @notice Deprecated. Retained only as a UUPS storage placeholder.
    /// @dev OMNICORE-DECENT: was `48 hours`; the timelock-in-functional-
    ///      contract anti-pattern was removed. Value is now zero so any
    ///      remaining off-chain consumer can read `ADMIN_TRANSFER_DELAY` as
    ///      "no delay" rather than crashing on a missing symbol.
    uint256 public constant ADMIN_TRANSFER_DELAY = 0;

    /**
     * @notice Propose transfer of ADMIN_ROLE to a new address.
     * @dev OMNICORE-DECENT: no enforced delay — `acceptAdminTransfer` can be
     *      called immediately. The two-step propose/accept structure is
     *      kept purely as typo protection (the new admin must explicitly
     *      claim the role; sending it to a wrong address by accident
     *      doesn't take effect unless the wrong address actively accepts).
     *      M-03 unchanged: `msg.sender` explicitly so this cannot be
     *      relayed through the trusted forwarder.
     * @param newAdmin Address to receive admin role
     */
    function proposeAdminTransfer(
        address newAdmin
    ) external onlyRole(ADMIN_ROLE) {
        if (newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = newAdmin;
        // `adminTransferEta` retained for storage-layout stability. Value
        // is set to the current block timestamp so `block.timestamp >= eta`
        // is trivially satisfied in `acceptAdminTransfer`.
        // solhint-disable-next-line not-rely-on-time
        adminTransferEta = block.timestamp;
        // M-03: Use msg.sender explicitly -- admin operations must not be relayed
        adminTransferProposer = msg.sender;
        // solhint-disable-next-line not-rely-on-time
        emit AdminTransferProposed(msg.sender, newAdmin, block.timestamp);
    }

    /**
     * @notice Accept pending admin role transfer.
     * @dev OMNICORE-DECENT: no enforced delay. Can be called immediately
     *      after `proposeAdminTransfer`. Grants both DEFAULT_ADMIN_ROLE
     *      and ADMIN_ROLE to the new admin (caller), then revokes both
     *      roles from the previous admin (H-01 fix). M-03 unchanged:
     *      `msg.sender` explicitly so this cannot be relayed.
     */
    function acceptAdminTransfer() external {
        // M-03: Use msg.sender explicitly -- admin operations must not be relayed
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        // OMNICORE-DECENT: legacy 48h-delay gate REMOVED. Two-step structure
        // retained as typo protection only (the new admin must actively
        // claim; the role doesn't move on `proposeAdminTransfer` alone).
        // {AdminTransferNotReady} error is retained as a declared error so
        // the ABI surface is stable for off-chain consumers; it is no
        // longer thrown by any path.

        address oldAdmin = adminTransferProposer;
        pendingAdmin = address(0);
        adminTransferEta = 0;
        adminTransferProposer = address(0);

        // Revoke ADMIN_ROLE from ALL current holders to prevent
        // stale privileges from persisting after transfer
        address[] memory currentAdmins = _adminRoleHolders;
        uint256 len = currentAdmins.length;
        for (uint256 i = 0; i < len; ++i) {
            _revokeRole(ADMIN_ROLE, currentAdmins[i]);
        }
        _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

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
     * @notice Provision a new validator (used by ValidatorProvisioner)
     * @dev Only PROVISIONER_ROLE can call. Performs the same logic as
     *      setValidator(addr, true) — sets the validators mapping and
     *      grants AVALANCHE_VALIDATOR_ROLE. This function exists because
     *      setValidator() requires ADMIN_ROLE, which should not be given
     *      to the ValidatorProvisioner contract.
     * @param validator Address of the validator to provision
     */
    function provisionValidator(
        address validator
    ) external onlyRole(PROVISIONER_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        validators[validator] = true;
        _grantRole(AVALANCHE_VALIDATOR_ROLE, validator);
        emit ValidatorUpdated(validator, true, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Deprovision a validator (used by ValidatorProvisioner)
     * @dev Only PROVISIONER_ROLE can call. Performs the same logic as
     *      setValidator(addr, false) — clears the validators mapping
     *      and revokes AVALANCHE_VALIDATOR_ROLE.
     * @param validator Address of the validator to deprovision
     */
    function deprovisionValidator(
        address validator
    ) external onlyRole(PROVISIONER_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        validators[validator] = false;
        _revokeRole(AVALANCHE_VALIDATOR_ROLE, validator);
        emit ValidatorUpdated(validator, false, block.timestamp); // solhint-disable-line not-rely-on-time
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
        // GOV-XSYS-15: the ODDAO recipient must be a contract (governance /
        // multisig / timelocked treasury), never an EOA. See
        // {RecipientMustBeContract} for rationale.
        if (newOddaoAddress.code.length == 0) revert RecipientMustBeContract();
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
        // GOV-XSYS-15: staking-pool recipient must be a contract; see
        // {RecipientMustBeContract}.
        if (newStakingPoolAddress.code.length == 0) revert RecipientMustBeContract();
        address oldAddress = stakingPoolAddress;
        stakingPoolAddress = newStakingPoolAddress;
        emit StakingPoolAddressUpdated(oldAddress, newStakingPoolAddress);
    }

    /**
     * @notice Update the protocol treasury fee recipient address
     * @dev Only admin can change. The protocol treasury receives
     *      10% of DEX fees.
     * @param newProtocolTreasuryAddress New protocol treasury address
     *        (must be non-zero)
     */
    function setProtocolTreasuryAddress(
        address newProtocolTreasuryAddress
    ) external onlyRole(ADMIN_ROLE) {
        if (newProtocolTreasuryAddress == address(0)) {
            revert InvalidAddress();
        }
        // GOV-XSYS-15: protocol-treasury recipient must be a contract;
        // see {RecipientMustBeContract}.
        if (newProtocolTreasuryAddress.code.length == 0) {
            revert RecipientMustBeContract();
        }
        address oldAddress = protocolTreasuryAddress;
        protocolTreasuryAddress = newProtocolTreasuryAddress;
        emit ProtocolTreasuryAddressUpdated(
            oldAddress, newProtocolTreasuryAddress
        );
    }

    /**
     * @notice Permanently disable all DEX settlement functions (one-way)
     * @dev M-01 audit remediation: Once called, depositToDEX, withdrawFromDEX,
     *      and all deprecated settlement functions (settleDEXTrade, batchSettleDEX,
     *      distributeDEXFees, settlePrivateDEXTrade, batchSettlePrivateDEX) will
     *      revert with DEXSettlementDisabled(). This is irreversible. Users must
     *      withdraw remaining dexBalances before this is called, or an admin-assisted
     *      migration must be arranged. Only callable by ADMIN_ROLE (timelock).
     */
    function disableDEXSettlement() external onlyRole(ADMIN_ROLE) {
        dexSettlementDisabled = true;
        emit DEXSettlementPermanentlyDisabled();
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
     * @notice Schedule a future `unlock` by starting the cooldown timer.
     * @dev VP-22 + M-Biz-Stake remediation. Callable any time the stake
     *      is active; sets `unstakeRequestedAt[caller] = block.timestamp`.
     *      A second `requestUnlock` while one is already pending reverts
     *      with `UnstakeAlreadyRequested` so an accidental call cannot
     *      reset the staker's own cooldown clock.
     *
     *      The request does NOT disable the stake — rewards continue to
     *      accrue in `StakingRewardPool` and validator duties are still
     *      expected throughout the cooldown window. Withdrawal only
     *      becomes possible at `unstakeRequestedAt + UNSTAKE_COOLDOWN`,
     *      gated also by the original lock-period expiry inside `unlock`.
     */
    function requestUnlock() external whenNotPaused {
        address caller = _msgSender();
        Stake storage userStake = stakes[caller];

        if (!userStake.active) revert StakeNotFound();
        if (unstakeRequestedAt[caller] != 0) revert UnstakeAlreadyRequested();

        // solhint-disable-next-line not-rely-on-time
        unstakeRequestedAt[caller] = block.timestamp;
        emit UnlockRequested(
            caller,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + UNSTAKE_COOLDOWN
        );
    }

    /**
     * @notice Unlock staked tokens after lock period AND the
     *         `UNSTAKE_COOLDOWN` from `requestUnlock`.
     * @dev Returns principal only. Rewards handled by StakingRewardPool contract.
     *      Call StakingRewardPool.snapshotRewards() BEFORE this to preserve rewards.
     *      VP-22 + M-Biz-Stake remediation: `requestUnlock` must have
     *      been called at least `UNSTAKE_COOLDOWN` ago. The original
     *      lock-period expiry remains enforced as before.
     */
    function unlock() external nonReentrant whenNotPaused {
        address caller = _msgSender();
        Stake storage userStake = stakes[caller];

        if (!userStake.active) revert StakeNotFound();
        if (block.timestamp < userStake.lockTime) revert StakeLocked(); // solhint-disable-line not-rely-on-time

        uint256 requestedAt = unstakeRequestedAt[caller];
        if (requestedAt == 0) revert UnstakeNotRequested();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < requestedAt + UNSTAKE_COOLDOWN) {
            revert UnstakeCooldownActive();
        }

        // H-02 (OMNICORE-DECENT): snapshot accrued rewards on the off-chain
        // pool BEFORE clearing the on-chain stake slot, so the unstake +
        // reward-payout flows stay accounting-consistent. The call is
        // wrapped in try/catch — a reverting reward pool MUST NOT block a
        // staker's principal withdrawal (auditor's explicit concern;
        // griefing the snapshot would otherwise lock the principal forever).
        // The `code.length > 0` pre-check skips the call entirely when the
        // recipient is an EOA (a state reachable for legacy proxies where
        // stakingPoolAddress was set before the {GOV-XSYS-15} setter check
        // was added). Without this pre-check Solidity's high-level EXTCODESIZE
        // guard reverts BEFORE the try-block scope, which try/catch does
        // not catch — bricking the principal withdrawal we're trying to
        // protect.
        address pool = stakingPoolAddress;
        if (pool != address(0) && pool.code.length > 0) {
            try IStakingRewardPool(pool).snapshotRewards(caller) {
                // snapshot succeeded; off-chain distributor proceeds normally.
            } catch {
                // Audit remediation F-7 / M-4: emit a signal so the
                // off-chain distributor knows it needs to investigate /
                // re-run the snapshot via direct pool call before
                // crediting `caller`. Principal still ships either way.
                emit RewardSnapshotFailed(caller, pool);
            }
        }

        uint256 amount = userStake.amount;

        // Clear stake fully (L-05: clear all fields for storage hygiene)
        userStake.active = false;
        userStake.amount = 0;
        userStake.tier = 0;
        userStake.duration = 0;
        userStake.lockTime = 0;
        unstakeRequestedAt[caller] = 0;
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

    /**
     * @notice Cancel a pending `requestUnlock` without unstaking.
     * @dev OMNICORE-DECENT ergonomics. Clears `unstakeRequestedAt[caller]`
     *      so the staker stays staked and can decide to keep earning
     *      rewards. A subsequent `requestUnlock` will restart the full
     *      `UNSTAKE_COOLDOWN` window from scratch — there is no partial
     *      credit for time already served on the cancelled request.
     */
    function cancelUnstakeRequest() external whenNotPaused {
        address caller = _msgSender();
        if (unstakeRequestedAt[caller] == 0) revert UnstakeNotRequested();
        unstakeRequestedAt[caller] = 0;
        emit UnlockRequestCancelled(caller);
    }

    /**
     * @notice Slash a validator's application-layer stake (VT-09).
     * @dev Only SLASHER_ROLE (the AttestationFraudHandler during Pioneer).
     *      Reduces `stakes[validator].amount` and `totalStaked` WITHOUT the
     *      48h `UNSTAKE_COOLDOWN` / `lockTime` cycle (slashing is a penalty,
     *      not a voluntary exit), keeps `active` true (the all-or-nothing
     *      deprovision cascade — ValidatorProvisioner / RandomCommitteeVerifier
     *      / OmniValidatorRewards minStake gates — runs when the remaining
     *      amount drops below 1M XOM, not here), and writes a governance
     *      checkpoint so `getStakedAt()` cannot overstate voting power.
     *
     *      The slashed amount is transferred to `msg.sender` (the fraud
     *      handler), which pays the reporter bounty and escrows the remainder
     *      under a post-slash lock before burning — the destination logic is
     *      the handler's, keeping OmniCore free of bounty/escrow policy.
     *
     *      NOT gated by `whenNotPaused`: fraud recovery must remain reachable
     *      even if the protocol is emergency-paused.
     * @param validator Validator whose stake to slash.
     * @param amount Amount of XOM to slash (≤ staked amount, > 0).
     */
    function slash(
        address validator,
        uint256 amount
    ) external nonReentrant onlyRole(SLASHER_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        Stake storage s = stakes[validator];
        if (!s.active) revert StakeNotFound();
        if (amount == 0 || amount > s.amount) revert InvalidAmount();

        s.amount -= amount;
        totalStaked -= amount;

        // Governance checkpoint so snapshot voting power reflects the slash.
        _stakeCheckpoints[validator].push(
            SafeCast.toUint32(block.number),
            SafeCast.toUint224(s.amount)
        );

        // Transfer the slashed stake to the slasher (fraud handler).
        OMNI_COIN.safeTransfer(msg.sender, amount);

        emit TokensSlashed(validator, amount, s.amount);
    }

    /**
     * @notice Earliest timestamp at which `unlock` can succeed for `user`.
     * @dev OMNICORE-DECENT ergonomics. Returns 0 if no `requestUnlock` is
     *      pending. The returned value does NOT account for the underlying
     *      stake's `lockTime`; callers that need a true "available to
     *      withdraw" timestamp should take `max(getUnstakeAvailableAt(user),
     *      stakes[user].lockTime)`.
     * @param user Staker to inspect.
     * @return availableAt Cooldown-only earliest-unlock timestamp; 0 when
     *         no unstake is pending.
     */
    function getUnstakeAvailableAt(address user) external view returns (uint256 availableAt) {
        uint256 requestedAt = unstakeRequestedAt[user];
        if (requestedAt == 0) return 0;
        availableAt = requestedAt + UNSTAKE_COOLDOWN;
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
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
        // M-01: Function deprecated in favour of DEXSettlement.sol
        revert DeprecatedFunction();
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
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
        // M-01: Function deprecated in favour of DEXSettlement.sol
        revert DeprecatedFunction();
    }

    /**
     * @notice Distribute DEX fees
     * @dev Called by validators to distribute fees according to tokenomics.
     *      70% ODDAO, 20% Staking Pool, 10% Protocol Treasury.
     * @param token Fee token
     * @param totalFee Total fee amount
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless fee distribution
     */
    function distributeDEXFees(
        address token,
        uint256 totalFee
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) whenNotPaused {
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
        // M-01: Function deprecated in favour of DEXSettlement.sol
        revert DeprecatedFunction();
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
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
        // M-01: Function deprecated in favour of DEXSettlement.sol
        revert DeprecatedFunction();
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
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
        // M-01: Function deprecated in favour of DEXSettlement.sol
        revert DeprecatedFunction();
    }

    /**
     * @notice Deposit tokens to DEX
     * @dev Simple deposit for trading
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToDEX(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
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
        if (dexSettlementDisabled) revert DEXSettlementDisabled();
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

        bytes32 usernameHash = keccak256(abi.encodePacked(username));

        // Check username is registered and not claimed
        if (!legacyUsernames[usernameHash]) revert InvalidAddress();
        if (legacyClaimed[usernameHash] != address(0)) revert InvalidAmount();

        // Compute and verify validator signatures BEFORE consuming nonce
        // (prevents griefing: nonce is only burned after a valid signature)
        _verifyClaimSignatures(
            username, claimAddress, nonce, signatures
        );

        // M-01: Track nonce on-chain to prevent signature replay
        if (_usedClaimNonces[nonce]) revert InvalidSignature();
        _usedClaimNonces[nonce] = true;

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
     * @dev Valid durations: 0 (legacy "no lock", retained for back-compat
     *      with positions created before the 1-day minimum), 1 day, 30 days,
     *      180 days, 730 days. The 1-day bucket is the new minimum offered
     *      by the WebApp/wallet UI; the 24 h MIN_STAKE_AGE in
     *      `StakingRewardPool` provides flash-stake protection so a 1-day
     *      commitment is meaningful and earns the base APR for the tier.
     * @param duration Lock duration in seconds
     */
    function _validateDuration(uint256 duration) internal pure {
        if (
            duration != 0 &&
            duration != 1 days &&
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
    // AccessControl Overrides — ADMIN_ROLE holder tracking
    // =============================================================================

    /**
     * @notice Override _grantRole to track ADMIN_ROLE holders
     * @dev Maintains _adminRoleHolders array for clean revocation
     *      during admin transfer.
     */
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        bool ret = super._grantRole(role, account);
        if (role == ADMIN_ROLE) {
            _adminRoleHolders.push(account);
        }
        return ret;
    }

    /**
     * @notice Override _revokeRole to untrack ADMIN_ROLE holders
     * @dev Removes account from _adminRoleHolders via swap-and-pop.
     */
    function _revokeRole(bytes32 role, address account) internal override returns (bool) {
        bool ret = super._revokeRole(role, account);
        if (role == ADMIN_ROLE) {
            uint256 len = _adminRoleHolders.length;
            for (uint256 i = 0; i < len; ++i) {
                if (_adminRoleHolders[i] == account) {
                    _adminRoleHolders[i] = _adminRoleHolders[len - 1];
                    _adminRoleHolders.pop();
                    break;
                }
            }
        }
        return ret;
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
