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

/// @notice Dispute already appealed
error AlreadyAppealed(uint256 disputeId);

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

/// @notice Dispute or appeal deadline has passed
error DeadlineExpired();

/// @notice Dispute deadline has not yet passed (for default resolution)
error DeadlineNotReached(uint256 deadline);

/// @notice Evidence submission period closed
error EvidencePeriodClosed();

/// @notice Appeal stake insufficient
error InsufficientAppealStake(
    uint256 provided,
    uint256 required
);

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

/// @notice Upgrade timelock not yet elapsed
/// @param scheduledAt When the upgrade was scheduled
/// @param availableAt When the upgrade becomes available
error UpgradeTimelockActive(
    uint256 scheduledAt,
    uint256 availableAt
);

/// @notice No upgrade is currently pending
error NoUpgradePending();

/// @notice Pending upgrade does not match the provided implementation
/// @param expected The scheduled implementation address
/// @param provided The provided implementation address
error UpgradeImplementationMismatch(
    address expected,
    address provided
);

/**
 * @title OmniArbitration
 * @author OmniBazaar Team
 * @notice Trustless arbitration system for OmniBazaar marketplace
 *         disputes
 *
 * @dev Provides two-phase arbitrator selection, 3-arbitrator panels,
 *      evidence registration via IPFS CIDs, appeals to 5-member
 *      panels, fee collection/distribution, escrow fund movement,
 *      and timeout protection with default resolution.
 *
 * Architecture:
 * - Arbitrators qualify via OmniParticipation (score >= 50, KYC 4)
 * - Two-phase commit: createDispute stores selectionBlock, then
 *   finalizeArbitratorSelection uses blockhash(selectionBlock) 2+
 *   blocks later to prevent the creator from predicting the panel
 * - 3-arbitrator panel with 2-of-3 majority for initial disputes
 * - Appeal escalates to 5-arbitrator panel with 3-of-5 majority
 * - Evidence CIDs recorded on-chain (immutable once submitted)
 * - 7-day deadline; default refund to buyer on timeout
 * - Fee: 5% of disputed amount collected at dispute creation
 *   (70% arbitrators, 20% validator, 10% ODDAO)
 * - UUPS upgrades subject to 48-hour timelock
 *
 * Security:
 * - UUPS upgradeable with timelock, Pausable, ReentrancyGuard
 * - Two-phase selection prevents creator from knowing the panel
 * - One dispute per escrow prevents panel shopping
 * - Active-dispute guard prevents arbitrator stake withdrawal
 * - Slashing for overturned decisions on appeal
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
    PausableUpgradeable
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
    enum DisputeStatus {
        Active,
        Resolved,
        Appealed,
        DefaultResolved,
        PendingSelection
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
        bool appealed;
        bytes32[] evidenceCIDs;
        uint256 disputeFee;
        uint256 selectionBlock;
    }

    /// @notice Appeal record
    struct Appeal {
        uint256 disputeId;
        address[5] arbitrators;
        uint8 releaseVotes;
        uint8 refundVotes;
        uint256 deadline;
        uint256 appealStake;
        address appellant;
        bool resolved;
    }

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Role for dispute management
    bytes32 public constant DISPUTE_ADMIN_ROLE =
        keccak256("DISPUTE_ADMIN_ROLE");

    /// @notice Default dispute deadline (7 days)
    uint256 public constant DEFAULT_DEADLINE = 7 days;

    /// @notice Appeal deadline (5 days)
    uint256 public constant APPEAL_DEADLINE = 5 days;

    /// @notice Arbitration fee in basis points (500 = 5%)
    uint256 public constant ARBITRATION_FEE_BPS = 500;

    /// @notice Fee split: arbitrators (7000 = 70%)
    uint256 public constant ARBITRATOR_FEE_SHARE = 7000;

    /// @notice Fee split: validator (2000 = 20%)
    uint256 public constant VALIDATOR_FEE_SHARE = 2000;

    /// @notice Fee split: ODDAO (1000 = 10%)
    uint256 public constant ODDAO_FEE_SHARE = 1000;

    /// @notice Basis points denominator
    uint256 private constant BPS = 10_000;

    /// @notice Maximum evidence items per dispute
    uint256 public constant MAX_EVIDENCE = 50;

    /// @notice Maximum registered arbitrators to iterate
    uint256 private constant MAX_ARBITRATOR_SEARCH = 200;

    /// @notice Timelock delay for UUPS upgrades (48 hours)
    uint256 public constant UPGRADE_DELAY = 48 hours;

    /// @notice Minimum allowed arbitrator stake (100 XOM)
    uint256 public constant MIN_STAKE_LOWER_BOUND = 100 ether;

    /// @notice Maximum allowed arbitrator stake (10,000,000 XOM)
    uint256 public constant MIN_STAKE_UPPER_BOUND =
        10_000_000 ether;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice OmniParticipation contract
    IArbitrationParticipation public participation;

    /// @notice Escrow contract
    IArbitrationEscrow public escrow;

    /// @notice XOM token for fees and stakes
    IERC20 public xomToken;

    /// @notice ODDAO treasury address
    address public oddaoTreasury;

    /// @notice Dispute counter
    uint256 public nextDisputeId;

    /// @notice All disputes
    mapping(uint256 => Dispute) public disputes;

    /// @notice All appeals
    mapping(uint256 => Appeal) public appeals;

    /// @notice Vote record per dispute per arbitrator
    mapping(uint256 => mapping(address => VoteType)) public votes;

    /// @notice Appeal vote record
    mapping(uint256 => mapping(address => VoteType))
        public appealVotes;

    /// @notice Arbitrator stake balances
    mapping(address => uint256) public arbitratorStakes;

    /// @notice Minimum arbitrator stake (10,000 XOM)
    uint256 public minArbitratorStake;

    /// @notice Appeal stake multiplier in bps (5000 = 50% of fee)
    uint256 public appealStakeMultiplier;

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

    /// @notice Pending implementation address for timelocked upgrade
    /// @dev H-04: UUPS upgrade timelock
    address public pendingImplementation;

    /// @notice Timestamp when an upgrade was scheduled
    /// @dev H-04: Must wait UPGRADE_DELAY after scheduling
    uint256 public upgradeScheduledAt;

    /// @notice Index of each arbitrator in the arbitratorPool array
    /// @dev M-03: Enables O(1) swap-and-pop removal from pool
    mapping(address => uint256) public arbitratorPoolIndex;

    /// @notice Reserved storage gap for future upgradeable variables
    /// @dev 50 - 5 new state variables = 45 slots reserved
    uint256[45] private __gap;

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

    /// @notice Emitted when an appeal is filed
    /// @param disputeId Dispute ID being appealed
    /// @param appellant Address filing the appeal
    /// @param arbitrators Selected 5-member appeal panel
    /// @param appealStake XOM staked by appellant
    /// @param deadline Appeal resolution deadline
    event AppealFiled(
        uint256 indexed disputeId,
        address indexed appellant,
        address[5] arbitrators,
        uint256 appealStake,
        uint256 deadline
    );

    /// @notice Emitted when an appeal is resolved
    /// @param disputeId Dispute ID
    /// @param outcome Final vote outcome
    /// @param originalOverturned True if appeal reversed original
    event AppealResolved(
        uint256 indexed disputeId,
        VoteType outcome,
        bool originalOverturned
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
    /// @param validatorShare Amount sent to resolving validator
    /// @param oddaoShare Amount sent to ODDAO treasury
    event FeesDistributed(
        uint256 indexed disputeId,
        uint256 arbitratorShare,
        uint256 validatorShare,
        uint256 oddaoShare
    );

    /// @notice Emitted when escrow resolution call fails
    /// @param escrowId Escrow ID that failed resolution
    /// @param reason Revert reason string
    event ResolutionCallFailed(
        uint256 indexed escrowId,
        string reason
    );

    /// @notice Emitted when contract references are updated
    /// @param participation New participation contract address
    /// @param escrowAddr New escrow contract address
    event ContractsUpdated(
        address indexed participation,
        address indexed escrowAddr
    );

    /// @notice Emitted when a UUPS upgrade is scheduled
    /// @param implementation New implementation address
    /// @param scheduledAt Timestamp when scheduled
    /// @param availableAt Timestamp when upgrade can execute
    event UpgradeScheduled(
        address indexed implementation,
        uint256 scheduledAt,
        uint256 availableAt
    );

    /// @notice Emitted when a pending UUPS upgrade is cancelled
    /// @param implementation Cancelled implementation address
    event UpgradeCancelled(address indexed implementation);

    /// @notice Emitted when ODDAO treasury address is updated
    /// @param oldTreasury Previous treasury address
    /// @param newTreasury New treasury address
    event OddaoTreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted when minimum arbitrator stake is updated
    /// @param oldStake Previous minimum stake
    /// @param newStake New minimum stake
    event MinStakeUpdated(
        uint256 oldStake,
        uint256 newStake
    );

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the arbitration contract
     * @dev Sets up roles, contract references, and default parameters.
     *      All four addresses must be non-zero.
     * @param _participation OmniParticipation contract address
     * @param _escrow MinimalEscrow contract address
     * @param _xomToken XOM token contract address
     * @param _oddaoTreasury ODDAO treasury address
     */
    function initialize(
        address _participation,
        address _escrow,
        address _xomToken,
        address _oddaoTreasury
    ) external initializer {
        // M-01: Zero-address validation for all parameters
        if (_participation == address(0)) revert ZeroAddress();
        if (_escrow == address(0)) revert ZeroAddress();
        if (_xomToken == address(0)) revert ZeroAddress();
        if (_oddaoTreasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISPUTE_ADMIN_ROLE, msg.sender);

        participation = IArbitrationParticipation(_participation);
        escrow = IArbitrationEscrow(_escrow);
        xomToken = IERC20(_xomToken);
        oddaoTreasury = _oddaoTreasury;

        nextDisputeId = 1;
        minArbitratorStake = 10_000 ether; // 10,000 XOM
        appealStakeMultiplier = 5000; // 50% of dispute fee
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
        if (!participation.canBeValidator(msg.sender)) {
            revert NotQualifiedArbitrator();
        }
        if (amount < minArbitratorStake) {
            revert InsufficientArbitratorStake(
                amount,
                minArbitratorStake
            );
        }

        xomToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        arbitratorStakes[msg.sender] += amount;

        if (!isInArbitratorPool[msg.sender]) {
            isInArbitratorPool[msg.sender] = true;
            arbitratorPoolIndex[msg.sender] =
                arbitratorPool.length;
            arbitratorPool.push(msg.sender);
        }

        emit ArbitratorRegistered(msg.sender, amount);
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
        // H-01: Block withdrawal while assigned to active disputes
        if (activeDisputeCount[msg.sender] > 0) {
            revert ArbitratorBusyInDispute();
        }

        if (arbitratorStakes[msg.sender] < amount) {
            revert InsufficientArbitratorStake(
                arbitratorStakes[msg.sender],
                amount
            );
        }

        arbitratorStakes[msg.sender] -= amount;

        // M-03: Remove from pool via swap-and-pop if below minimum
        if (
            arbitratorStakes[msg.sender] < minArbitratorStake &&
            isInArbitratorPool[msg.sender]
        ) {
            _removeFromArbitratorPool(msg.sender);
        }

        xomToken.safeTransfer(msg.sender, amount);

        emit ArbitratorWithdrawn(msg.sender, amount);
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
        // C-03: Prevent duplicate disputes per escrow
        if (escrowToDisputeId[escrowId] != 0) {
            revert EscrowAlreadyDisputed(escrowId);
        }

        address buyer = escrow.getBuyer(escrowId);
        address seller = escrow.getSeller(escrowId);
        uint256 amount = escrow.getAmount(escrowId);

        // Only buyer or seller can dispute
        if (msg.sender != buyer && msg.sender != seller) {
            revert NotEscrowParty();
        }

        // C-01: Calculate and collect dispute fee (5% of amount)
        uint256 fee =
            (amount * ARBITRATION_FEE_BPS) / BPS;
        xomToken.safeTransferFrom(
            msg.sender,
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

        // Must wait at least 2 blocks
        if (block.number < d.selectionBlock + 2) {
            revert SelectionTooEarly(
                block.number,
                d.selectionBlock + 2
            );
        }

        // Select 3 arbitrators using stored block's hash
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

    // ══════════════════════════════════════════════════════════════════
    //                        EVIDENCE SUBMISSION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Submit evidence for a dispute (IPFS CID)
     * @dev Only buyer, seller, or assigned arbitrators can submit.
     *      Evidence is immutable once recorded on-chain.
     *      M-07: During appeal status, appeal arbitrators are also
     *      authorized to submit evidence.
     * @param disputeId Dispute ID
     * @param ipfsCID IPFS content identifier hash
     */
    function submitEvidence(
        uint256 disputeId,
        bytes32 ipfsCID
    ) external whenNotPaused {
        Dispute storage d = disputes[disputeId];
        // M-05: Use createdAt instead of escrowId for existence
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (
            d.status != DisputeStatus.Active &&
            d.status != DisputeStatus.Appealed
        ) {
            revert EvidencePeriodClosed();
        }
        if (d.evidenceCIDs.length >= MAX_EVIDENCE) {
            revert EvidencePeriodClosed();
        }

        // Only parties or assigned arbitrators can submit
        bool authorized = (
            msg.sender == d.buyer ||
            msg.sender == d.seller
        );

        // Check initial panel arbitrators
        if (!authorized) {
            for (uint256 i = 0; i < 3; ++i) {
                if (d.arbitrators[i] == msg.sender) {
                    authorized = true;
                    break;
                }
            }
        }

        // M-07: During appeal, also check appeal arbitrators
        if (
            !authorized &&
            d.status == DisputeStatus.Appealed
        ) {
            Appeal storage a = appeals[disputeId];
            for (uint256 i = 0; i < 5; ++i) {
                if (a.arbitrators[i] == msg.sender) {
                    authorized = true;
                    break;
                }
            }
        }

        if (!authorized) revert NotAssignedArbitrator();

        d.evidenceCIDs.push(ipfsCID);
        evidenceSubmitters[disputeId][ipfsCID] = msg.sender;

        emit EvidenceSubmitted(
            disputeId,
            msg.sender,
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
            if (d.arbitrators[i] == msg.sender) {
                isArbitrator = true;
                break;
            }
        }
        if (!isArbitrator) revert NotAssignedArbitrator();

        // Check not already voted
        if (votes[disputeId][msg.sender] != VoteType.None) {
            revert AlreadyVoted();
        }

        votes[disputeId][msg.sender] = vote;

        if (vote == VoteType.Release) {
            ++d.releaseVotes;
        } else {
            ++d.refundVotes;
        }

        emit VoteCast(disputeId, msg.sender, vote);

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
    //                            APPEALS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice File an appeal on a resolved dispute
     * @dev Appellant stakes XOM (returned if appeal succeeds,
     *      forfeited to ODDAO if appeal fails).
     *      Escalates to 5-arbitrator panel with 3-of-5 majority.
     * @param disputeId Dispute ID to appeal
     */
    function fileAppeal(
        uint256 disputeId
    ) external nonReentrant whenNotPaused {
        Dispute storage d = disputes[disputeId];
        // M-05: Use createdAt for existence check
        if (d.createdAt == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Resolved) {
            revert DisputeAlreadyResolved(disputeId);
        }
        if (d.appealed) revert AlreadyAppealed(disputeId);

        // Only buyer or seller can appeal
        if (msg.sender != d.buyer && msg.sender != d.seller) {
            revert NotEscrowParty();
        }

        // Calculate appeal stake (50% of arbitration fee)
        uint256 fee =
            (d.disputedAmount * ARBITRATION_FEE_BPS) / BPS;
        uint256 appealStake =
            (fee * appealStakeMultiplier) / BPS;

        // Transfer appeal stake
        xomToken.safeTransferFrom(
            msg.sender,
            address(this),
            appealStake
        );

        // Select 5 new arbitrators (excluding original 3)
        address[5] memory appealArbitrators =
            _selectAppealArbitrators(
                disputeId,
                d.arbitrators
            );

        // solhint-disable-next-line not-rely-on-time
        uint256 deadline = block.timestamp + APPEAL_DEADLINE;

        appeals[disputeId] = Appeal({
            disputeId: disputeId,
            arbitrators: appealArbitrators,
            releaseVotes: 0,
            refundVotes: 0,
            deadline: deadline,
            appealStake: appealStake,
            appellant: msg.sender,
            resolved: false
        });

        d.status = DisputeStatus.Appealed;
        d.appealed = true;

        // H-01: Increment active dispute count for appeal arbs
        for (uint256 i = 0; i < 5; ++i) {
            ++activeDisputeCount[appealArbitrators[i]];
        }

        emit AppealFiled(
            disputeId,
            msg.sender,
            appealArbitrators,
            appealStake,
            deadline
        );
    }

    /**
     * @notice Cast a vote on an appeal
     * @dev 3-of-5 majority resolves the appeal.
     *      H-03: Enforces appeal deadline.
     *      H-05: Forfeited appeal stake goes to ODDAO treasury.
     *      C-01/C-02: Distributes fees and triggers escrow on
     *      resolution.
     * @param disputeId Dispute ID
     * @param vote Release or Refund
     */
    function castAppealVote(
        uint256 disputeId,
        VoteType vote
    ) external nonReentrant whenNotPaused {
        if (vote == VoteType.None) revert InvalidVoteType();

        Appeal storage a = appeals[disputeId];
        if (a.disputeId == 0) revert DisputeNotFound(disputeId);
        if (a.resolved) revert DisputeAlreadyResolved(disputeId);

        // H-03: Enforce appeal voting deadline
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > a.deadline) {
            revert DeadlineExpired();
        }

        // Verify assigned appeal arbitrator
        bool isArbitrator = false;
        for (uint256 i = 0; i < 5; ++i) {
            if (a.arbitrators[i] == msg.sender) {
                isArbitrator = true;
                break;
            }
        }
        if (!isArbitrator) revert NotAssignedArbitrator();

        if (
            appealVotes[disputeId][msg.sender] != VoteType.None
        ) {
            revert AlreadyVoted();
        }

        appealVotes[disputeId][msg.sender] = vote;

        if (vote == VoteType.Release) {
            ++a.releaseVotes;
        } else {
            ++a.refundVotes;
        }

        emit VoteCast(disputeId, msg.sender, vote);

        // Check for 3-of-5 majority
        if (a.releaseVotes >= 3 || a.refundVotes >= 3) {
            a.resolved = true;

            VoteType outcome = a.releaseVotes >= 3
                ? VoteType.Release
                : VoteType.Refund;

            // Determine if original decision was overturned
            Dispute storage d = disputes[disputeId];
            VoteType originalOutcome = d.releaseVotes >= 2
                ? VoteType.Release
                : VoteType.Refund;
            bool overturned = outcome != originalOutcome;

            bool isRelease = (outcome == VoteType.Release);

            d.status = DisputeStatus.Resolved;

            // H-05: Handle appeal stake
            if (overturned) {
                // Appeal succeeded - return stake to appellant
                xomToken.safeTransfer(
                    a.appellant,
                    a.appealStake
                );
            } else {
                // Appeal failed - forfeit stake to ODDAO
                xomToken.safeTransfer(
                    oddaoTreasury,
                    a.appealStake
                );
            }

            // H-01: Decrement active dispute count for appeal
            // arbitrators only (original panel was already
            // decremented during _resolveDispute before appeal)
            for (uint256 i = 0; i < 5; ++i) {
                --activeDisputeCount[a.arbitrators[i]];
            }

            // C-01: Distribute collected fees
            _collectAndDistributeFee(disputeId);

            // C-02: Trigger escrow fund movement
            _triggerEscrowResolution(
                d.escrowId,
                isRelease
            );

            emit AppealResolved(
                disputeId,
                outcome,
                overturned
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

        emit DisputeDefaultResolved(disputeId, msg.sender);
        emit DisputeResolved(
            disputeId,
            VoteType.Refund,
            d.releaseVotes,
            d.refundVotes
        );
    }

    /**
     * @notice Trigger default appeal resolution after deadline
     * @dev H-03: If the appeal deadline passes without 3-of-5
     *      majority, the original decision is upheld. The appeal
     *      stake is forfeited to ODDAO.
     * @param disputeId Dispute ID with an expired appeal
     */
    function triggerDefaultAppealResolution(
        uint256 disputeId
    ) external nonReentrant {
        Appeal storage a = appeals[disputeId];
        if (a.disputeId == 0) revert DisputeNotFound(disputeId);
        if (a.resolved) revert DisputeAlreadyResolved(disputeId);

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < a.deadline) {
            revert DeadlineNotReached(a.deadline);
        }

        a.resolved = true;

        Dispute storage d = disputes[disputeId];

        // Original decision is upheld
        VoteType originalOutcome = d.releaseVotes >= 2
            ? VoteType.Release
            : VoteType.Refund;
        bool isRelease =
            (originalOutcome == VoteType.Release);

        d.status = DisputeStatus.Resolved;

        // Forfeit appeal stake to ODDAO (appeal failed by timeout)
        xomToken.safeTransfer(oddaoTreasury, a.appealStake);

        // H-01: Decrement active dispute count for appeal
        // arbitrators only (original panel was already
        // decremented during _resolveDispute before appeal)
        for (uint256 i = 0; i < 5; ++i) {
            --activeDisputeCount[a.arbitrators[i]];
        }

        // C-01: Distribute collected fees
        _collectAndDistributeFee(disputeId);

        // C-02: Trigger escrow based on original decision
        _triggerEscrowResolution(d.escrowId, isRelease);

        emit AppealResolved(
            disputeId,
            originalOutcome,
            false
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
     * @return totalFee Total fee
     * @return arbitratorShare Amount to arbitrators (70%)
     * @return validatorShare Amount to validator (20%)
     * @return oddaoShare Amount to ODDAO (10%)
     */
    function calculateFee(
        uint256 amount
    )
        external
        pure
        returns (
            uint256 totalFee,
            uint256 arbitratorShare,
            uint256 validatorShare,
            uint256 oddaoShare
        )
    {
        totalFee = (amount * ARBITRATION_FEE_BPS) / BPS;
        arbitratorShare =
            (totalFee * ARBITRATOR_FEE_SHARE) / BPS;
        validatorShare =
            (totalFee * VALIDATOR_FEE_SHARE) / BPS;
        oddaoShare =
            totalFee - arbitratorShare - validatorShare;
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
     * @notice Update the ODDAO treasury address
     * @dev M-06: Allows admin to update treasury. Validates
     *      non-zero address.
     * @param _oddaoTreasury New ODDAO treasury address
     */
    function setOddaoTreasury(
        address _oddaoTreasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oddaoTreasury == address(0)) revert ZeroAddress();

        address oldTreasury = oddaoTreasury;
        oddaoTreasury = _oddaoTreasury;

        emit OddaoTreasuryUpdated(oldTreasury, _oddaoTreasury);
    }

    /**
     * @notice Schedule a UUPS upgrade with timelock
     * @dev H-04: Upgrade requires a 48-hour delay between
     *      scheduling and execution. Only admin can schedule.
     * @param newImplementation Address of new implementation
     */
    function scheduleUpgrade(
        address newImplementation
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        if (newImplementation.code.length == 0) {
            revert NotAContract(newImplementation);
        }

        pendingImplementation = newImplementation;
        // solhint-disable-next-line not-rely-on-time
        upgradeScheduledAt = block.timestamp;

        emit UpgradeScheduled(
            newImplementation,
            block.timestamp, // solhint-disable-line not-rely-on-time
            block.timestamp + UPGRADE_DELAY // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Cancel a pending UUPS upgrade
     * @dev H-04: Allows admin to cancel a scheduled upgrade before
     *      the timelock elapses.
     */
    function cancelUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingImplementation == address(0)) {
            revert NoUpgradePending();
        }

        address cancelled = pendingImplementation;
        pendingImplementation = address(0);
        upgradeScheduledAt = 0;

        emit UpgradeCancelled(cancelled);
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
     * @dev C-01: Distributes fees. C-02: Triggers escrow fund
     *      movement. H-01: Decrements active dispute counts.
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

        // H-01: Decrement active dispute count for each arbitrator
        for (uint256 i = 0; i < 3; ++i) {
            --activeDisputeCount[d.arbitrators[i]];
        }

        // C-01: Distribute collected fees
        _collectAndDistributeFee(disputeId);

        // C-02: Trigger escrow fund movement
        _triggerEscrowResolution(d.escrowId, isRelease);

        emit DisputeResolved(
            disputeId,
            outcome,
            d.releaseVotes,
            d.refundVotes
        );
    }

    /**
     * @notice Distribute the collected dispute fee per 70/20/10
     *         split
     * @dev C-01: Splits the fee stored in d.disputeFee among
     *      arbitrators (70%), the resolving validator/msg.sender
     *      (20%), and ODDAO treasury (10%). Uses XOM tokens already
     *      held by this contract from dispute creation.
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

        uint256 arbShare =
            (fee * ARBITRATOR_FEE_SHARE) / BPS;
        uint256 valShare =
            (fee * VALIDATOR_FEE_SHARE) / BPS;
        uint256 oddaoShare =
            fee - arbShare - valShare;

        // Distribute arbitrator share equally among panel members
        // Use initial panel (3 arbitrators) for fee split
        uint256 perArb = arbShare / 3;
        uint256 arbRemainder = arbShare - (perArb * 3);

        for (uint256 i = 0; i < 3; ++i) {
            uint256 arbAmount = perArb;
            // Give dust to the first arbitrator
            if (i == 0) {
                arbAmount += arbRemainder;
            }
            if (arbAmount > 0) {
                xomToken.safeTransfer(
                    d.arbitrators[i],
                    arbAmount
                );
            }
        }

        // Validator share goes to the transaction sender
        // (the validator or party that triggered resolution)
        if (valShare > 0) {
            xomToken.safeTransfer(msg.sender, valShare);
        }

        // ODDAO share
        if (oddaoShare > 0) {
            xomToken.safeTransfer(oddaoTreasury, oddaoShare);
        }

        emit FeesDistributed(
            disputeId,
            arbShare,
            valShare,
            oddaoShare
        );
    }

    /**
     * @notice Trigger escrow fund movement on dispute resolution
     * @dev C-02: Calls escrow.resolveDispute() to release or refund
     *      funds. If the call fails, emits ResolutionCallFailed so
     *      an admin can intervene manually.
     * @param escrowId Escrow ID to resolve
     * @param releaseFunds True to release to seller, false to
     *        refund buyer
     */
    function _triggerEscrowResolution(
        uint256 escrowId,
        bool releaseFunds
    ) internal {
        // solhint-disable-next-line no-empty-blocks
        try escrow.resolveDispute(escrowId, releaseFunds) {
            // Success - funds moved
        } catch Error(string memory reason) {
            emit ResolutionCallFailed(escrowId, reason);
        } catch {
            emit ResolutionCallFailed(
                escrowId,
                "Unknown escrow error"
            );
        }
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
                    msg.sender,
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
     * @notice Select 5 arbitrators for appeal (excluding original 3)
     * @param disputeId Dispute ID
     * @param original Original 3 arbitrators to exclude
     * @return selected Array of 5 appeal arbitrators
     */
    function _selectAppealArbitrators(
        uint256 disputeId,
        address[3] memory original
    ) internal view returns (address[5] memory selected) {
        uint256 poolSize = arbitratorPool.length;
        // Need 5 + 3 excluded
        if (poolSize < 8) revert NotEnoughArbitrators();

        Dispute storage d = disputes[disputeId];
        uint256 found = 0;
        uint256 nonce = 0;

        while (found < 5 && nonce < MAX_ARBITRATOR_SEARCH) {
            bytes32 h = keccak256(
                abi.encodePacked(
                    disputeId,
                    blockhash(block.number - 1),
                    block.number,
                    msg.sender,
                    "appeal",
                    nonce
                )
            );
            uint256 idx = uint256(h) % poolSize;
            address candidate = arbitratorPool[idx];

            // Skip parties, original arbs, unqualified, dupes
            bool valid = (
                candidate != d.buyer &&
                candidate != d.seller &&
                arbitratorStakes[candidate] >=
                    minArbitratorStake &&
                participation.canBeValidator(candidate)
            );

            if (valid) {
                // Check not original arbitrator
                for (uint256 k = 0; k < 3; ++k) {
                    if (original[k] == candidate) {
                        valid = false;
                        break;
                    }
                }
            }

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

        if (found < 5) revert NotEnoughArbitrators();
    }

    /**
     * @notice Authorize UUPS upgrades with timelock enforcement
     * @dev H-04: Validates that the upgrade was previously scheduled
     *      via scheduleUpgrade() and the 48-hour timelock has
     *      elapsed. Clears the pending upgrade after authorization.
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingImplementation == address(0)) {
            revert NoUpgradePending();
        }
        if (pendingImplementation != newImplementation) {
            revert UpgradeImplementationMismatch(
                pendingImplementation,
                newImplementation
            );
        }
        // solhint-disable-next-line not-rely-on-time
        if (
            block.timestamp <
            upgradeScheduledAt + UPGRADE_DELAY
        ) {
            revert UpgradeTimelockActive(
                upgradeScheduledAt,
                upgradeScheduledAt + UPGRADE_DELAY
            );
        }

        // Clear pending upgrade
        pendingImplementation = address(0);
        upgradeScheduledAt = 0;
    }
}
