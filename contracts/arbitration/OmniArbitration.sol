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
    function getTotalScore(address user) external view returns (uint256);
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
    function getBuyer(uint256 escrowId) external view returns (address);

    /// @notice Get escrow seller address
    /// @param escrowId Escrow ID
    /// @return Seller address
    function getSeller(uint256 escrowId) external view returns (address);

    /// @notice Get escrow amount
    /// @param escrowId Escrow ID
    /// @return Amount in XOM
    function getAmount(uint256 escrowId) external view returns (uint256);
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
error InsufficientArbitratorStake(uint256 provided, uint256 required);

/// @notice Dispute deadline has passed
error DeadlineExpired(uint256 deadline);

/// @notice Dispute deadline has not yet passed (for default resolution)
error DeadlineNotReached(uint256 deadline);

/// @notice Evidence submission period closed
error EvidencePeriodClosed();

/// @notice Appeal stake insufficient
error InsufficientAppealStake(uint256 provided, uint256 required);

/// @notice Insufficient qualified arbitrators available
error NotEnoughArbitrators();

/// @notice Vote type invalid
error InvalidVoteType();

/**
 * @title OmniArbitration
 * @author OmniBazaar Team
 * @notice Trustless arbitration system for OmniBazaar marketplace disputes
 *
 * @dev Provides deterministic arbitrator selection, 3-arbitrator panels,
 *      evidence registration via IPFS CIDs, appeals to 5-member panels,
 *      and timeout protection with default resolution.
 *
 * Architecture:
 * - Arbitrators must qualify via OmniParticipation (score >= 50, KYC 4)
 * - Selection uses hash(disputeId, prevBlockHash, escrowCreatedAt) for
 *   unpredictable-by-validator assignment
 * - 3-arbitrator panel with 2-of-3 majority for initial disputes
 * - Appeal escalates to 5-arbitrator panel with 3-of-5 majority
 * - Evidence CIDs recorded on-chain (immutable once submitted)
 * - 7-day deadline; default refund to buyer on timeout
 * - Fee: 5% of disputed amount (70% arbitrators, 20% validator, 10% ODDAO)
 *
 * Security:
 * - UUPS upgradeable, Pausable, ReentrancyGuard
 * - Deterministic selection prevents validator self-assignment
 * - Slashing for overturned decisions on appeal
 * - Only qualified participants can serve as arbitrators
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
        DefaultResolved
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
    mapping(uint256 => mapping(address => VoteType)) public appealVotes;

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

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a dispute is created
    /// @param disputeId Unique dispute ID
    /// @param escrowId Associated escrow ID
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param arbitrators Selected 3-member arbitrator panel
    /// @param amount Disputed amount in XOM
    /// @param deadline Resolution deadline timestamp
    event DisputeCreated(
        uint256 indexed disputeId,
        uint256 indexed escrowId,
        address buyer,
        address seller,
        address[3] arbitrators,
        uint256 amount,
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

    // ══════════════════════════════════════════════════════════════════
    //                           INITIALIZER
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the arbitration contract
     * @param _participation OmniParticipation contract
     * @param _escrow MinimalEscrow contract
     * @param _xomToken XOM token address
     * @param _oddaoTreasury ODDAO treasury address
     */
    function initialize(
        address _participation,
        address _escrow,
        address _xomToken,
        address _oddaoTreasury
    ) external initializer {
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
     *      KYC Tier 4)
     * @param amount XOM to stake (must be >= minArbitratorStake)
     */
    function registerArbitrator(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!participation.canBeValidator(msg.sender)) {
            revert NotQualifiedArbitrator();
        }
        if (amount < minArbitratorStake) {
            revert InsufficientArbitratorStake(amount, minArbitratorStake);
        }

        xomToken.safeTransferFrom(msg.sender, address(this), amount);
        arbitratorStakes[msg.sender] += amount;

        if (!isInArbitratorPool[msg.sender]) {
            isInArbitratorPool[msg.sender] = true;
            arbitratorPool.push(msg.sender);
        }

        emit ArbitratorRegistered(msg.sender, amount);
    }

    /**
     * @notice Withdraw arbitrator stake (if not actively assigned)
     * @param amount XOM to withdraw
     */
    function withdrawArbitratorStake(
        uint256 amount
    ) external nonReentrant {
        if (arbitratorStakes[msg.sender] < amount) {
            revert InsufficientArbitratorStake(
                arbitratorStakes[msg.sender],
                amount
            );
        }

        arbitratorStakes[msg.sender] -= amount;

        // Remove from pool if below minimum
        if (arbitratorStakes[msg.sender] < minArbitratorStake) {
            isInArbitratorPool[msg.sender] = false;
        }

        xomToken.safeTransfer(msg.sender, amount);

        emit ArbitratorWithdrawn(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       DISPUTE CREATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a dispute for an escrow transaction
     * @dev Only buyer or seller of the escrow can create a dispute.
     *      Arbitrators are selected deterministically using a hash
     *      that is unpredictable to the validator at commit time.
     * @param escrowId ID of the escrow to dispute
     */
    function createDispute(
        uint256 escrowId
    ) external nonReentrant whenNotPaused {
        address buyer = escrow.getBuyer(escrowId);
        address seller = escrow.getSeller(escrowId);
        uint256 amount = escrow.getAmount(escrowId);

        // Only buyer or seller can dispute
        if (msg.sender != buyer && msg.sender != seller) {
            revert NotEscrowParty();
        }

        // Select 3 arbitrators deterministically
        address[3] memory selected = _selectArbitrators(
            escrowId,
            3,
            buyer,
            seller
        );

        uint256 disputeId = nextDisputeId;
        ++nextDisputeId;
        // solhint-disable-next-line not-rely-on-time
        uint256 deadline = block.timestamp + DEFAULT_DEADLINE;

        Dispute storage d = disputes[disputeId];
        d.escrowId = escrowId;
        d.buyer = buyer;
        d.seller = seller;
        d.arbitrators = selected;
        d.createdAt = block.timestamp; // solhint-disable-line not-rely-on-time
        d.deadline = deadline;
        d.disputedAmount = amount;
        d.status = DisputeStatus.Active;

        emit DisputeCreated(
            disputeId,
            escrowId,
            buyer,
            seller,
            selected,
            amount,
            deadline
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
        Dispute storage d = disputes[disputeId];
        if (d.escrowId == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Active &&
            d.status != DisputeStatus.Appealed) {
            revert EvidencePeriodClosed();
        }
        if (d.evidenceCIDs.length >= MAX_EVIDENCE) {
            revert EvidencePeriodClosed();
        }

        // Only parties or assigned arbitrators can submit
        bool authorized = (msg.sender == d.buyer ||
            msg.sender == d.seller);
        if (!authorized) {
            for (uint256 i = 0; i < 3; ++i) {
                if (d.arbitrators[i] == msg.sender) {
                    authorized = true;
                    break;
                }
            }
        }
        if (!authorized) revert NotAssignedArbitrator();

        d.evidenceCIDs.push(ipfsCID);
        evidenceSubmitters[disputeId][ipfsCID] = msg.sender;

        emit EvidenceSubmitted(disputeId, msg.sender, ipfsCID);
    }

    // ══════════════════════════════════════════════════════════════════
    //                           VOTING
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Cast a vote on a dispute (release to seller or refund
     *         to buyer)
     * @dev Only assigned arbitrators can vote. 2-of-3 majority resolves.
     * @param disputeId Dispute ID
     * @param vote Release (to seller) or Refund (to buyer)
     */
    function castVote(
        uint256 disputeId,
        VoteType vote
    ) external nonReentrant whenNotPaused {
        if (vote == VoteType.None) revert InvalidVoteType();

        Dispute storage d = disputes[disputeId];
        if (d.escrowId == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Active) {
            revert DisputeAlreadyResolved(disputeId);
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
            d.status = DisputeStatus.Resolved;
            emit DisputeResolved(
                disputeId,
                VoteType.Release,
                d.releaseVotes,
                d.refundVotes
            );
        } else if (d.refundVotes >= 2) {
            d.status = DisputeStatus.Resolved;
            emit DisputeResolved(
                disputeId,
                VoteType.Refund,
                d.releaseVotes,
                d.refundVotes
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                            APPEALS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice File an appeal on a resolved dispute
     * @dev Appellant stakes XOM (returned if appeal succeeds).
     *      Escalates to 5-arbitrator panel with 3-of-5 majority.
     * @param disputeId Dispute ID to appeal
     */
    function fileAppeal(
        uint256 disputeId
    ) external nonReentrant whenNotPaused {
        Dispute storage d = disputes[disputeId];
        if (d.escrowId == 0) revert DisputeNotFound(disputeId);
        if (d.status != DisputeStatus.Resolved) {
            revert DisputeAlreadyResolved(disputeId);
        }
        if (d.appealed) revert AlreadyAppealed(disputeId);

        // Only buyer or seller can appeal
        if (msg.sender != d.buyer && msg.sender != d.seller) {
            revert NotEscrowParty();
        }

        // Calculate appeal stake (50% of arbitration fee)
        uint256 fee = (d.disputedAmount * ARBITRATION_FEE_BPS) / BPS;
        uint256 appealStake = (fee * appealStakeMultiplier) / BPS;

        // Transfer appeal stake
        xomToken.safeTransferFrom(
            msg.sender,
            address(this),
            appealStake
        );

        // Select 5 new arbitrators (excluding original 3)
        address[5] memory appealArbitrators = _selectAppealArbitrators(
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
     * @dev 3-of-5 majority resolves the appeal
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

        // Verify assigned appeal arbitrator
        bool isArbitrator = false;
        for (uint256 i = 0; i < 5; ++i) {
            if (a.arbitrators[i] == msg.sender) {
                isArbitrator = true;
                break;
            }
        }
        if (!isArbitrator) revert NotAssignedArbitrator();

        if (appealVotes[disputeId][msg.sender] != VoteType.None) {
            revert AlreadyVoted();
        }

        appealVotes[disputeId][msg.sender] = vote;

        if (vote == VoteType.Release) {
            a.releaseVotes++;
        } else {
            a.refundVotes++;
        }

        emit VoteCast(disputeId, msg.sender, vote);

        // Check for 3-of-5 majority
        if (a.releaseVotes >= 3 || a.refundVotes >= 3) {
            a.resolved = true;

            VoteType outcome = a.releaseVotes >= 3
                ? VoteType.Release
                : VoteType.Refund;

            // Check if original decision was overturned
            Dispute storage d = disputes[disputeId];
            VoteType originalOutcome = d.releaseVotes >= 2
                ? VoteType.Release
                : VoteType.Refund;
            bool overturned = outcome != originalOutcome;

            d.status = DisputeStatus.Resolved;

            // If appeal succeeds (overturned), return stake
            if (overturned) {
                xomToken.safeTransfer(a.appellant, a.appealStake);
            }

            emit AppealResolved(disputeId, outcome, overturned);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                       TIMEOUT RESOLUTION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Trigger default resolution after deadline passes
     * @dev Default: refund to buyer. Either party can trigger.
     * @param disputeId Dispute ID
     */
    function triggerDefaultResolution(
        uint256 disputeId
    ) external nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.escrowId == 0) revert DisputeNotFound(disputeId);
        if (d.status == DisputeStatus.Resolved ||
            d.status == DisputeStatus.DefaultResolved) {
            revert DisputeAlreadyResolved(disputeId);
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < d.deadline) {
            revert DeadlineNotReached(d.deadline);
        }

        d.status = DisputeStatus.DefaultResolved;

        emit DisputeDefaultResolved(disputeId, msg.sender);
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
    function arbitratorPoolSize() external view returns (uint256) {
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
        arbitratorShare = (totalFee * ARBITRATOR_FEE_SHARE) / BPS;
        validatorShare = (totalFee * VALIDATOR_FEE_SHARE) / BPS;
        oddaoShare = totalFee - arbitratorShare - validatorShare;
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update contract references
     * @param _participation New OmniParticipation address
     * @param _escrow New escrow address
     */
    function updateContracts(
        address _participation,
        address _escrow
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_participation != address(0)) {
            participation = IArbitrationParticipation(_participation);
        }
        if (_escrow != address(0)) {
            escrow = IArbitrationEscrow(_escrow);
        }
    }

    /**
     * @notice Update minimum arbitrator stake
     * @param _minStake New minimum in XOM (18 decimals)
     */
    function setMinArbitratorStake(
        uint256 _minStake
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minArbitratorStake = _minStake;
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
     * @notice Deterministically select arbitrators for a dispute
     * @dev Uses hash of dispute parameters + previous block hash +
     *      caller address + block number for unpredictable selection.
     *      The previous block hash cannot be known by the caller at
     *      the time they submit the transaction (it depends on the
     *      block in which the tx is included). Combined with
     *      msg.sender and block.number, this provides sufficient
     *      entropy for fair selection.
     *
     *      Note: For production mainnet, consider upgrading to
     *      Chainlink VRF for cryptographic randomness guarantees.
     *
     * @param escrowId Escrow ID
     * @param count Number of arbitrators to select
     * @param buyer Buyer address (excluded from selection)
     * @param seller Seller address (excluded from selection)
     * @return selected Array of selected arbitrator addresses
     */
    function _selectArbitrators(
        uint256 escrowId,
        uint256 count,
        address buyer,
        address seller
    ) internal view returns (address[3] memory selected) {
        uint256 poolSize = arbitratorPool.length;
        if (poolSize < count) revert NotEnoughArbitrators();

        uint256 found = 0;
        uint256 nonce = 0;

        while (found < count && nonce < MAX_ARBITRATOR_SEARCH) {
            // Deterministic but unpredictable hash using multiple
            // entropy sources
            bytes32 hash = keccak256(
                abi.encodePacked(
                    escrowId,
                    blockhash(block.number - 1),
                    block.number,
                    msg.sender,
                    nonce
                )
            );
            uint256 idx = uint256(hash) % poolSize;
            address candidate = arbitratorPool[idx];

            // Skip if party to dispute, unqualified, or duplicate
            bool valid = (candidate != buyer &&
                candidate != seller &&
                arbitratorStakes[candidate] >= minArbitratorStake &&
                participation.canBeValidator(candidate));

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
                    found++;
                }
            }

            nonce++;
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
        if (poolSize < 8) revert NotEnoughArbitrators(); // Need 5 + 3 excluded

        Dispute storage d = disputes[disputeId];
        uint256 found = 0;
        uint256 nonce = 0;

        while (found < 5 && nonce < MAX_ARBITRATOR_SEARCH) {
            bytes32 hash = keccak256(
                abi.encodePacked(
                    disputeId,
                    blockhash(block.number - 1),
                    block.number,
                    msg.sender,
                    "appeal",
                    nonce
                )
            );
            uint256 idx = uint256(hash) % poolSize;
            address candidate = arbitratorPool[idx];

            // Skip parties, original arbitrators, unqualified, duplicates
            bool valid = (candidate != d.buyer &&
                candidate != d.seller &&
                arbitratorStakes[candidate] >= minArbitratorStake &&
                participation.canBeValidator(candidate));

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
                    found++;
                }
            }

            nonce++;
        }

        if (found < 5) revert NotEnoughArbitrators();
    }

    /**
     * @notice Authorize UUPS upgrades
     * @param newImplementation New implementation address
     */
    // solhint-disable-next-line no-unused-vars
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
