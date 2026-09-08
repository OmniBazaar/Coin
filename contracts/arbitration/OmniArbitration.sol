// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ══════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title IArbitrationParticipation
 * @author OmniBazaar Team
 * @notice Interface for checking arbitrator qualification
 */
interface IArbitrationParticipation {
    /// @notice Check if user can be a validator (score >= 50, KYC 4)
    /// @param user Address to check
    /// @return True if qualified as arbitrator
    function canBeValidator(address user) external view returns (bool);

    /// @notice Get total participation score
    /// @param user Address to check
    /// @return Total score (0-100)
    function getTotalScore(
        address user
    ) external view returns (uint256);
}

/**
 * @title IArbitrationEscrow
 * @author OmniBazaar Team
 * @notice Interface for escrow contract interaction
 */
interface IArbitrationEscrow {
    /// @notice Get escrow buyer address
    /// @param escrowId Escrow ID
    /// @return Buyer address
    function getBuyer(
        uint256 escrowId
    ) external view returns (address);

    /// @notice Get escrow seller address
    /// @param escrowId Escrow ID
    /// @return Seller address
    function getSeller(
        uint256 escrowId
    ) external view returns (address);

    /// @notice Get escrow amount
    /// @param escrowId Escrow ID
    /// @return Amount in XOM
    function getAmount(
        uint256 escrowId
    ) external view returns (uint256);

    /// @notice Resolve a dispute by releasing or refunding escrow funds
    /// @dev Called by OmniArbitration when a dispute reaches resolution
    /// @param escrowId Escrow ID to resolve
    /// @param releaseFunds True to release to seller, false to refund buyer
    function resolveDispute(
        uint256 escrowId,
        bool releaseFunds
    ) external;

    /// @notice Mark an escrow disputed so party-unilateral exits (buyer
    ///         refund, atomic release) are blocked while the panel deliberates
    /// @dev Called by {createDispute} when a panel dispute is opened. Closes
    ///      the refund race where a buyer could self-refund an expired escrow
    ///      mid-deliberation, stranding a winning seller. Reverts if the escrow
    ///      is already resolved or does not exist, which correctly rejects
    ///      disputing a settled escrow.
    /// @param escrowId Escrow ID to mark disputed
    function markDisputed(uint256 escrowId) external;
}

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Caller is not qualified as arbitrator
error NotQualifiedArbitrator();

/// @notice Dispute does not exist
error DisputeNotFound(uint256 disputeId);

/// @notice Dispute already resolved
error DisputeAlreadyResolved(uint256 disputeId);

/// @notice Caller is not assigned arbitrator for this dispute
error NotAssignedArbitrator();

/// @notice Arbitrator already voted on this dispute
error AlreadyVoted();

/// @notice Cannot dispute own escrow
error CannotDisputeOwnEscrow();

/// @notice Caller is not buyer or seller of this escrow
error NotEscrowParty();

/// @notice Insufficient stake for arbitration
error InsufficientArbitratorStake(
    uint256 provided,
    uint256 required
);

/// @notice Dispute deadline has passed
error DeadlineExpired();

/// @notice Dispute deadline has not yet passed (for default resolution)
error DeadlineNotReached(uint256 deadline);

/// @notice Evidence submission period closed
error EvidencePeriodClosed();

/// @notice Insufficient qualified arbitrators available
error NotEnoughArbitrators();

/// @notice Vote type invalid
error InvalidVoteType();

/// @notice An escrow already has an active dispute
/// @param escrowId The escrow ID that is already disputed
error EscrowAlreadyDisputed(uint256 escrowId);

/// @notice Arbitrator has active dispute assignments and cannot withdraw
error ArbitratorBusyInDispute();

/// @notice A zero address was provided where one is not allowed
error ZeroAddress();

/// @notice Address does not contain contract code
/// @param addr The address that has no code
error NotAContract(address addr);

/// @notice Minimum stake is outside allowed bounds
/// @param provided The value provided
/// @param minBound Lower bound
/// @param maxBound Upper bound
error StakeOutOfBounds(
    uint256 provided,
    uint256 minBound,
    uint256 maxBound
);

/// @notice Disputed amount too small to produce a meaningful fee
error DisputedAmountTooSmall();

/// @notice Arbitrator selection not yet finalized for this dispute
error SelectionNotFinalized(uint256 disputeId);

/// @notice Must wait at least 2 blocks after dispute creation
/// @param currentBlock Current block number
/// @param requiredBlock Earliest allowed block
error SelectionTooEarly(
    uint256 currentBlock,
    uint256 requiredBlock
);

/// @notice Arbitrator selection already finalized
error SelectionAlreadyFinalized(uint256 disputeId);

/// @notice Dispute status is invalid for the requested operation
error InvalidDisputeStatus();

/// @notice No fee vault change is currently pending
error NoFeeVaultChangePending();

/// @notice Fee vault timelock delay has not yet elapsed
/// @param availableAt Timestamp when the change becomes available
error FeeVaultTimelockActive(uint256 availableAt);

/// @notice The selection block's hash has expired (older than 256
///         blocks), so arbitrator selection would use a zero seed
error SelectionBlockhashExpired();

/**
 * @title OmniArbitration
 * @author OmniBazaar Team
 * @notice Trustless arbitration system for OmniBazaar marketplace
 *         disputes
 *
 * @dev Provides two-phase arbitrator selection, 3-arbitrator panels,
 *      evidence registration via IPFS CIDs, fee collection and
 *      distribution, escrow fund movement, and timeout protection
 *      with default resolution.
 *
 * Architecture:
 * - Arbitrators qualify via OmniParticipation (score >= 50, KYC 4)
 * - Two-phase commit: createDispute stores selectionBlock, then
 *   finalizeArbitratorSelection uses blockhash(selectionBlock) 2+
 *   blocks later to prevent the creator from predicting the panel
 * - 3-arbitrator panel with 2-of-3 majority
 * - Evidence CIDs recorded on-chain (immutable once submitted)
 * - 7-day deadline; default refund to buyer on timeout
 * - Fee: 5% of disputed amount collected at dispute creation
 *   (30% to each arbitrator, 10% to UnifiedFeeVault)
 * - UUPS upgrades authorized directly by the admin (deployer)
 *
 * Security:
 * - UUPS upgradeable (deployer-direct), Pausable, ReentrancyGuard
 * - Two-phase selection prevents creator from knowing the panel
 * - One dispute per escrow prevents panel shopping
 * - Active-dispute guard prevents arbitrator stake withdrawal
 * - Only qualified participants can serve as arbitrators
 *
 * @custom:security-note For production mainnet, consider upgrading
 *   the two-phase selection to Chainlink VRF for cryptographic
 *   randomness guarantees. The current two-phase blockhash approach
 *   is safe against user manipulation but a colluding block
 *   proposer could theoretically influence selection by withholding
 *   blocks.
 */
contract OmniArbitration is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                        TYPE DECLARATIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Vote type for dispute resolution
    enum VoteType {
        None,
        Release,
        Refund
    }

    /// @notice Dispute status
    /// @dev Appealed and AppealPendingSelection are retained for ABI/storage
    ///      compatibility with off-chain indexers, but are never set — the
    ///      appeal tier was removed.
    enum DisputeStatus {
        Active,
        Resolved,
        // solhint-disable-next-line unused-state-variable
        Appealed, // @dev deprecated — appeal tier removed, never set
        DefaultResolved,
        PendingSelection,
        // solhint-disable-next-line unused-state-variable
        AppealPendingSelection // @dev deprecated — appeal tier removed, never set
    }

    /// @notice Dispute record
    struct Dispute {
        uint256 escrowId;
        address buyer;
        address seller;
        address[3] arbitrators;
        uint8 releaseVotes;
        uint8 refundVotes;
        uint256 createdAt;
        uint256 deadline;
        uint256 disputedAmount;
        DisputeStatus status;
        /// @dev Deprecated — appeal tier removed; never set.
        bool appealed;
        bytes32[] evidenceCIDs;
        uint256 disputeFee;
        uint256 selectionBlock;
        /// @dev Deprecated — appeal tier removed. Retained for storage layout
        ///      compatibility; never set.
        uint48 appealDeadline;
        /// @dev Deprecated — appeal tier removed; never set.
        bool resolutionDirection;
        /// @dev Deprecated — appeal tier removed; never set.
        bool escrowFinalized;
    }

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Role for dispute management
    bytes32 public constant DISPUTE_ADMIN_ROLE =
        keccak256("DISPUTE_ADMIN_ROLE");

    /// @notice Default dispute deadline (7 days)
    uint256 public constant DEFAULT_DEADLINE = 7 days;

    /// @notice Arbitration fee in basis points (500 = 5%)
    uint256 public constant ARBITRATION_FEE_BPS = 500;

    /// @notice Fee split: share paid to EACH of the three arbitrators
    ///         (3000 = 30% of the total fee). The 3-member panel receives
    ///         90% in total.
    uint256 public constant PER_ARBITRATOR_FEE_SHARE = 3000;

    /// @notice Fee split: UnifiedFeeVault target share (1000 = 10%)
    /// @dev The vault receives the fee remainder (fee minus the arbitrators'
    ///      90%) so rounding dust lands there too — the effective vault share
    ///      is ≥10%. Vault handles internal 70/20/10 distribution.
    uint256 public constant VAULT_SHARE = 1000;

    /// @notice Basis points denominator
    uint256 private constant BPS = 10_000;

    /// @notice Maximum evidence items per dispute
    uint256 public constant MAX_EVIDENCE = 50;

    /// @notice Maximum registered arbitrators to iterate
    uint256 private constant MAX_ARBITRATOR_SEARCH = 200;

    /// @notice Minimum allowed arbitrator stake (100 XOM)
    uint256 public constant MIN_STAKE_LOWER_BOUND = 100 ether;

    /// @notice Maximum allowed arbitrator stake (10,000,000 XOM)
    uint256 public constant MIN_STAKE_UPPER_BOUND =
        10_000_000 ether;

    /// @notice Timelock delay for fee vault address changes (48 hours)
    /// @dev FE-H-01 remediation: prevents instant fee redirection
    ///      by a compromised admin key
    uint256 public constant FEE_VAULT_DELAY = 48 hours;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice OmniParticipation contract
    IArbitrationParticipation public participation;

    /// @notice Escrow contract
    IArbitrationEscrow public escrow;

    /// @notice XOM token for fees and stakes
    IERC20 public xomToken;

    /// @dev Removed: formerly oddaoTreasury (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    uint256 private __removedOddaoTreasury;

    /// @dev Removed: formerly protocolTreasury (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    uint256 private __removedProtocolTreasury;

    /// @notice Dispute counter
    uint256 public nextDisputeId;

    /// @notice All disputes
    mapping(uint256 => Dispute) public disputes;

    /// @dev Removed: formerly appeals (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    mapping(uint256 => uint256) private __removedAppeals;

    /// @notice Vote record per dispute per arbitrator
    mapping(uint256 => mapping(address => VoteType)) public votes;

    /// @dev Removed: formerly appealVotes (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    mapping(uint256 => mapping(address => uint256))
        private __removedAppealVotes;

    /// @notice Arbitrator stake balances
    mapping(address => uint256) public arbitratorStakes;

    /// @notice Minimum arbitrator stake (10,000 XOM)
    uint256 public minArbitratorStake;

    /// @dev Removed: formerly appealStakeMultiplier (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    uint256 private __removedAppealStakeMultiplier;

    /// @notice Registered arbitrator addresses (for selection pool)
    address[] public arbitratorPool;

    /// @notice Whether address is in the arbitrator pool
    mapping(address => bool) public isInArbitratorPool;

    /// @notice Evidence submitter tracking
    mapping(uint256 => mapping(bytes32 => address))
        public evidenceSubmitters;

    /// @notice Maps escrow ID to dispute ID (prevents duplicates)
    /// @dev C-03: One dispute per escrow to prevent panel shopping
    mapping(uint256 => uint256) public escrowToDisputeId;

    /// @notice Number of active (unresolved) disputes an arbitrator
    ///         is assigned to
    /// @dev H-01: Prevents withdrawal while actively assigned
    mapping(address => uint256) public activeDisputeCount;

    /// @notice Index of each arbitrator in the arbitratorPool array
    /// @dev M-03: Enables O(1) swap-and-pop removal from pool
    mapping(address => uint256) public arbitratorPoolIndex;

    /// @notice UnifiedFeeVault address for non-arbitrator fee routing
    /// @dev Receives 10% of dispute fees; handles internal 70/20/10
    ///      distribution (ODDAO / Staking Pool / Protocol Treasury)
    address public feeVault;

    /// @notice Pending fee vault address awaiting timelock acceptance
    /// @dev FE-H-01: Set by proposeFeeVault(), applied by
    ///      acceptFeeVault() after FEE_VAULT_DELAY elapses
    address public pendingFeeVault;

    /// @notice Timestamp when the fee vault change was proposed
    /// @dev FE-H-01: acceptFeeVault() requires
    ///      block.timestamp >= feeVaultChangeTimestamp + FEE_VAULT_DELAY
    uint256 public feeVaultChangeTimestamp;

    /// @dev Removed: formerly slashBps (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    uint256 private __removedSlashBps;

    /// @dev Removed: formerly reservedAppealFee (preserves storage layout)
    // solhint-disable-next-line var-name-mixedcase
    mapping(uint256 => uint256) private __removedReservedAppealFee;

    /// @notice Reserved storage gap for future upgradeable variables
    uint256[48] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a dispute is created (pending selection)
    /// @param disputeId Unique dispute ID
    /// @param escrowId Associated escrow ID
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param amount Disputed amount in XOM
    /// @param disputeFee Fee collected from dispute creator
    /// @param selectionBlock Block number for arbitrator selection
    event DisputeCreated(
        uint256 indexed disputeId,
        uint256 indexed escrowId,
        address buyer,
        address seller,
        uint256 amount,
        uint256 disputeFee,
        uint256 selectionBlock
    );

    /// @notice Emitted when arbitrator selection is finalized
    /// @param disputeId Dispute ID
    /// @param arbitrators Selected 3-member arbitrator panel
    /// @param deadline Resolution deadline timestamp
    event ArbitratorSelectionFinalized(
        uint256 indexed disputeId,
        address[3] arbitrators,
        uint256 deadline
    );

    /// @notice Emitted when an arbitrator casts a vote
    /// @param disputeId Dispute ID
    /// @param arbitrator Voting arbitrator address
    /// @param vote Release or Refund
    event VoteCast(
        uint256 indexed disputeId,
        address indexed arbitrator,
        VoteType vote
    );

    /// @notice Emitted when a dispute is resolved
    /// @param disputeId Dispute ID
    /// @param outcome Winning vote type
    /// @param releaseVotes Number of release votes
    /// @param refundVotes Number of refund votes
    event DisputeResolved(
        uint256 indexed disputeId,
        VoteType outcome,
        uint8 releaseVotes,
        uint8 refundVotes
    );

    /// @notice Emitted when evidence is submitted
    /// @param disputeId Dispute ID
    /// @param submitter Address submitting evidence
    /// @param ipfsCID IPFS content identifier hash
    event EvidenceSubmitted(
        uint256 indexed disputeId,
        address indexed submitter,
        bytes32 ipfsCID
    );

    /// @notice Emitted when dispute times out (default resolution)
    /// @param disputeId Dispute ID
    /// @param triggeredBy Address that triggered default resolution
    event DisputeDefaultResolved(
        uint256 indexed disputeId,
        address indexed triggeredBy
    );

    /// @notice Emitted when arbitrator registers
    /// @param arbitrator Arbitrator address
    /// @param stake Amount staked in XOM
    event ArbitratorRegistered(
        address indexed arbitrator,
        uint256 stake
    );

    /// @notice Emitted when arbitrator withdraws
    /// @param arbitrator Arbitrator address
    /// @param amount Amount withdrawn in XOM
    event ArbitratorWithdrawn(
        address indexed arbitrator,
        uint256 amount
    );

    /// @notice Emitted when dispute fees are distributed
    /// @param disputeId Dispute ID
    /// @param arbitratorShare Total amount sent to arbitrators
    /// @param vaultShare Amount sent to UnifiedFeeVault
    event FeesDistributed(
        uint256 indexed disputeId,
        uint256 arbitratorShare,
        uint256 vaultShare
    );

    /// @notice Emitted when contract references are updated
    /// @param participation New participation contract address
    /// @param escrowAddr New escrow contract address
    event ContractsUpdated(
        address indexed participation,
        address indexed escrowAddr
    );

    /// @notice Emitted when a fee vault address change is proposed
    /// @param current Current UnifiedFeeVault address
    /// @param proposed Proposed new UnifiedFeeVault address
    /// @param effectiveAt Timestamp when the change can be accepted
    event FeeVaultChangeProposed(
        address indexed current,
        address indexed proposed,
        uint256 effectiveAt
    );

    /// @notice Emitted when a proposed fee vault change is accepted
    /// @param oldVault Previous UnifiedFeeVault address
    /// @param newVault New UnifiedFeeVault address
    event FeeVaultChangeAccepted(
        address indexed oldVault,
        address indexed newVault
    );

    /// @notice Emitted when minimum arbitrator stake is updated
    /// @param oldStake Previous minimum stake
    /// @param newStake New minimum stake
    event MinStakeUpdated(
        uint256 oldStake,
        uint256 newStake
    );

    /// @notice Emitted when arbitrator selection is rescheduled
    ///         because the original selection block's hash expired
    /// @param disputeId Dispute ID whose selection was rescheduled
    /// @param newSelectionBlock New block number seeding selection
    event ArbitratorReselectionScheduled(
        uint256 indexed disputeId,
        uint256 newSelectionBlock
    );

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

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
     * @notice Initialize the arbitration contract
     * @dev Sets up roles, contract references, and default parameters.
     *      All four addresses must be non-zero.
     * @param _participation OmniParticipation contract address
     * @param _escrow MinimalEscrow contract address
     * @param _xomToken XOM token contract address
     * @param _feeVault UnifiedFeeVault address (receives 10% of fees)
     */
    function initialize(
        address _participation,
        address _escrow,
        address _xomToken,
        address _feeVault
    ) external initializer {
        // M-01: Zero-address validation for all parameters
        if (_participation == address(0)) revert ZeroAddress();
        if (_escrow == address(0)) revert ZeroAddress();
        if (_xomToken == address(0)) revert ZeroAddress();
        if (_feeVault == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISPUTE_ADMIN_ROLE, msg.sender);

        participation = IArbitrationParticipation(_participation);
        escrow = IArbitrationEscrow(_escrow);
        xomToken = IERC20(_xomToken);
        feeVault = _feeVault;

        nextDisputeId = 1;
        minArbitratorStake = 10_000 ether; // 10,000 XOM
    }

    // ══════════════════════════════════════════════════════════════════
    //                     ARBITRATOR REGISTRATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Register as an arbitrator by staking XOM
     * @dev Must meet OmniParticipation qualification (score >= 50,
     *      KYC Tier 4). Transfers XOM from caller to this contract.
     * @param amount XOM to stake (must be >= minArbitratorStake)
     */
    function registerArbitrator(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        address caller = _msgSender();

        if (!participation.canBeValidator(caller)) {
            revert NotQualifiedArbitrator();
        }
        if (amount < minArbitratorStake) {
            revert InsufficientArbitratorStake(
                amount,
                minArbitratorStake
            );
        }

        xomToken.safeTransferFrom(
            caller,
            address(this),
            amount
        );
        arbitratorStakes[caller] += amount;

        if (!isInArbitratorPool[caller]) {
            isInArbitratorPool[caller] = true;
            arbitratorPoolIndex[caller] =
                arbitratorPool.length;
            arbitratorPool.push(caller);
        }

        emit ArbitratorRegistered(caller, amount);
    }

    /**
     * @notice Withdraw arbitrator stake (if not actively assigned)
     * @dev H-01: Reverts if the arbitrator has active dispute
     *      assignments. M-03: Removes arbitrator from pool via
     *      swap-and-pop if stake falls below minimum.
     * @param amount XOM to withdraw
     */
    function withdrawArbitratorStake(
        uint256 amount
    ) external nonReentrant {
        address caller = _msgSender();

        // H-01: Block withdrawal while assigned to active disputes
        if (activeDisputeCount[caller] > 0) {
            revert ArbitratorBusyInDispute();
        }

        if (arbitratorStakes[caller] < amount) {
            revert InsufficientArbitratorStake(
                arbitratorStakes[caller],
                amount
            );
        }

        arbitratorStakes[caller] -= amount;

        // M-03: Remove from pool via swap-and-pop if below minimum
        if (
            arbitratorStakes[caller] < minArbitratorStake &&
            isInArbitratorPool[caller]
        ) {
            _removeFromArbitratorPool(caller);
        }

        xomToken.safeTransfer(caller, amount);

        emit ArbitratorWithdrawn(caller, amount);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       DISPUTE CREATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a dispute for an escrow transaction (phase 1)
     * @dev H-02: Two-phase arbitrator selection. This function stores
     *      the current block number but does NOT select arbitrators.
     *      The caller must invoke finalizeArbitratorSelection() at
     *      least 2 blocks later.
     *      C-01: Collects the 5% dispute fee from the creator via
     *      safeTransferFrom.
     *      C-03: Only one dispute per escrow is allowed.
     * @param escrowId ID of the escrow to dispute
     */
    function createDispute(
        uint256 escrowId
    ) external nonReentrant whenNotPaused {
        address caller = _msgSender();

        // C-03: Prevent duplicate disputes per escrow
        if (escrowToDisputeId[escrowId] != 0) {
            revert EscrowAlreadyDisputed(escrowId);
        }

        address buyer = escrow.getBuyer(escrowId);
        address seller = escrow.getSeller(escrowId);
        uint256 amount = escrow.getAmount(escrowId);

        // Only buyer or seller can dispute
        if (caller != buyer && caller != seller) {
            revert NotEscrowParty();
        }

        // C-01: Calculate and collect dispute fee (5% of amount)
        uint256 fee =
            (amount * ARBITRATION_FEE_BPS) / BPS;
        // M-01 (Round 6): Prevent zero-fee disputes for dust amounts
        if (fee == 0) revert DisputedAmountTooSmall();
        xomToken.safeTransferFrom(
            caller,
            address(this),
            fee
        );

        uint256 disputeId = nextDisputeId;
        ++nextDisputeId;

        Dispute storage d = disputes[disputeId];
        d.escrowId = escrowId;
        d.buyer = buyer;
        d.seller = seller;
        // solhint-disable-next-line not-rely-on-time
        d.createdAt = block.timestamp;
        d.disputedAmount = amount;
        d.disputeFee = fee;
        // H-02: Store block number for two-phase selection
        d.selectionBlock = block.number;
        d.status = DisputeStatus.PendingSelection;

        // C-03: Map escrow to dispute
        escrowToDisputeId[escrowId] = disputeId;

        // v2 refund-race fix: mark the escrow disputed so the buyer cannot
        // self-refund the expired escrow (or a contract atomically release it)
        // while this panel deliberates. A direct call (not try/catch) is
        // intentional: if the escrow is already resolved or absent, markDisputed
        // reverts and this dispute creation reverts with it — you cannot open a
        // panel dispute against a settled escrow. Reentrancy-safe: createDispute
        // is nonReentrant and markDisputed performs no external calls.
        escrow.markDisputed(escrowId);

        emit DisputeCreated(
            disputeId,
            escrowId,
            buyer,
            seller,
            amount,
            fee,
            block.number
        );
    }

    /**
     * @notice Finalize arbitrator selection for a pending dispute
     *         (phase 2)
     * @dev H-02: Must be called at least 2 blocks after
     *      createDispute() so the caller cannot predict the
     *      blockhash used for selection. Uses
     *      blockhash(d.selectionBlock) which is unknown at dispute
     *      creation time.
     * @param disputeId Dispute ID to finalize
     */
    function finalizeArbitratorSelection(
        uint256 disputeId
    ) external nonReentrant whenNotPaused {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.PendingSelection) {
            revert SelectionAlreadyFinalized(disputeId);
        }

        // H-03: Only buyer or seller can finalize arbitrator selection.
        // Prevents a third party from manipulating the panel by calling
        // finalize at a strategically chosen block.
        address caller = _msgSender();
        if (caller != d.buyer && caller != d.seller) {
            revert NotEscrowParty();
        }

        // Must wait at least 2 blocks
        if (block.number < d.selectionBlock + 2) {
            revert SelectionTooEarly(
                block.number,
                d.selectionBlock + 2
            );
        }

        // Recovery: blockhash() returns zero once the selection block
        // is older than 256 blocks, which would seed selection with a
        // degenerate zero hash. Require reselectArbitrators() instead.
        if (blockhash(d.selectionBlock) == bytes32(0)) {
            revert SelectionBlockhashExpired();
        }

        // Select 3 arbitrators using stored block's hash
        // msg.sender is intentionally excluded from the selection hash
        // to prevent panel manipulation via caller identity.
        address[3] memory selected = _selectArbitrators(
            d.escrowId,
            3,
            d.buyer,
            d.seller,
            d.selectionBlock
        );

        d.arbitrators = selected;
        // solhint-disable-next-line not-rely-on-time
        d.deadline = block.timestamp + DEFAULT_DEADLINE;
        d.status = DisputeStatus.Active;

        // H-01: Increment active dispute count per arbitrator
        for (uint256 i = 0; i < 3; ++i) {
            ++activeDisputeCount[selected[i]];
        }

        emit ArbitratorSelectionFinalized(
            disputeId,
            selected,
            d.deadline
        );
    }

    /**
     * @notice Reschedule arbitrator selection when the original
     *         selection block's hash has expired
     * @dev Once the selection block is older than 256 blocks,
     *      blockhash() returns zero and
     *      finalizeArbitratorSelection() reverts with
     *      SelectionBlockhashExpired. This resets selectionBlock to
     *      the current block so a fresh, valid blockhash can seed the
     *      panel. The normal finalizeArbitratorSelection() (which
     *      requires a 2-block wait) then runs as usual. Callable by
     *      anyone to unblock the dispute.
     * @param disputeId Dispute ID with a stale selection block
     */
    function reselectArbitrators(
        uint256 disputeId
    ) external {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.PendingSelection) {
            revert InvalidDisputeStatus();
        }

        // H-03: Only buyer or seller can reselect. Prevents a third
        // party from griefing by repeatedly resetting the selection
        // block, delaying dispute resolution indefinitely.
        address caller = _msgSender();
        if (caller != d.buyer && caller != d.seller) {
            revert NotEscrowParty();
        }

        // Blockhash is only available for the most recent 256 blocks
        if (block.number <= d.selectionBlock + 256) {
            revert SelectionNotFinalized(disputeId);
        }

        d.selectionBlock = block.number;

        emit ArbitratorReselectionScheduled(
            disputeId,
            block.number
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                        EVIDENCE SUBMISSION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Submit evidence for a dispute (IPFS CID)
     * @dev Only buyer, seller, or assigned arbitrators can submit.
     *      Evidence is immutable once recorded on-chain.
     * @param disputeId Dispute ID
     * @param ipfsCID IPFS content identifier hash
     */
    function submitEvidence(
        uint256 disputeId,
        bytes32 ipfsCID
    ) external whenNotPaused {
        address caller = _msgSender();

        Dispute storage d = disputes[disputeId];
        // M-05: Use createdAt instead of escrowId for existence
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Active) {
            revert EvidencePeriodClosed();
        }
        if (d.evidenceCIDs.length >= MAX_EVIDENCE) {
            revert EvidencePeriodClosed();
        }

        // Only parties or assigned arbitrators can submit
        bool authorized = (
            caller == d.buyer ||
            caller == d.seller
        );

        // Check initial panel arbitrators
        if (!authorized) {
            for (uint256 i = 0; i < 3; ++i) {
                if (d.arbitrators[i] == caller) {
                    authorized = true;
                    break;
                }
            }
        }

        if (!authorized) revert NotAssignedArbitrator();

        d.evidenceCIDs.push(ipfsCID);
        evidenceSubmitters[disputeId][ipfsCID] = caller;

        emit EvidenceSubmitted(
            disputeId,
            caller,
            ipfsCID
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                           VOTING
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Cast a vote on a dispute (release to seller or refund
     *         to buyer)
     * @dev Only assigned arbitrators can vote. 2-of-3 majority
     *      resolves. H-03: Enforces deadline. C-01/C-02: On
     *      resolution, distributes fees and triggers escrow fund
     *      movement.
     * @param disputeId Dispute ID
     * @param vote Release (to seller) or Refund (to buyer)
     */
    function castVote(
        uint256 disputeId,
        VoteType vote
    ) external nonReentrant whenNotPaused {
        address caller = _msgSender();

        if (vote == VoteType.None) revert InvalidVoteType();

        Dispute storage d = disputes[disputeId];
        // M-05: Use createdAt for existence check
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Active) {
            revert DisputeAlreadyResolved(disputeId);
        }

        // H-03: Enforce voting deadline
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > d.deadline) {
            revert DeadlineExpired();
        }

        // Verify caller is assigned arbitrator
        bool isArbitrator = false;
        for (uint256 i = 0; i < 3; ++i) {
            if (d.arbitrators[i] == caller) {
                isArbitrator = true;
                break;
            }
        }
        if (!isArbitrator) revert NotAssignedArbitrator();

        // Check not already voted
        if (votes[disputeId][caller] != VoteType.None) {
            revert AlreadyVoted();
        }

        votes[disputeId][caller] = vote;

        if (vote == VoteType.Release) {
            ++d.releaseVotes;
        } else {
            ++d.refundVotes;
        }

        emit VoteCast(disputeId, caller, vote);

        // Check for 2-of-3 majority
        if (d.releaseVotes >= 2) {
            _resolveDispute(
                disputeId,
                VoteType.Release,
                true
            );
        } else if (d.refundVotes >= 2) {
            _resolveDispute(
                disputeId,
                VoteType.Refund,
                false
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                       TIMEOUT RESOLUTION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Trigger default resolution after deadline passes
     * @dev Default: refund to buyer. Anyone can trigger after
     *      deadline. C-01: Distributes fees. C-02: Triggers escrow
     *      refund.
     * @param disputeId Dispute ID
     */
    function triggerDefaultResolution(
        uint256 disputeId
    ) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        // M-05: Use createdAt for existence check
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (
            d.status == DisputeStatus.Resolved ||
            d.status == DisputeStatus.DefaultResolved
        ) {
            revert DisputeAlreadyResolved(disputeId);
        }
        // M-02 (Round 6): Reject PendingSelection disputes -- arbitrators
        // have not been selected yet, so default resolution is premature.
        // The dispute creator must call finalizeArbitratorSelection() first.
        if (d.status == DisputeStatus.PendingSelection) {
            revert SelectionNotFinalized(disputeId);
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < d.deadline) {
            revert DeadlineNotReached(d.deadline);
        }

        d.status = DisputeStatus.DefaultResolved;

        // H-01: Decrement active dispute count for arbitrators
        for (uint256 i = 0; i < 3; ++i) {
            if (d.arbitrators[i] != address(0)) {
                --activeDisputeCount[d.arbitrators[i]];
            }
        }

        // C-01: Distribute collected fees
        _collectAndDistributeFee(disputeId);

        // C-02: Default is refund to buyer
        _triggerEscrowResolution(d.escrowId, false);

        emit DisputeDefaultResolved(disputeId, _msgSender());
        emit DisputeResolved(
            disputeId,
            VoteType.Refund,
            d.releaseVotes,
            d.refundVotes
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Get dispute details
     * @param disputeId Dispute ID
     * @return escrowId Escrow ID
     * @return buyer Buyer address
     * @return seller Seller address
     * @return arbitrators Array of 3 arbitrator addresses
     * @return releaseVotes Number of release votes
     * @return refundVotes Number of refund votes
     * @return deadline Dispute deadline timestamp
     * @return status Dispute status
     */
    function getDispute(
        uint256 disputeId
    )
        external
        view
        returns (
            uint256 escrowId,
            address buyer,
            address seller,
            address[3] memory arbitrators,
            uint8 releaseVotes,
            uint8 refundVotes,
            uint256 deadline,
            DisputeStatus status
        )
    {
        Dispute storage d = disputes[disputeId];
        return (
            d.escrowId,
            d.buyer,
            d.seller,
            d.arbitrators,
            d.releaseVotes,
            d.refundVotes,
            d.deadline,
            d.status
        );
    }

    /**
     * @notice Get evidence CIDs for a dispute
     * @param disputeId Dispute ID
     * @return Array of IPFS CID hashes
     */
    function getEvidence(
        uint256 disputeId
    ) external view returns (bytes32[] memory) {
        return disputes[disputeId].evidenceCIDs;
    }

    /**
     * @notice Get arbitrator pool size
     * @return Number of registered arbitrators
     */
    function arbitratorPoolSize()
        external
        view
        returns (uint256)
    {
        return arbitratorPool.length;
    }

    /**
     * @notice Calculate arbitration fee for an amount
     * @param amount Disputed amount
     * @return totalFee Total fee (5% of disputed amount)
     * @return arbitratorShare Amount to arbitrators (90% total, 30% each)
     * @return vaultShare Amount to UnifiedFeeVault (10%)
     */
    function calculateFee(
        uint256 amount
    )
        external
        pure
        returns (
            uint256 totalFee,
            uint256 arbitratorShare,
            uint256 vaultShare
        )
    {
        totalFee = (amount * ARBITRATION_FEE_BPS) / BPS;
        // 3 arbitrators × 30% = 90% to the panel (matches the on-chain
        // distribution in {_collectAndDistributeFee}); vault absorbs dust.
        uint256 perArb = (totalFee * PER_ARBITRATOR_FEE_SHARE) / BPS;
        arbitratorShare = perArb * 3;
        vaultShare = totalFee - arbitratorShare;
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update contract references
     * @dev M-04: Validates that non-zero addresses contain code and
     *      emits an event on update.
     * @param _participation New OmniParticipation address
     * @param _escrow New escrow address
     */
    function updateContracts(
        address _participation,
        address _escrow
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // M-04: Zero-address and code-existence checks
        if (_participation != address(0)) {
            if (_participation.code.length == 0) {
                revert NotAContract(_participation);
            }
            participation =
                IArbitrationParticipation(_participation);
        }
        if (_escrow != address(0)) {
            if (_escrow.code.length == 0) {
                revert NotAContract(_escrow);
            }
            escrow = IArbitrationEscrow(_escrow);
        }

        emit ContractsUpdated(_participation, _escrow);
    }

    /**
     * @notice Update minimum arbitrator stake
     * @dev M-08: Bounded between 100 XOM and 10,000,000 XOM.
     * @param _minStake New minimum in XOM (18 decimals)
     */
    function setMinArbitratorStake(
        uint256 _minStake
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // M-08: Enforce bounds
        if (
            _minStake < MIN_STAKE_LOWER_BOUND ||
            _minStake > MIN_STAKE_UPPER_BOUND
        ) {
            revert StakeOutOfBounds(
                _minStake,
                MIN_STAKE_LOWER_BOUND,
                MIN_STAKE_UPPER_BOUND
            );
        }

        uint256 oldStake = minArbitratorStake;
        minArbitratorStake = _minStake;

        emit MinStakeUpdated(oldStake, _minStake);
    }

    /**
     * @notice Propose a new UnifiedFeeVault address (step 1 of 2)
     * @dev FE-H-01 remediation: starts a 48-hour timelock before the
     *      new vault address can be accepted. This prevents a
     *      compromised admin from instantly redirecting all fees.
     *      Emits {FeeVaultChangeProposed}.
     * @param _feeVault Proposed new UnifiedFeeVault address
     */
    function proposeFeeVault(
        address _feeVault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeVault == address(0)) revert ZeroAddress();

        pendingFeeVault = _feeVault;
        // solhint-disable-next-line not-rely-on-time
        feeVaultChangeTimestamp = block.timestamp;

        emit FeeVaultChangeProposed(
            feeVault,
            _feeVault,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + FEE_VAULT_DELAY
        );
    }

    /**
     * @notice Accept the pending fee vault address change (step 2 of 2)
     * @dev FE-H-01 remediation: can only be called after the 48-hour
     *      timelock has elapsed. Clears the pending state after
     *      applying the change. Emits {FeeVaultChangeAccepted}.
     */
    function acceptFeeVault()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingFeeVault == address(0)) {
            revert NoFeeVaultChangePending();
        }

        uint256 availableAt =
            feeVaultChangeTimestamp + FEE_VAULT_DELAY;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < availableAt) {
            revert FeeVaultTimelockActive(availableAt);
        }

        address oldVault = feeVault;
        feeVault = pendingFeeVault;

        // Clear pending state
        pendingFeeVault = address(0);
        feeVaultChangeTimestamp = 0;

        emit FeeVaultChangeAccepted(oldVault, feeVault);
    }

    /// @notice Pause the contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve a dispute with the given outcome
     * @dev H-01: Decrements active dispute counts so the assigned
     *      arbitrators can withdraw their stake afterward.
     *      C-01: Distributes fees. C-02: Triggers escrow movement.
     * @param disputeId Dispute ID to resolve
     * @param outcome Winning vote type (Release or Refund)
     * @param isRelease True if outcome is Release (to seller)
     */
    function _resolveDispute(
        uint256 disputeId,
        VoteType outcome,
        bool isRelease
    ) internal {
        Dispute storage d = disputes[disputeId];
        d.status = DisputeStatus.Resolved;

        // H-01: Release the original panel's stake locks now that the
        // dispute is resolved.
        for (uint256 i = 0; i < 3; ++i) {
            if (d.arbitrators[i] != address(0)) {
                --activeDisputeCount[d.arbitrators[i]];
            }
        }

        // C-01: Distribute collected fees
        _collectAndDistributeFee(disputeId);

        // C-02: Execute the escrow fund movement
        _triggerEscrowResolution(d.escrowId, isRelease);

        emit DisputeResolved(
            disputeId,
            outcome,
            d.releaseVotes,
            d.refundVotes
        );
    }

    /**
     * @notice Distribute the collected dispute fee per 90/10 split
     * @dev C-01: Splits the fee stored in d.disputeFee among the three
     *      arbitrators (30% each = 90%) and UnifiedFeeVault (10%). The
     *      vault handles the internal 70/20/10 sub-distribution. Uses
     *      XOM tokens already held by this contract from dispute
     *      creation.
     * @param disputeId Dispute ID whose fee to distribute
     */
    function _collectAndDistributeFee(
        uint256 disputeId
    ) internal {
        Dispute storage d = disputes[disputeId];
        uint256 fee = d.disputeFee;
        if (fee == 0) return;

        // Zero out fee to prevent double-distribution
        d.disputeFee = 0;

        // Each arbitrator receives 30% of the total fee; the vault
        // receives the remaining 10% (absorbs rounding dust).
        uint256 perArb = (fee * PER_ARBITRATOR_FEE_SHARE) / BPS;
        uint256 arbitratorsTotal = perArb * 3;
        uint256 vaultAmount = fee - arbitratorsTotal;

        for (uint256 i = 0; i < 3; ++i) {
            if (perArb > 0) {
                xomToken.safeTransfer(
                    d.arbitrators[i],
                    perArb
                );
            }
        }

        // Fee vault share (10%)
        if (vaultAmount > 0) {
            xomToken.safeTransfer(feeVault, vaultAmount);
        }

        emit FeesDistributed(
            disputeId,
            arbitratorsTotal,
            vaultAmount
        );
    }

    /**
     * @notice Trigger escrow fund movement on dispute resolution.
     * @dev C-02: Calls escrow.resolveDispute() to release or refund
     *      funds. The fund-move MUST succeed for the verdict to stand:
     *      a direct (non-swallowed) call makes the resolution tx atomic,
     *      so if resolveDispute reverts (e.g. the fee vault is paused),
     *      the terminal state transition that called this LAST
     *      (status / stake release) reverts with it and the dispute
     *      stays re-callable once the failure clears. Payouts use ERC20
     *      safeTransfer (no receive callback), so a "winner" contract
     *      cannot grief this.
     * @param escrowId Escrow ID to resolve
     * @param releaseFunds True to release to seller, false to
     *        refund buyer
     */
    function _triggerEscrowResolution(
        uint256 escrowId,
        bool releaseFunds
    ) internal {
        escrow.resolveDispute(escrowId, releaseFunds);
    }

    /**
     * @notice Remove an arbitrator from the pool using swap-and-pop
     * @dev M-03: Efficiently removes the arbitrator in O(1) by
     *      swapping with the last element and popping.
     * @param arb Address to remove from pool
     */
    function _removeFromArbitratorPool(
        address arb
    ) internal {
        uint256 idx = arbitratorPoolIndex[arb];
        uint256 lastIdx = arbitratorPool.length - 1;

        if (idx != lastIdx) {
            address lastArb = arbitratorPool[lastIdx];
            arbitratorPool[idx] = lastArb;
            arbitratorPoolIndex[lastArb] = idx;
        }

        arbitratorPool.pop();
        delete arbitratorPoolIndex[arb];
        isInArbitratorPool[arb] = false;
    }

    /**
     * @notice Deterministically select arbitrators for a dispute
     * @dev H-02: Uses blockhash(selectionBlock) which is unknown
     *      to the dispute creator at creation time (two-phase
     *      commit). Combined with escrowId, block.number, and
     *      msg.sender for additional entropy.
     *
     *      Note: For production mainnet, consider upgrading to
     *      Chainlink VRF for cryptographic randomness guarantees.
     *      The two-phase blockhash approach protects against user
     *      manipulation but a colluding block proposer could
     *      theoretically influence selection by withholding blocks.
     *
     * @param escrowId Escrow ID
     * @param count Number of arbitrators to select
     * @param buyer Buyer address (excluded from selection)
     * @param seller Seller address (excluded from selection)
     * @param selBlock Block number whose hash seeds selection
     * @return selected Array of selected arbitrator addresses
     */
    function _selectArbitrators(
        uint256 escrowId,
        uint256 count,
        address buyer,
        address seller,
        uint256 selBlock
    ) internal view returns (address[3] memory selected) {
        uint256 poolSize = arbitratorPool.length;
        if (poolSize < count) revert NotEnoughArbitrators();

        uint256 found = 0;
        uint256 nonce = 0;

        while (found < count && nonce < MAX_ARBITRATOR_SEARCH) {
            // Deterministic but unpredictable hash using the
            // stored selection block's hash
            bytes32 h = keccak256(
                abi.encodePacked(
                    escrowId,
                    blockhash(selBlock),
                    block.number,
                    nonce
                )
            );
            uint256 idx = uint256(h) % poolSize;
            address candidate = arbitratorPool[idx];

            // Skip parties, unqualified, or duplicates
            bool valid = (
                candidate != buyer &&
                candidate != seller &&
                arbitratorStakes[candidate] >=
                    minArbitratorStake &&
                participation.canBeValidator(candidate)
            );

            if (valid) {
                bool duplicate = false;
                for (uint256 j = 0; j < found; ++j) {
                    if (selected[j] == candidate) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    selected[found] = candidate;
                    ++found;
                }
            }

            ++nonce;
        }

        if (found < count) revert NotEnoughArbitrators();
    }

    /**
     * @notice Authorize UUPS upgrades
     * @dev Pioneer-phase: the deployer (DEFAULT_ADMIN_ROLE) authorizes
     *      upgrades directly via upgradeToAndCall, with no timelock.
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        (newImplementation);
    }

    // ══════════════════════════════════════════════════════════════════
    //                   ERC-2771 CONTEXT OVERRIDES
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve _msgSender diamond between ContextUpgradeable
     *         and ERC2771ContextUpgradeable
     * @dev Delegates to ERC2771ContextUpgradeable which returns the
     *      original sender appended by a trusted forwarder, or falls
     *      back to msg.sender for direct calls.
     * @return The effective sender address for this call
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
     * @notice Resolve _msgData diamond between ContextUpgradeable
     *         and ERC2771ContextUpgradeable
     * @dev Delegates to ERC2771ContextUpgradeable which strips the
     *      appended sender address from calldata when called via a
     *      trusted forwarder.
     * @return The effective calldata for this call
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
     * @notice Resolve _contextSuffixLength diamond between
     *         ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev ERC-2771 specifies a 20-byte suffix (the forwarded sender
     *      address). Base ContextUpgradeable returns 0.
     * @return Length in bytes of the context suffix (20 for ERC-2771)
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
