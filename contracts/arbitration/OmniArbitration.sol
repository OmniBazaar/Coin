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
    /// @notice Check if user can be a service node (score >= 25, KYC 2)
    /// @dev The same bar applies to a listing node. Arbitrators use this
    ///      qualification (founder ruling 2026-10-20) rather than the
    ///      validator standard.
    /// @param user Address to check
    /// @return True if qualified as an arbitrator
    function canBeServiceNode(address user) external view returns (bool);

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

    /**
     * @notice Clear an escrow's disputed flag (cancelled dispute)
     * @param escrowId Escrow identifier
     */
    function unmarkDisputed(uint256 escrowId) external;
}

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Caller is not qualified as arbitrator
error NotQualifiedArbitrator();
/**
 * @notice Too few registered judges to seat a committee for this escrow
 * @param available Judges currently in the pool
 * @param required Judges needed (3 + buyer/seller if they are judges)
 */
error ArbitrationPoolNotSeated(uint256 available, uint256 required);

/// @notice Dispute is not in PendingSelection, so it cannot be cancelled
error DisputeNotPendingSelection(uint256 disputeId);

/// @notice Cancellation is not allowed yet (selection block still recent)
error CancellationTooEarly(uint256 disputeId, uint256 allowedAtBlock);

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
/**
 * @title IArbitratorKyc
 * @notice The one read arbitrator qualification needs from OmniRegistration
 * @dev Read directly so arbitrator qualification never depends on a node-role
 *      gate: those gates change (they did on 2026-10-20) and every change
 *      silently re-qualified or disqualified the judge panel.
 */
interface IArbitratorKyc {
    function hasKycTier2(address user) external view returns (bool);
}

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
        AppealPendingSelection, // @dev deprecated — appeal tier removed, never set
        Cancelled // selection failed; the fee was refunded and the escrow unfrozen
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
        /// @dev The address that paid `disputeFee` (buyer OR seller — either
        ///      party may open a panel dispute). Cancellation refunds THIS
        ///      address, never a hard-coded party. Appended; safe because no
        ///      dispute has ever been created on mainnet (nextDisputeId == 1).
        address feePayer;
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

    /// @notice Seat bond, in basis points of the disputed amount (10,000 = 1x)
    uint256 public constant SEAT_BOND_BPS = 10_000;

    /// @notice How long the review (escalation) window stays open after a verdict
    uint256 public constant CHALLENGE_WINDOW = 7 days;

    /// @notice How long the review panel has to decide once a review is open
    uint256 public constant REVIEW_WINDOW = 3 days;

    /// @notice Bond a party posts to demand a review, in basis points (1,000 = 10%)
    uint256 public constant ESCALATION_BOND_BPS = 5_000;

    /// @notice Floor on the escalation bond (1,000 XOM)
    uint256 public constant MIN_ESCALATION_BOND = 100 ether;

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

    // ── 2026-10 panel hardening ──────────────────────────────────────────
    /// @notice Seat bond not posted for the calling judge
    error SeatBondMissing(uint256 disputeId, address judge);
    /// @notice Seat bond already posted for the calling judge
    error SeatBondAlreadyPosted(uint256 disputeId, address judge);
    /// @notice Caller is not seated on this dispute
    error NotSeatedJudge(uint256 disputeId, address caller);
    /// @notice The challenge window has already closed
    error ChallengeWindowClosed(uint256 deadline);
    /// @notice The challenge window is still open; bonds stay locked
    error ChallengeWindowOpen(uint256 deadline);
    /// @notice Escalation was already opened for this dispute
    error EscalationAlreadyOpened(uint256 disputeId);
    /// @notice Not enough unassigned, qualified judges to seat the review panel
    error EscalationNotSeatable(uint256 seatable);
    /// @notice Caller is not a party to the dispute
    error NotChallengeParty();
    /// @notice Withdraw blocked: the caller has bonds still held
    error BondsStillLocked(address arbitrator, uint256 amount);
    /// @notice No verdict was reached in this round
    error NoVerdict(uint256 disputeId);
    /// @notice Judge is not registered as a founder arbitrator
    error NotFounderArbitrator(address account);

    /// @notice Per-dispute seat bond posted by each seated judge
    /// @dev 2026-10 panel hardening: a judge's decision has a price. The bond
    ///      is 1x the disputed amount, held for the challenge window, and
    ///      forfeited to the harmed party if a review panel overturns the
    ///      verdict. Returned in full when the window closes clean.
    mapping(uint256 => mapping(address => uint256)) public seatBonds;

    /// @notice Number of seat bonds posted for a dispute (0..3)
    mapping(uint256 => uint256) public seatBondCount;

    /// @notice XOM held against a judge's bond obligations
    mapping(address => uint256) public lockedBond;

    /// @notice Timestamp after which a resolved dispute's bonds unlock
    mapping(uint256 => uint256) public challengeDeadline;

    /// @notice Whether a review (escalation) panel was opened
    mapping(uint256 => bool) public escalated;

    /// @notice Review panel seated by {escalate}
    mapping(uint256 => address[3]) public escalationPanel;

    /// @notice Review panel vote tallies
    mapping(uint256 => uint8) public escalationReleaseVotes;
    mapping(uint256 => uint8) public escalationRefundVotes;

    /// @notice Bond posted by the party that demanded the review
    mapping(uint256 => uint256) public escalationBond;

    /// @notice One-shot flag: the no-verdict path already reselected a panel
    mapping(uint256 => bool) public reselected;

    /// @notice Founder-seeded arbitrators (pioneer phase)
    mapping(address => bool) public founderArbitrator;

    /// @notice Review votes per dispute per judge
    mapping(uint256 => mapping(address => VoteType)) public reviewVotes;

    /// @notice Party that opened the review (receives an overturned verdict's bonds)
    mapping(uint256 => address) public reviewChallenger;

    /// @notice Deadline for the review panel to decide (independent of the
    ///         challenge window; audit C-02)
    mapping(uint256 => uint256) public reviewDeadline;

    /// @notice OmniRegistration, for the KYC read in {canBeArbitrator}
    address public registration;

    /// @notice Reserved storage gap for future upgradeable variables
    uint256[33] private __gap;

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

    /// @notice Emitted when an unseatable dispute is cancelled and refunded
    /// @param disputeId Dispute identifier
    /// @param escrowId Escrow identifier
    /// @param caller Address that cancelled
    /// @param refunded Fee returned to the disputer
    event DisputeCancelled(
        uint256 indexed disputeId,
        uint256 indexed escrowId,
        address indexed caller,
        uint256 refunded
    );

    /// @notice Emitted when a founder arbitrator is seeded or cleared
    event FounderArbitratorSet(address indexed account, bool allowed);

    /// @notice Emitted when the registration (KYC) source changes
    event RegistrationSet(address indexed registration);

    /// @notice Emitted when a review-panel judge votes
    event ReviewVoteCast(
        uint256 indexed disputeId,
        address indexed judge,
        VoteType vote
    );

    /// @notice Emitted when a judge posts the seat bond for a dispute
    event SeatBondPosted(
        uint256 indexed disputeId,
        address indexed judge,
        uint256 amount
    );

    /// @notice Emitted when a dispute's bonds unlock after the challenge window
    event BondsUnlocked(uint256 indexed disputeId);

    /// @notice Emitted when a party demands a review of a verdict
    event ReviewOpened(
        uint256 indexed disputeId,
        address indexed requester,
        uint256 bond,
        address[3] panel
    );

    /// @notice Emitted when a review closes without a decision
    event ReviewLapsed(uint256 indexed disputeId);

    /// @notice Emitted when the review panel upholds or overturns the verdict
    event ReviewDecided(
        uint256 indexed disputeId,
        bool overturned,
        uint256 forfeited
    );

    /// @notice Emitted when the escrow could not clear its disputed flag
    event EscrowUnmarkFailed(uint256 indexed escrowId);

    /// @notice Emitted when a no-verdict dispute returns to the status quo
    event DisputeReturnedToStatusQuo(
        uint256 indexed disputeId,
        uint256 feeRefunded
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
    /**
     * @notice Post-upgrade initializer for the panel hardening (version 2)
     * @dev Consumed by `upgradeToAndCall(impl, abi.encodeCall(initializeV2,
     *      (registration)))`. Without it the new gate has no KYC source and
     *      every judge is unqualified — the pool would be pruned to nothing
     *      (audit H-03). `reinitializer(2)` makes it callable exactly once.
     * @param registration_ OmniRegistration address (KYC reads)
     */
    function initializeV2(
        address registration_
    ) external reinitializer(2) {
        if (registration_.code.length == 0) revert NotAContract(registration_);
        registration = registration_;
        emit RegistrationSet(registration_);
    }

    /**
     * @notice Whether an account may serve as an arbitrator
     * @dev Own gate: a stake at or above the minimum AND an identity check
     *      (KYC tier 2), or the pioneer founder allowlist. Deliberately does
     *      NOT consult the service-node or validator gates — those describe
     *      what else an operator runs, not whether they may judge.
     * @param user Account to check
     * @return eligible True when the account may register or be seated
     */
    function canBeArbitrator(address user) public view returns (bool eligible) {
        if (arbitratorStakes[user] < minArbitratorStake) return false;
        return _qualifiedIdentity(user);
    }

    /**
     * @dev Identity half of the arbitrator gate, without the stake test —
     *      used at registration, where the stake arrives with the call.
     */
    function _qualifiedIdentity(address user) private view returns (bool) {
        if (founderArbitrator[user]) return true;
        if (registration == address(0)) return false;
        try IArbitratorKyc(registration).hasKycTier2(user) returns (bool kyc) {
            return kyc;
        } catch {
            return false;
        }
    }

    /**
     * @notice Seed or clear a pioneer-phase founder arbitrator
     * @dev The only bypass in {canBeArbitrator}. Admin-controlled because it is
     *      a trust list, and it is the reason a founder-seeded judge does not
     *      need a KYC tier recorded on chain.
     * @param account Account to change
     * @param allowed True to allowlist, false to remove
     */
    function setFounderArbitrator(
        address account,
        bool allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert NotFounderArbitrator(account);
        founderArbitrator[account] = allowed;
        emit FounderArbitratorSet(account, allowed);
    }

    /**
     * @notice Point the qualification gate at OmniRegistration
     * @param registration_ OmniRegistration address (KYC reads)
     */
    function setRegistration(
        address registration_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registration_.code.length == 0) revert NotAContract(registration_);
        registration = registration_;
        emit RegistrationSet(registration_);
    }

    function registerArbitrator(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        address caller = _msgSender();

        // Arbitrator qualification = the NODE standard, not the validator
        // standard (founder ruling 2026-10-20): participation score >= 25 and
        // KYC Tier 2. Judging a marketplace dispute is an operational duty
        // like hosting listings, not the capital/uptime commitment a
        // validator makes, and requiring validator-grade KYC kept the panel
        // below the three judges it needs to seat a committee.
        // Arbitrator qualification is its OWN gate (2026-10-20). It used to
        // ride the service-node standard, which meant a node-role rule change
        // silently re-qualified or disqualified every seated judge — and on
        // 2026-10-20 it disqualified all of them. A judge must prove a stake
        // and an identity; what else they run is not this contract's business.
        if (!_qualifiedIdentity(caller)) {
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

        _pruneUnqualified();

        if (!isInArbitratorPool[caller]) {
            isInArbitratorPool[caller] = true;
            arbitratorPoolIndex[caller] =
                arbitratorPool.length;
            arbitratorPool.push(caller);
        }

        emit ArbitratorRegistered(caller, amount);
    }

    /**
     * @notice Drop pooled judges that can no longer be selected
     * @dev Selection already skips them, but leaving them in the pool makes
     *      the seatable-count check and the pool size disagree — and a stale
     *      entry can sit in front of the scan window forever. Bounded by
     *      {SEATING_SCAN_LIMIT}; called when the pool is touched rather than
     *      on every read.
     */
    function _pruneUnqualified() private {
        uint256 i = 0;
        uint256 scanned = 0;
        while (i < arbitratorPool.length && scanned < SEATING_SCAN_LIMIT) {
            address candidate = arbitratorPool[i];
            ++scanned;
            bool eligible = canBeArbitrator(candidate);
            if (eligible) {
                ++i;
                continue;
            }
            _removeFromArbitratorPool(candidate);
            // `_removeFromArbitratorPool` swap-and-pops; re-check index i.
        }
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
        // Panel hardening: seat bonds stay locked through the challenge window,
        // so a judge cannot exit with the capital that secures a verdict.
        if (lockedBond[caller] > 0) {
            revert BondsStillLocked(caller, lockedBond[caller]);
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

    /// @notice Judges selected per dispute (buyer and seller excluded)
    uint256 public constant MIN_PANEL_SIZE = 3;

    /// @notice Maximum pool entries the seating check will inspect
    /// @dev A `canBeServiceNode` read fans out to several external calls, so
    ///      scanning the full pool would let a large pool run dispute creation
    ///      out of gas. Unqualified entries are pruned at registration, so the
    ///      pool should never need a deep scan; the bound fails closed.
    uint256 public constant SEATING_SCAN_LIMIT = 32;

    /// @notice Blocks after createDispute before others may cancel a stuck dispute
    /// @dev Long enough that a judge cannot be withdrawn and the dispute
    ///      cancelled in the same breath, short enough that a stuck fee is not
    ///      a multi-day problem (~8.5 minutes at 2s blocks).
    uint256 public constant CANCEL_DELAY_BLOCKS = 256;

    /**
     * @notice Count judges that could actually be seated for this escrow
     * @dev Mirrors the selection predicate exactly. The scan is bounded by
     *      {MAX_ARBITRATOR_SEARCH} so a large pool cannot make dispute
     *      creation unbounded in gas; it stops as soon as enough are found.
     * @param buyer Escrow buyer (excluded from panels)
     * @param seller Escrow seller (excluded from panels)
     * @return eligible Number of seatable, non-party judges found
     */
    function _seatableJudges(
        address buyer,
        address seller
    ) private view returns (uint256 eligible) {
        uint256 pooled = arbitratorPool.length;
        uint256 scan = pooled < SEATING_SCAN_LIMIT
            ? pooled
            : SEATING_SCAN_LIMIT;
        for (uint256 i = 0; i < scan; ++i) {
            address candidate = arbitratorPool[i];
            if (candidate == buyer || candidate == seller) continue;
            if (!canBeArbitrator(candidate)) continue;
            ++eligible;
            if (eligible >= MIN_PANEL_SIZE) return eligible;
        }
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

        // Refuse BEFORE taking the 5% fee unless a full committee is SEATABLE
        // for this escrow. Counting `arbitratorPool.length` is not enough: a
        // pooled judge can be under-staked, lose KYC, or lose participation
        // score, and selection skips them — so a pool of 3 stale entries
        // passed a length check and then failed selection, after the fee was
        // taken. Count only judges the selector would actually accept.
        uint256 seatable = _seatableJudges(buyer, seller);
        if (seatable < MIN_PANEL_SIZE) {
            revert ArbitrationPoolNotSeated(seatable, MIN_PANEL_SIZE);
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
        d.feePayer = caller;
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
     * @notice Cancel a dispute whose panel could never be seated
     * @dev `createDispute` takes the 5% fee up front and marks the escrow
     *      disputed (which freezes every unilateral exit). If selection then
     *      fails — judges withdrawn, under-staked, or disqualified in the
     *      two-block window — the dispute used to sit in PendingSelection
     *      forever: the fee had no refund path and the escrow stayed frozen
     *      until the 30-day timeout. This returns the fee, frees the
     *      escrow↔dispute mapping, and asks the escrow to clear its disputed
     *      flag, restoring the pre-dispute state exactly.
     *
     *      Callable by a party, or by anyone once {CANCEL_DELAY_BLOCKS} have
     *      passed, so a stuck dispute is never hostage to one silent party.
     * @param disputeId Dispute to cancel
     */
    function cancelDispute(uint256 disputeId) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.PendingSelection) {
            revert DisputeNotPendingSelection(disputeId);
        }

        address caller = _msgSender();
        bool party = caller == d.buyer || caller == d.seller;
        // solhint-disable-next-line not-rely-on-time
        uint256 allowedAt = d.selectionBlock + CANCEL_DELAY_BLOCKS;
        if (!party && block.number < allowedAt) {
            revert CancellationTooEarly(disputeId, allowedAt);
        }

        d.status = DisputeStatus.Cancelled;

        uint256 fee = d.disputeFee;
        d.disputeFee = 0;
        if (fee > 0) {
            xomToken.safeTransfer(d.feePayer, fee);
        }

        uint256 escrowId = d.escrowId;
        if (escrowToDisputeId[escrowId] == disputeId) {
            delete escrowToDisputeId[escrowId];
        }

        // Unfreeze the escrow. Best-effort on purpose: a legacy escrow that
        // predates `unmarkDisputed` (or one already resolved by the 30-day
        // timeout) must not block the fee refund or the mapping cleanup.
        // solhint-disable-next-line no-empty-blocks
        try escrow.unmarkDisputed(escrowId) {} catch {}

        emit DisputeCancelled(disputeId, escrowId, caller, fee);
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

        // Panel hardening (2026-10-20): a judge may not decide a dispute until
        // it has capital at stake in it. The bond is held for the challenge
        // window and is forfeited if a review panel overturns the verdict.
        if (seatBonds[disputeId][caller] == 0) {
            revert SeatBondMissing(disputeId, caller);
        }

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
    //              PANEL HARDENING (2026-10-20): BONDS + REVIEW
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Bond a seated judge must post for this dispute
     * @dev 1x the disputed amount (SEAT_BOND_BPS = 10,000). Two colluding
     *      judges therefore put two dollars at risk for every dollar they can
     *      redirect.
     * @param disputeId Dispute identifier
     * @return Bond in XOM
     */
    function seatBondFor(uint256 disputeId) public view returns (uint256) {
        return (disputes[disputeId].disputedAmount * SEAT_BOND_BPS) / BPS;
    }

    /**
     * @notice Post the seat bond for a dispute you were selected to judge
     * @dev Without it {castVote} refuses. Held through the challenge window and
     *      returned in full unless a review panel overturns the verdict.
     * @param disputeId Dispute identifier
     */
    function postSeatBond(uint256 disputeId) external nonReentrant whenNotPaused {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Active) revert InvalidDisputeStatus();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > d.deadline) revert DeadlineExpired();

        address caller = _msgSender();
        bool seated = false;
        for (uint256 i = 0; i < 3; ++i) {
            if (d.arbitrators[i] == caller) {
                seated = true;
                break;
            }
        }
        if (!seated) revert NotSeatedJudge(disputeId, caller);
        if (seatBonds[disputeId][caller] != 0) {
            revert SeatBondAlreadyPosted(disputeId, caller);
        }

        uint256 bond = seatBondFor(disputeId);
        if (bond == 0) revert DisputedAmountTooSmall();

        seatBonds[disputeId][caller] = bond;
        seatBondCount[disputeId] += 1;
        lockedBond[caller] += bond;
        xomToken.safeTransferFrom(caller, address(this), bond);

        emit SeatBondPosted(disputeId, caller, bond);
    }

    /**
     * @notice Return every seat bond once the challenge window has closed clean
     * @dev Permissionless: a judge should never depend on a party to get their
     *      capital back. Refuses while a review is open — that path decides the
     *      bonds itself.
     * @param disputeId Dispute identifier
     */
    function unlockBonds(uint256 disputeId) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        uint256 deadline = challengeDeadline[disputeId];
        if (deadline == 0) revert NoVerdict(disputeId);
        if (escalated[disputeId]) revert EscalationAlreadyOpened(disputeId);
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < deadline) revert ChallengeWindowOpen(deadline);
        _releaseBonds(disputeId, d);
    }

    /**
     * @notice Read the review panel seated for a dispute
     * @param disputeId Dispute identifier
     * @return panel Three review judges (zero addresses when no review is open)
     */
    function getEscalationPanel(
        uint256 disputeId
    ) external view returns (address[3] memory panel) {
        return escalationPanel[disputeId];
    }

    /**
     * @notice Demand a review of a verdict by a panel that did not decide it
     * @dev Either party may open it inside the challenge window by posting a
     *      bond (10% of the dispute, floor 1,000 XOM). The review panel is
     *      drawn from judges who were NOT on the original panel, so a captured
     *      majority cannot review itself. The escrow payout is never reversed:
     *      an overturn pays the harmed party out of the colluding judges'
     *      bonds, which is what makes the seat bond a real deterrent.
     * @param disputeId Dispute identifier
     */
    function escalate(uint256 disputeId) external nonReentrant whenNotPaused {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Resolved) {
            revert NoVerdict(disputeId);
        }
        uint256 deadline = challengeDeadline[disputeId];
        // solhint-disable-next-line not-rely-on-time
        if (deadline == 0 || block.timestamp >= deadline) {
            revert ChallengeWindowClosed(deadline);
        }
        if (escalated[disputeId]) revert EscalationAlreadyOpened(disputeId);

        address caller = _msgSender();
        // Only the party HARMED by the verdict may demand a review. Letting the
        // winner escalate gave it a free option on the judges' bonds
        // (audit H-01).
        bool originalRelease = d.releaseVotes > d.refundVotes;
        address harmed = originalRelease ? d.buyer : d.seller;
        if (caller != harmed) revert NotChallengeParty();

        address[3] memory panel = _selectReviewPanel(disputeId, d);

        uint256 bond = (d.disputedAmount * ESCALATION_BOND_BPS) / BPS;
        if (bond < MIN_ESCALATION_BOND) bond = MIN_ESCALATION_BOND;

        escalated[disputeId] = true;
        escalationPanel[disputeId] = panel;
        reviewChallenger[disputeId] = caller;
        escalationBond[disputeId] = bond;
        lockedBond[caller] += bond;
        // The review gets its own window (audit C-02): tying it to the
        // challenge deadline let a challenger open a review one block before
        // the deadline and strand every bond forever.
        // solhint-disable-next-line not-rely-on-time
        reviewDeadline[disputeId] = block.timestamp + REVIEW_WINDOW;
        // Reviewers are locked like the panel so they cannot withdraw and
        // vanish mid-review (audit M-05).
        for (uint256 i = 0; i < 3; ++i) {
            if (panel[i] != address(0)) ++activeDisputeCount[panel[i]];
        }
        xomToken.safeTransferFrom(caller, address(this), bond);

        emit ReviewOpened(disputeId, caller, bond, panel);
    }

    /**
     * @notice Close a review that produced no decision, returning every bond
     * @dev Permissionless after the review deadline. A review that stalls must
     *      not strand the panel's capital: an undecided review is treated as
     *      "no forfeiture", the challenger gets the review bond back, and the
     *      seat bonds are released (audit C-02).
     * @param disputeId Dispute identifier
     */
    function lapseReview(uint256 disputeId) external nonReentrant {
        if (!escalated[disputeId]) revert NoVerdict(disputeId);
        uint256 deadline = reviewDeadline[disputeId];
        // solhint-disable-next-line not-rely-on-time
        if (deadline != 0 && block.timestamp < deadline) {
            revert ChallengeWindowOpen(deadline);
        }
        Dispute storage d = disputes[disputeId];

        address[3] memory panel = escalationPanel[disputeId];
        for (uint256 i = 0; i < 3; ++i) {
            if (panel[i] != address(0)) --activeDisputeCount[panel[i]];
        }
        uint256 bond = escalationBond[disputeId];
        if (bond > 0) {
            escalationBond[disputeId] = 0;
            address challenger = reviewChallenger[disputeId];
            lockedBond[challenger] -= bond;
            // A review that never reaches a decision is a failed challenge:
            // the challenger loses the bond (to the vault) and the panel keeps
            // theirs. Refunding it made "open a review and stall" the cheapest
            // way to freeze three judges' capital (red-team, 2026-10-20).
            xomToken.safeTransfer(feeVault, bond);
        }
        // Mark the review closed without a decision; `escalated` stays true so
        // no second review can be opened, but the window fields are cleared.
        reviewDeadline[disputeId] = 0;
        challengeDeadline[disputeId] = 0;
        _releaseBonds(disputeId, d);
        emit ReviewLapsed(disputeId);
    }

    /**
     * @notice Cast a review vote
     * @dev Two matching votes decide. Upholding the verdict pays the review
     *      bond to the majority that was challenged; overturning it pays the
     *      challenger out of the challenged majority's seat bonds.
     * @param disputeId Dispute identifier
     * @param release True to release to the seller, false to refund the buyer
     */
    function castReviewVote(
        uint256 disputeId,
        bool release
    ) external nonReentrant whenNotPaused {
        if (!escalated[disputeId]) revert NoVerdict(disputeId);
        uint256 deadline = reviewDeadline[disputeId];
        // solhint-disable-next-line not-rely-on-time
        if (deadline == 0 || block.timestamp >= deadline) {
            revert ChallengeWindowClosed(deadline);
        }

        address caller = _msgSender();
        address[3] memory panel = escalationPanel[disputeId];
        bool seated = false;
        for (uint256 i = 0; i < 3; ++i) {
            if (panel[i] == caller) {
                seated = true;
                break;
            }
        }
        if (!seated) revert NotSeatedJudge(disputeId, caller);
        if (reviewVotes[disputeId][caller] != VoteType.None) {
            revert AlreadyVoted();
        }

        VoteType vote = release ? VoteType.Release : VoteType.Refund;
        reviewVotes[disputeId][caller] = vote;
        if (release) {
            ++escalationReleaseVotes[disputeId];
        } else {
            ++escalationRefundVotes[disputeId];
        }
        emit ReviewVoteCast(disputeId, caller, vote);

        if (
            escalationReleaseVotes[disputeId] >= 2 ||
            escalationRefundVotes[disputeId] >= 2
        ) {
            _decideReview(
                disputeId,
                escalationReleaseVotes[disputeId] >= 2
            );
        }
    }


    /**
     * @dev Seat three judges who were not on the original panel and are not
     *      parties. Deterministic like the first selection, salted by the
     *      review, and bounded by MAX_ARBITRATOR_SEARCH.
     */
    function _selectReviewPanel(
        uint256 disputeId,
        Dispute storage d
    ) private view returns (address[3] memory panel) {
        address[3] memory original = d.arbitrators;
        uint256 poolSize = arbitratorPool.length;
        uint256 found = 0;
        uint256 seatable = 0;
        uint256 scan = poolSize < SEATING_SCAN_LIMIT ? poolSize : SEATING_SCAN_LIMIT;
        for (uint256 i = 0; i < scan; ++i) {
            address c = arbitratorPool[i];
            if (c == d.buyer || c == d.seller) continue;
            if (c == original[0] || c == original[1] || c == original[2]) continue;
            if (!canBeArbitrator(c)) continue;
            ++seatable;
        }
        if (seatable < 3) revert EscalationNotSeatable(seatable);

        // Entropy from the PREVIOUS block: the challenger cannot compute this
        // panel before submitting, so escalation is not a free option on a
        // chosen panel (audit H-01).
        bytes32 entropy = blockhash(block.number - 1);
        uint256 nonce = 0;
        while (found < 3 && nonce < MAX_ARBITRATOR_SEARCH) {
            bytes32 h = keccak256(abi.encodePacked(disputeId, nonce, entropy, "review"));
            address candidate = arbitratorPool[uint256(h) % poolSize];
            ++nonce;

            if (candidate == d.buyer || candidate == d.seller) continue;
            if (candidate == original[0] || candidate == original[1] || candidate == original[2]) continue;
            if (!canBeArbitrator(candidate)) continue;

            bool duplicate = false;
            for (uint256 j = 0; j < found; ++j) {
                if (panel[j] == candidate) duplicate = true;
            }
            if (duplicate) continue;

            panel[found] = candidate;
            ++found;
        }
        if (found < 3) revert EscalationNotSeatable(found);
    }

    /**
     * @dev Settle a review: uphold pays the challenger's bond to the majority
     *      that was challenged; overturn pays the challenger out of the
     *      challenged majority's seat bonds. Either way every remaining bond is
     *      released to its owner and the lock is cleared.
     */
    function _decideReview(uint256 disputeId, bool reviewRelease) private {
        Dispute storage d = disputes[disputeId];
        bool originalRelease = d.releaseVotes > d.refundVotes;
        bool overturned = reviewRelease != originalRelease;
        uint256 forfeited = 0;
        uint256 bond = escalationBond[disputeId];

        // The challenged majority: judges who voted with the original verdict.
        address[3] memory original = d.arbitrators;
        for (uint256 i = 0; i < 3; ++i) {
            address judge = original[i];
            if (judge == address(0)) continue;
            VoteType v = votes[disputeId][judge];
            bool majority =
                (originalRelease && v == VoteType.Release) ||
                (!originalRelease && v == VoteType.Refund);
            uint256 held = seatBonds[disputeId][judge];
            if (held == 0) continue;

            if (overturned && majority) {
                // Forfeit to the challenger, but never pay more than the loss:
                // paying 2x the dispute turned a review into a lottery on the
                // judges' capital (red-team, 2026-10-20).
                uint256 payableAmount = held;
                uint256 cap = d.disputedAmount;
                if (forfeited + payableAmount > cap) {
                    payableAmount = cap > forfeited ? cap - forfeited : 0;
                }
                seatBonds[disputeId][judge] = 0;
                lockedBond[judge] -= held;
                forfeited += payableAmount;
                if (payableAmount > 0) {
                    xomToken.safeTransfer(_challenger(disputeId), payableAmount);
                }
                if (held > payableAmount) {
                    xomToken.safeTransfer(feeVault, held - payableAmount);
                }
            } else {
                seatBonds[disputeId][judge] = 0;
                lockedBond[judge] -= held;
                xomToken.safeTransfer(judge, held);
            }
        }

        if (bond > 0) {
            address challenger = _challenger(disputeId);
            lockedBond[challenger] -= bond;
            // Reviewers are paid for deciding (25% of the review bond each to
            // the two who voted); without a fee no one has a reason to make q
            // greater than zero, and the review is theatre.
            uint256 paid = 0;
            address[3] memory reviewers = escalationPanel[disputeId];
            for (uint256 i = 0; i < 3; ++i) {
                address reviewer = reviewers[i];
                if (reviewer == address(0)) continue;
                if (reviewVotes[disputeId][reviewer] == VoteType.None) continue;
                uint256 share = bond / 4;
                if (share > 0) {
                    xomToken.safeTransfer(reviewer, share);
                    paid += share;
                }
            }
            if (!overturned) {
                // Upheld: the rest of the challenger's bond goes to the vault —
                // a meritless challenge must cost the challenger something.
                if (bond > paid) xomToken.safeTransfer(feeVault, bond - paid);
            } else if (bond > paid) {
                // Overturned: the challenger keeps the unspent remainder.
                xomToken.safeTransfer(challenger, bond - paid);
            }
        }

        address[3] memory reviewers = escalationPanel[disputeId];
        for (uint256 i = 0; i < 3; ++i) {
            if (reviewers[i] != address(0)) --activeDisputeCount[reviewers[i]];
        }
        reviewDeadline[disputeId] = 0;
        challengeDeadline[disputeId] = 0;
        emit ReviewDecided(disputeId, overturned, forfeited);
    }

    /// @dev The party that opened the review.
    function _challenger(uint256 disputeId) private view returns (address) {
        return reviewChallenger[disputeId];
    }

    /// @dev Release every remaining seat bond for a dispute.
    function _releaseBonds(uint256 disputeId, Dispute storage d) private {
        address[3] memory panel = d.arbitrators;
        for (uint256 i = 0; i < 3; ++i) {
            address judge = panel[i];
            if (judge == address(0)) continue;
            uint256 held = seatBonds[disputeId][judge];
            if (held == 0) continue;
            seatBonds[disputeId][judge] = 0;
            lockedBond[judge] -= held;
            xomToken.safeTransfer(judge, held);
        }
        seatBondCount[disputeId] = 0;
        challengeDeadline[disputeId] = 0;
        emit BondsUnlocked(disputeId);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       TIMEOUT RESOLUTION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Close a dispute that produced no verdict — never by picking a winner
     * @dev Replaces "default = refund the buyer", which paid one party for
     *      stalling and paid every judge for not reading.
     *
     *      Round 1: one fresh panel (new selection block, bonds returned to the
     *      panel that did not decide). Round 2: the status quo — the dispute
     *      fee is refunded to whoever paid it, the escrow's disputed flag is
     *      cleared where the escrow supports it, and the parties fall back on
     *      the escrow's own exits, which decide on delivery evidence instead of
     *      on who waited longer.
     *
     *      Permissionless after the deadline.
     * @param disputeId Dispute identifier
     */
    function triggerDefaultResolution(
        uint256 disputeId
    ) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (
            d.status == DisputeStatus.Resolved ||
            d.status == DisputeStatus.DefaultResolved
        ) {
            revert DisputeAlreadyResolved(disputeId);
        }
        if (d.status == DisputeStatus.PendingSelection) {
            revert SelectionNotFinalized(disputeId);
        }
        if (d.status != DisputeStatus.Active) {
            revert DisputeAlreadyResolved(disputeId);
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < d.deadline) {
            revert DeadlineNotReached(d.deadline);
        }

        // A 2-vote majority resolves in castVote; reaching here means none.
        if (d.releaseVotes >= 2 || d.refundVotes >= 2) {
            revert DisputeAlreadyResolved(disputeId);
        }

        // Round 1 → seat one fresh panel with a new selection block.
        if (!reselected[disputeId]) {
            reselected[disputeId] = true;
            for (uint256 i = 0; i < 3; ++i) {
                address judge = d.arbitrators[i];
                if (judge == address(0)) continue;
                // No verdict was reached, so no bond is forfeited — but the
                // bond MUST be returned before the panel is zeroed. Zeroing
                // first destroyed the only record of who held it, which froze
                // the bond and the judge's stake forever (audit C-01).
                uint256 held = seatBonds[disputeId][judge];
                if (held != 0) {
                    seatBonds[disputeId][judge] = 0;
                    lockedBond[judge] -= held;
                    xomToken.safeTransfer(judge, held);
                }
                // Clear the round-1 vote record too (audit H-02): a reseated
                // judge must be able to vote in round 2, and a stale vote must
                // not count as participation in the deciding round.
                delete votes[disputeId][judge];
                --activeDisputeCount[judge];
                d.arbitrators[i] = address(0);
            }
            seatBondCount[disputeId] = 0;
            d.releaseVotes = 0;
            d.refundVotes = 0;
            d.deadline = 0;
            d.selectionBlock = block.number;
            d.status = DisputeStatus.PendingSelection;
            emit ArbitratorReselectionScheduled(disputeId, block.number);
            return;
        }

        // Round 2 → status quo. No winner, no fee kept.
        d.status = DisputeStatus.Cancelled;
        for (uint256 i = 0; i < 3; ++i) {
            address judge = d.arbitrators[i];
            if (judge == address(0)) continue;
            --activeDisputeCount[judge];
        }
        uint256 refunded = d.disputeFee;
        d.disputeFee = 0;
        if (refunded > 0 && d.feePayer != address(0)) {
            xomToken.safeTransfer(d.feePayer, refunded);
        }
        // Only forget the escrow↔dispute link if the escrow actually cleared
        // its disputed flag. Otherwise a new dispute could be opened against an
        // escrow that is still frozen, and the old link is the only record
        // (audit M-01).
        if (_tryUnmarkDisputed(d.escrowId)) {
            delete escrowToDisputeId[d.escrowId];
        }
        _releaseBonds(disputeId, d);

        emit DisputeReturnedToStatusQuo(disputeId, refunded);
    }

    /**
     * @dev Ask the escrow to clear its disputed flag, without letting an escrow
     *      that predates {unmarkDisputed} block the cancel. The old
     *      MinimalEscrow has no such function; its escrow stays frozen until
     *      its own exits apply, which is recorded in the event trail rather
     *      than reverting the whole call.
     */
    function _tryUnmarkDisputed(uint256 escrowId) private returns (bool ok) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, ) = address(escrow).call(
            abi.encodeWithSignature("unmarkDisputed(uint256)", escrowId)
        );
        if (!ok) {
            emit EscrowUnmarkFailed(escrowId);
        }
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

        // Bonds stay locked for CHALLENGE_WINDOW: a verdict is final in the
        // escrow, but the judges' capital is still at risk to the party that
        // ends up harmed. No reversal, so the escrow keeps its one-way
        // resolution guarantee.
        // solhint-disable-next-line not-rely-on-time
        challengeDeadline[disputeId] = block.timestamp + CHALLENGE_WINDOW;

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

        // Pay ONLY the judges who voted (2026-10-20). Paying an absent judge
        // pays for absence, and absence is the cheapest way to stall a panel.
        // A non-voter's share stays in the vault.
        uint256 perArb = (fee * PER_ARBITRATOR_FEE_SHARE) / BPS;
        uint256 arbitratorsTotal = 0;
        for (uint256 i = 0; i < 3; ++i) {
            address judge = d.arbitrators[i];
            if (judge == address(0)) continue;
            if (votes[disputeId][judge] == VoteType.None) continue;
            if (perArb > 0) {
                xomToken.safeTransfer(judge, perArb);
                arbitratorsTotal += perArb;
            }
        }
        uint256 vaultAmount = fee - arbitratorsTotal;

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
                canBeArbitrator(candidate)
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
