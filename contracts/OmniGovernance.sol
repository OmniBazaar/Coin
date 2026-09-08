// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    EIP712Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {
    ERC2771ContextUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {
    ContextUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IOmniVotingPowerCap} from "./governance/OmniVotingPowerCap.sol";

/* solhint-disable max-states-count, ordering */

/**
 * @title OmniGovernance
 * @author OmniCoin Development Team
 * @notice UUPS-upgradeable on-chain governance with timelock execution
 * @dev Full governance system with two proposal types, delegation support,
 *      and on-chain execution through OmniTimelockController.
 *
 * Architecture:
 * - Voting power = delegated XOM (ERC20Votes) + staked XOM (OmniCore)
 * - Two proposal types: ROUTINE (48h timelock) and CRITICAL (7-day timelock)
 * - Flash-loan protection via 1-day voting delay + snapshot voting weights
 * - On-chain execution through OmniTimelockController
 * - Gasless voting via EIP-712 signatures (castVoteBySig)
 *
 * Follows Compound Governor Bravo / OpenZeppelin Governor patterns.
 * Governance can upgrade itself through the timelock (self-referential).
 *
 * max-states-count disabled: Need 20+ states for comprehensive governance.
 * ordering disabled: Upgradeable contracts follow specific ordering pattern.
 */
contract OmniGovernance is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable,
    ERC2771ContextUpgradeable
{
    // =========================================================================
    // Type Declarations
    // =========================================================================

    /// @notice Proposal classification for timelock delay selection
    enum ProposalType {
        ROUTINE,
        CRITICAL
    }

    /// @notice Proposal lifecycle states
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Cancelled,
        Expired
    }

    /// @notice Vote options (Compound-compatible)
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /// @notice Full proposal data stored on-chain
    /// @dev Packed: proposer(20) + proposalType(1) + executed(1) +
    ///      cancelled(1) + queued(1) = 24 bytes in slot 1
    // solhint-disable-next-line gas-struct-packing
    struct Proposal {
        address proposer;
        ProposalType proposalType;
        bool executed;
        bool cancelled;
        bool queued;
        bytes32 descriptionHash;
        uint256 snapshotBlock;
        uint256 snapshotTotalSupply;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        /// @dev Quorum (bps) captured at creation so a later change to the
        ///      live `quorumBps` cannot retroactively move an open proposal's
        ///      pass bar. Appended field — safe for mapping-valued structs.
        uint256 snapshotQuorumBps;
    }

    /// @notice Encoded actions for a proposal (stored separately for gas)
    struct ProposalActions {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /* solhint-disable gas-small-strings */
    /// @notice EIP-712 typehash for vote-by-signature
    bytes32 public constant VOTE_TYPEHASH = keccak256(
        "Vote(uint256 proposalId,uint8 support,uint256 nonce)"
    );
    /* solhint-enable gas-small-strings */

    /// @notice Lower bound for the governance-tunable voting delay
    uint256 public constant MIN_VOTING_DELAY = 1 hours;

    /// @notice Upper bound for the governance-tunable voting delay
    uint256 public constant MAX_VOTING_DELAY = 14 days;

    /// @notice Lower bound for the governance-tunable voting period
    uint256 public constant MIN_VOTING_PERIOD = 1 days;

    /// @notice Upper bound for the governance-tunable voting period
    uint256 public constant MAX_VOTING_PERIOD = 30 days;

    /// @notice Lower bound for the governance-tunable proposal threshold
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 1_000e18;

    /// @notice Upper bound for the governance-tunable proposal threshold
    uint256 public constant MAX_PROPOSAL_THRESHOLD = 50_000_000e18;

    /// @notice Lower bound for the governance-tunable quorum (1% in bps)
    uint256 public constant MIN_QUORUM_BPS = 100;

    /// @notice Upper bound for the governance-tunable quorum (20% in bps)
    uint256 public constant MAX_QUORUM_BPS = 2_000;

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Maximum number of actions per proposal (gas limit)
    uint256 public constant MAX_ACTIONS = 10;

    /// @notice Time window after voting ends to queue a succeeded proposal
    uint256 public constant QUEUE_DEADLINE = 14 days;

    // =========================================================================
    // State Variables (STORAGE LAYOUT - DO NOT REORDER!)
    // =========================================================================

    /// @notice OmniCoin token with ERC20Votes delegation
    IVotes public omniCoin;

    /// @notice OmniCoin as IERC20 for totalSupply queries
    IERC20 public omniCoinERC20;

    /// @notice OmniCore contract for staking queries
    address public omniCore;

    /// @notice Timelock controller for queuing and executing proposals
    address public timelock;

    /// @notice Current proposal count (auto-incrementing ID)
    uint256 public proposalCount;

    /// @notice Proposal data by ID
    mapping(uint256 => Proposal) public proposals;

    /// @notice Proposal actions by ID (stored separately for gas)
    mapping(uint256 => ProposalActions) private _proposalActions;

    /// @notice Whether an address has voted on a proposal
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Vote weight by user and proposal
    mapping(uint256 => mapping(address => uint256)) public voteWeight;

    /// @notice Nonces for EIP-712 vote-by-signature
    mapping(address => uint256) private _voteNonces;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Optional voting-power cap sidecar. When set, `_castVote`
    ///         clamps voter weight via `effectiveWeight()`. Defaults
    ///         to `address(0)` (no clamping) for pre-cap proposals.
    ///         Set by admin via {setVotingPowerCap}.
    IOmniVotingPowerCap public votingPowerCap;

    /// @notice Delay between proposal creation and voting start.
    /// @dev Governance-tunable within [MIN_VOTING_DELAY, MAX_VOTING_DELAY]
    ///      via {setVotingDelay}. Seeded by {initializeGovernanceParamsV2}.
    uint256 public votingDelay;

    /// @notice Voting period duration.
    /// @dev Governance-tunable within [MIN_VOTING_PERIOD, MAX_VOTING_PERIOD]
    ///      via {setVotingPeriod}. Seeded by {initializeGovernanceParamsV2}.
    uint256 public votingPeriod;

    /// @notice Minimum voting power required to create a proposal.
    /// @dev Governance-tunable within
    ///      [MIN_PROPOSAL_THRESHOLD, MAX_PROPOSAL_THRESHOLD] via
    ///      {setProposalThreshold}. Seeded by {initializeGovernanceParamsV2}.
    uint256 public proposalThreshold;

    /// @notice Quorum as basis points of snapshot total supply.
    /// @dev Governance-tunable within [MIN_QUORUM_BPS, MAX_QUORUM_BPS]
    ///      via {setQuorumBps}. Seeded by {initializeGovernanceParamsV2}.
    uint256 public quorumBps;

    /// @notice Token holders excluded from the quorum denominator (the
    ///         "voteable supply"): contracts holding undistributed/locked XOM
    ///         that cannot vote — validator/block-reward pool, user-bonus pool,
    ///         unclaimed legacy, and the founder vest. Their live balances are
    ///         subtracted from totalSupply when a proposal snapshots quorum, so
    ///         the denominator tracks the genuinely voteable float and grows as
    ///         those pools distribute. Settable via {setQuorumExcludedHolders}.
    address[] public quorumExcludedHolders;

    /// @notice Storage gap for future upgrades
    /// @dev Pre-mainnet: gap set to 50. Reduce by N when adding N new
    ///      state variables. Decremented 50→49 when `votingPowerCap` was
    ///      added (2026-05-29 cap upgrade), then 49→45 when the four
    ///      governance-tunable params were added (settable-params upgrade),
    ///      then 45→44 when `quorumExcludedHolders` was added (voteable-supply
    ///      quorum upgrade).
    uint256[44] private __gap;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new proposal is created
    /// @param proposalId Unique proposal identifier
    /// @param proposer Address that created the proposal
    /// @param proposalType ROUTINE or CRITICAL
    /// @param voteStart Timestamp when voting begins
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType indexed proposalType,
        uint256 voteStart
    );

    /// @notice Emitted with full proposal details (for indexers)
    /// @param proposalId Unique proposal identifier
    /// @param targets Array of target contract addresses
    /// @param calldatas Array of encoded function calls
    /// @param description Human-readable proposal description
    event ProposalDetails(
        uint256 indexed proposalId,
        address[] targets,
        bytes[] calldatas,
        string description
    );

    /// @notice Emitted when a vote is cast
    /// @param proposalId Proposal being voted on
    /// @param voter Address casting the vote
    /// @param support Vote type (0=Against, 1=For, 2=Abstain)
    /// @param weight Voting power applied
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 indexed support,
        uint256 weight
    );

    /// @notice Emitted when a proposal is queued in the timelock
    /// @param proposalId Queued proposal identifier
    /// @param timelockId Timelock operation identifier
    event ProposalQueued(
        uint256 indexed proposalId,
        bytes32 indexed timelockId
    );

    /// @notice Emitted when a proposal is executed
    /// @param proposalId Executed proposal identifier
    event ProposalExecuted(uint256 indexed proposalId);

    /// @notice Emitted when a proposal is cancelled
    /// @param proposalId Cancelled proposal identifier
    event ProposalCancelled(uint256 indexed proposalId);

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when the voting-power-cap sidecar is wired in
    ///         or removed.
    /// @param cap Address of the new cap contract (zero if cleared)
    event VotingPowerCapSet(address indexed cap);

    /// @notice Emitted when admin authority is transferred to the timelock
    /// @param previousAdmin Address that held the admin role
    /// @param timelockAddress Address of the timelock (new admin)
    event AdminTransferredToTimelock(
        address indexed previousAdmin,
        address indexed timelockAddress
    );

    /// @notice Emitted when a timelock cancel fails during proposal cancellation
    /// @param proposalId The proposal whose timelock cancel failed
    /// @param timelockId The timelock operation that could not be cancelled
    event TimelockCancelFailed(
        uint256 indexed proposalId,
        bytes32 indexed timelockId
    );

    /// @notice Emitted when the voting delay is updated
    /// @param previousValue Prior voting delay (seconds)
    /// @param newValue New voting delay (seconds)
    event VotingDelayUpdated(
        uint256 indexed previousValue,
        uint256 indexed newValue
    );

    /// @notice Emitted when the voting period is updated
    /// @param previousValue Prior voting period (seconds)
    /// @param newValue New voting period (seconds)
    event VotingPeriodUpdated(
        uint256 indexed previousValue,
        uint256 indexed newValue
    );

    /// @notice Emitted when the proposal threshold is updated
    /// @param previousValue Prior proposal threshold (wei)
    /// @param newValue New proposal threshold (wei)
    event ProposalThresholdUpdated(
        uint256 indexed previousValue,
        uint256 indexed newValue
    );

    /// @notice Emitted when the quorum (basis points) is updated
    /// @param previousValue Prior quorum in basis points
    /// @param newValue New quorum in basis points
    event QuorumBpsUpdated(
        uint256 indexed previousValue,
        uint256 indexed newValue
    );

    /// @notice Emitted when the quorum-excluded holder set is updated
    /// @param count Number of excluded holders after the update
    event QuorumExcludedHoldersUpdated(uint256 indexed count);

    /// @notice Emitted when the governance execution target is re-pointed
    ///         (e.g. to a redeployed OmniTimelockController at the handover).
    /// @param previousTimelock Prior timelock address
    /// @param newTimelock New timelock address
    event TimelockUpdated(
        address indexed previousTimelock,
        address indexed newTimelock
    );

    // =========================================================================
    // Custom Errors
    // =========================================================================

    /// @notice Thrown when proposer lacks sufficient voting power
    error InsufficientVotingPower();
    /// @notice Thrown when proposal is not in the required state
    error InvalidProposalState(ProposalState current, ProposalState expected);
    /// @notice Thrown when voter has already voted on this proposal
    error AlreadyVoted();
    /// @notice Thrown when vote type is not 0, 1, or 2
    error InvalidVoteType();
    /// @notice Thrown when voter has zero voting power
    error ZeroVotingPower();
    /// @notice Thrown when actions arrays have mismatched lengths
    error InvalidActionsLength();
    /// @notice Thrown when proposal has too many actions
    error TooManyActions();
    /// @notice Thrown when address is zero
    error InvalidAddress();
    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();
    /// @notice Thrown when EIP-712 signature is invalid
    error InvalidSignature();
    /// @notice Thrown when signature nonce does not match
    error InvalidNonce();
    /// @notice Thrown when queue deadline has passed for a succeeded proposal
    error QueueDeadlinePassed();
    /// @notice Thrown when the queried proposal does not exist
    error ProposalNotFound();
    /// @notice Thrown when caller is not authorized to cancel
    error NotAuthorizedToCancel();
    /// @notice Thrown when timelock cancel call fails during proposal cancellation
    error TimelockCancelError(bytes32 timelockId);
    /// @notice Thrown when a ROUTINE proposal contains critical selectors
    error CriticalActionInRoutineProposal();
    /// @notice Thrown when a governance parameter is set outside its bounds
    error ParameterOutOfBounds();

    // =========================================================================
    // Constructor & Initializer
    // =========================================================================

    /**
     * @notice Disable initializers on implementation contract
     * @dev Sets the trusted forwarder address as an immutable (stored in
     *      bytecode, not proxy storage). Pass address(0) to disable
     *      meta-transaction support.
     * @param trustedForwarder_ Address of the OmniForwarder contract
     *        for gasless relay
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
     * @notice Initialize governance with core contract references
     * @dev Can only be called once via proxy deployment
     * @param _omniCoin Address of OmniCoin (ERC20Votes) token
     * @param _omniCore Address of OmniCore contract
     * @param _timelock Address of OmniTimelockController
     * @param admin Address to receive initial admin role
     */
    function initialize(
        address _omniCoin,
        address _omniCore,
        address _timelock,
        address admin
    ) public initializer {
        if (
            _omniCoin == address(0) || _omniCore == address(0) ||
            _timelock == address(0) || admin == address(0)
        ) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("OmniGovernance", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        omniCoin = IVotes(_omniCoin);
        omniCoinERC20 = IERC20(_omniCoin);
        omniCore = _omniCore;
        timelock = _timelock;

        // Seed governance-tunable params for FRESH deploys. The already-live
        // mainnet proxy ran initialize() before these existed, so it is
        // seeded by {initializeGovernanceParamsV2} on the upgrade instead.
        votingDelay = 2 days;
        votingPeriod = 7 days;
        proposalThreshold = 1_700_000e18;
        quorumBps = 150;
    }

    /**
     * @notice Seed the governance-tunable parameters introduced by the
     *         settable-params upgrade.
     * @dev `reinitializer(2)` runs exactly once, atomically, when the proxy
     *      is upgraded to this implementation via
     *      `upgradeToAndCall(newImpl, abi.encodeCall(this.initializeGovernanceParamsV2, ()))`.
     *      Gated by DEFAULT_ADMIN_ROLE so a front-runner cannot consume the
     *      initializer slot and brick the atomic upgrade call. Seeds the
     *      founder-ratified launch values (2026-06-09): 2-day delay, 7-day
     *      period, 1.7M XOM threshold (~0.1% of the ~1.725B launch float),
     *      150 bps quorum (~4% of that float, denominated against total
     *      supply). Thereafter the values are adjustable only via the
     *      DEFAULT_ADMIN_ROLE setters — deployer-gated during Pioneer,
     *      timelock(governance)-gated after the admin handoff.
     */
    function initializeGovernanceParamsV2()
        public
        reinitializer(2)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        votingDelay = 2 days;
        votingPeriod = 7 days;
        proposalThreshold = 1_700_000e18;
        quorumBps = 150;

        emit VotingDelayUpdated(0, 2 days);
        emit VotingPeriodUpdated(0, 7 days);
        emit ProposalThresholdUpdated(0, 1_700_000e18);
        emit QuorumBpsUpdated(0, 150);
    }

    // =========================================================================
    // External Functions - Proposal Lifecycle
    // =========================================================================

    /**
     * @notice Create a new governance proposal
     * @dev Proposer must have voting power >= PROPOSAL_THRESHOLD.
     *      Snapshots block number and total supply at creation time.
     *      Voting starts after VOTING_DELAY (1 day).
     * @param proposalType ROUTINE (48h timelock) or CRITICAL (7-day timelock)
     * @param targets Array of target contract addresses
     * @param values Array of ETH values to send (usually 0)
     * @param calldatas Array of encoded function calls
     * @param description Human-readable proposal description (hashed on-chain)
     * @return proposalId Unique proposal identifier
     */
    function propose(
        ProposalType proposalType,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external nonReentrant returns (uint256 proposalId) {
        _validateActions(targets, values, calldatas);

        // M-02: Validate ROUTINE proposals do not contain critical selectors
        if (proposalType == ProposalType.ROUTINE) {
            _validateNoCriticalSelectors(calldatas);
        }

        address caller = _msgSender();
        // ATK-H02 hardening: gate the proposal threshold on the proposer's
        // power at the PRIOR block (getPastVotes + checkpointed stake), so a
        // flash-acquired balance within this same block cannot clear the
        // threshold and spam proposals.
        uint256 votingPower = getVotingPowerAt(caller, block.number - 1);
        if (votingPower < proposalThreshold) {
            revert InsufficientVotingPower();
        }

        proposalId = ++proposalCount;

        // Snapshot for flash-loan protection
        // solhint-disable-next-line not-rely-on-time
        uint256 voteStart = block.timestamp + votingDelay;
        uint256 voteEnd = voteStart + votingPeriod;

        proposals[proposalId] = Proposal({
            proposer: caller,
            proposalType: proposalType,
            descriptionHash: keccak256(bytes(description)),
            snapshotBlock: block.number,
            snapshotTotalSupply: voteableSupply(),
            snapshotQuorumBps: quorumBps,
            voteStart: voteStart,
            voteEnd: voteEnd,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            executed: false,
            cancelled: false,
            queued: false
        });

        // Store actions separately (gas optimization for reads)
        ProposalActions storage actions = _proposalActions[proposalId];
        for (uint256 i = 0; i < targets.length; ++i) {
            actions.targets.push(targets[i]);
            actions.values.push(values[i]);
            actions.calldatas.push(calldatas[i]);
        }

        emit ProposalCreated(
            proposalId, caller, proposalType, voteStart
        );
        emit ProposalDetails(
            proposalId, targets, calldatas, description
        );
    }

    /**
     * @notice Cast a vote on an active proposal
     * @param proposalId Proposal to vote on
     * @param support Vote type (0=Against, 1=For, 2=Abstain)
     */
    function castVote(
        uint256 proposalId,
        uint8 support
    ) external nonReentrant {
        _castVote(proposalId, _msgSender(), support);
    }

    /**
     * @notice Cast a vote using an EIP-712 signature (gasless voting)
     * @dev Allows relayers to submit votes on behalf of token holders
     * @param proposalId Proposal to vote on
     * @param support Vote type (0=Against, 1=For, 2=Abstain)
     * @param nonce Signer's current vote nonce
     * @param v ECDSA v parameter
     * @param r ECDSA r parameter
     * @param s ECDSA s parameter
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint256 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(VOTE_TYPEHASH, proposalId, support, nonce)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, v, r, s);

        if (signer == address(0)) revert InvalidSignature();
        if (_voteNonces[signer] != nonce) revert InvalidNonce();

        ++_voteNonces[signer];
        _castVote(proposalId, signer, support);
    }

    /**
     * @notice Queue a succeeded proposal in the timelock
     * @dev Can only be called after voting ends and proposal passed.
     *      Must be called within QUEUE_DEADLINE after voting ends.
     * @param proposalId Proposal to queue
     */
    function queue(uint256 proposalId) external nonReentrant {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Succeeded) {
            revert InvalidProposalState(
                currentState, ProposalState.Succeeded
            );
        }

        Proposal storage proposal = proposals[proposalId];

        // Check queue deadline
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > proposal.voteEnd + QUEUE_DEADLINE) {
            revert QueueDeadlinePassed();
        }

        proposal.queued = true;

        ProposalActions storage actions = _proposalActions[proposalId];

        // Determine delay based on proposal type
        uint256 delay = proposal.proposalType == ProposalType.CRITICAL
            ? 7 days
            : 48 hours;

        // Generate unique salt from proposal ID
        bytes32 salt = keccak256(
            abi.encodePacked("OmniGov", proposalId)
        );

        // Queue in timelock via scheduleBatch
        /* solhint-disable avoid-low-level-calls,gas-small-strings */
        (bool success, ) = timelock.call(
            abi.encodeWithSignature(
                "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
                actions.targets,
                actions.values,
                actions.calldatas,
                bytes32(0), // no predecessor
                salt,
                delay
            )
        );
        /* solhint-enable avoid-low-level-calls,gas-small-strings */

        if (!success) {
            proposal.queued = false;
            // If scheduling fails, revert
            revert InvalidProposalState(
                currentState, ProposalState.Succeeded
            );
        }

        bytes32 timelockId = _getTimelockId(proposalId);
        emit ProposalQueued(proposalId, timelockId);
    }

    /**
     * @notice Execute a queued proposal after timelock delay
     * @param proposalId Proposal to execute
     */
    function execute(uint256 proposalId) external nonReentrant {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Queued) {
            revert InvalidProposalState(
                currentState, ProposalState.Queued
            );
        }

        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;

        ProposalActions storage actions = _proposalActions[proposalId];
        bytes32 salt = keccak256(
            abi.encodePacked("OmniGov", proposalId)
        );

        // Execute via timelock
        /* solhint-disable avoid-low-level-calls,gas-small-strings */
        (bool success, ) = timelock.call(
            abi.encodeWithSignature(
                "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
                actions.targets,
                actions.values,
                actions.calldatas,
                bytes32(0), // no predecessor
                salt
            )
        );
        /* solhint-enable avoid-low-level-calls,gas-small-strings */

        if (!success) {
            proposal.executed = false;
            revert InvalidProposalState(
                currentState, ProposalState.Queued
            );
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cancel a proposal
     * @dev Can be cancelled by the proposer (if their voting power dropped
     *      below threshold) or by anyone with ADMIN_ROLE (emergency).
     * @param proposalId Proposal to cancel
     */
    function cancel(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        // M-01: Validate proposal exists before cancellation
        if (proposal.proposer == address(0)) {
            revert ProposalNotFound();
        }

        if (proposal.executed || proposal.cancelled) {
            revert InvalidProposalState(
                state(proposalId), ProposalState.Pending
            );
        }

        // L-03: Use dedicated authorization error
        address caller = _msgSender();
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, caller);

        if (isAdmin) {
            // Admin (timelock) can always cancel at any stage
        } else if (caller == proposal.proposer) {
            // M-02 (Round 6): Proposer can only cancel during Pending or Active.
            // After voting ends and a proposal has Succeeded or been Queued,
            // the community has spoken and the proposer should not be able to
            // unilaterally veto the decision. Governor Bravo pattern.
            ProposalState currentState = state(proposalId);
            if (
                currentState != ProposalState.Pending &&
                currentState != ProposalState.Active
            ) {
                revert NotAuthorizedToCancel();
            }
        } else {
            revert NotAuthorizedToCancel();
        }

        proposal.cancelled = true;

        // L-02: If queued, attempt timelock cancel and revert on failure.
        // The timelock cancel will fail if OmniGovernance lacks CANCELLER_ROLE
        // on the timelock — reverting here surfaces the root cause rather than
        // silently proceeding with a cancelled proposal whose timelock operation
        // is still pending.
        if (proposal.queued) {
            bytes32 timelockId = _getTimelockId(proposalId);
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = timelock.call(
                abi.encodeWithSignature("cancel(bytes32)", timelockId)
            );
            if (!success) {
                revert TimelockCancelError(timelockId);
            }
        }

        emit ProposalCancelled(proposalId);
    }

    // =========================================================================
    // External View Functions
    // =========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Get current state of a proposal
     * @param proposalId Proposal to query
     * @return Current ProposalState
     */
    function state(
        uint256 proposalId
    ) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        // L-01: Revert on non-existent proposals instead of returning Pending
        if (proposal.proposer == address(0) && proposal.voteStart == 0) {
            revert ProposalNotFound();
        }

        if (proposal.voteStart == 0) {
            return ProposalState.Pending;
        }
        if (proposal.cancelled) return ProposalState.Cancelled;
        if (proposal.executed) return ProposalState.Executed;

        // solhint-disable-next-line not-rely-on-time
        uint256 currentTime = block.timestamp;

        if (currentTime < proposal.voteStart) {
            return ProposalState.Pending;
        }

        // solhint-disable-next-line gas-strict-inequalities
        if (currentTime <= proposal.voteEnd) {
            return ProposalState.Active;
        }

        // Voting has ended - check results
        if (!_proposalPassed(proposal)) return ProposalState.Defeated;

        if (proposal.queued) return ProposalState.Queued;

        // Succeeded but check queue deadline
        // solhint-disable-next-line not-rely-on-time
        if (currentTime > proposal.voteEnd + QUEUE_DEADLINE) {
            return ProposalState.Expired;
        }

        return ProposalState.Succeeded;
    }
    /* solhint-enable code-complexity */

    /**
     * @notice Get an address's CURRENT voting power (delegated + staked)
     * @dev Combines current ERC20Votes delegation power with current OmniCore
     *      stake. For live display only (e.g. the voting-power API). The
     *      proposal-threshold gate and vote tallying use the snapshot variant
     *      {getVotingPowerAt}, never this one — see ATK-H02.
     * @param account Address to query
     * @return Total current voting power
     */
    function getVotingPower(
        address account
    ) public view returns (uint256) {
        // Delegated voting power from OmniCoin (ERC20Votes)
        uint256 delegatedPower = omniCoin.getVotes(account);

        // Staked XOM in OmniCore
        uint256 stakedPower = _getStakedAmount(account);

        return delegatedPower + stakedPower;
    }

    /**
     * @notice Get voting power at a specific past block
     * @dev Uses ERC20Votes.getPastVotes for delegated power and
     *      OmniCore.getStakedAt (checkpointed) for staked power, both at the
     *      given block (ATK-H02). No fallback to current balances, so
     *      post-snapshot staking cannot inflate vote weight.
     * @param account Address to query
     * @param blockNumber Block to query at
     * @return Total voting power at the given block
     */
    function getVotingPowerAt(
        address account,
        uint256 blockNumber
    ) public view returns (uint256) {
        uint256 delegatedPower = omniCoin.getPastVotes(
            account, blockNumber
        );
        uint256 stakedPower = _getStakedAmountAt(account, blockNumber);
        return delegatedPower + stakedPower;
    }

    /**
     * @notice Get the actions for a proposal
     * @param proposalId Proposal to query
     * @return targets Array of target addresses
     * @return values Array of ETH values
     * @return calldatas Array of encoded calls
     */
    function getActions(
        uint256 proposalId
    ) external view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) {
        ProposalActions storage actions = _proposalActions[proposalId];
        return (actions.targets, actions.values, actions.calldatas);
    }

    /**
     * @notice Get the quorum requirement for a proposal
     * @param proposalId Proposal to check
     * @return Minimum total votes required for quorum
     */
    function quorum(
        uint256 proposalId
    ) external view returns (uint256) {
        return (proposals[proposalId].snapshotTotalSupply *
            proposals[proposalId].snapshotQuorumBps)
            / BASIS_POINTS;
    }

    /**
     * @notice The current voteable supply — totalSupply minus the live
     *         balances of the quorum-excluded holders (undistributed
     *         validator-reward + bonus pools, unclaimed legacy, founder vest).
     *         This is the denominator each new proposal snapshots for quorum;
     *         it rises automatically as those pools distribute/claim.
     * @return The voteable XOM supply (18 decimals).
     */
    function voteableSupply() public view returns (uint256) {
        uint256 total = omniCoinERC20.totalSupply();
        uint256 excluded = 0;
        uint256 len = quorumExcludedHolders.length;
        for (uint256 i = 0; i < len; ++i) {
            excluded += omniCoinERC20.balanceOf(quorumExcludedHolders[i]);
        }
        // Defensive: never underflow if the exclusion set ever drifts above
        // the total supply.
        return total > excluded ? total - excluded : 0;
    }

    /**
     * @notice Get the current vote nonce for an address
     * @dev Used for EIP-712 vote-by-signature replay protection
     * @param voter Address to query
     * @return Current nonce
     */
    function voteNonce(address voter) external view returns (uint256) {
        return _voteNonces[voter];
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again. This is the strongest
     *      possible signal of decentralization.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Wire in (or remove) the voting-power cap sidecar.
     * @dev Admin-only. Pass `address(0)` to remove the cap (revert to
     *      uncapped voting). When set, `_castVote` consults the cap's
     *      `effectiveWeight()` to clamp voters whose addresses are
     *      registered in the cap contract. Founder-authorized
     *      2026-05-29 as the LP-Briefing voting-power-cap mechanism.
     * @param cap Address of an `IOmniVotingPowerCap` implementation,
     *            or `address(0)` to disable clamping.
     */
    function setVotingPowerCap(IOmniVotingPowerCap cap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        votingPowerCap = cap;
        emit VotingPowerCapSet(address(cap));
    }

    /**
     * @notice Update the delay between proposal creation and voting start.
     * @dev DEFAULT_ADMIN_ROLE-gated (deployer in Pioneer; timelock after
     *      handoff). Reverts if outside [MIN_VOTING_DELAY, MAX_VOTING_DELAY].
     * @param newDelay New voting delay in seconds.
     */
    function setVotingDelay(uint256 newDelay)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newDelay < MIN_VOTING_DELAY || newDelay > MAX_VOTING_DELAY) {
            revert ParameterOutOfBounds();
        }
        uint256 previous = votingDelay;
        votingDelay = newDelay;
        emit VotingDelayUpdated(previous, newDelay);
    }

    /**
     * @notice Update the voting period duration.
     * @dev DEFAULT_ADMIN_ROLE-gated. Reverts if outside
     *      [MIN_VOTING_PERIOD, MAX_VOTING_PERIOD].
     * @param newPeriod New voting period in seconds.
     */
    function setVotingPeriod(uint256 newPeriod)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newPeriod < MIN_VOTING_PERIOD || newPeriod > MAX_VOTING_PERIOD) {
            revert ParameterOutOfBounds();
        }
        uint256 previous = votingPeriod;
        votingPeriod = newPeriod;
        emit VotingPeriodUpdated(previous, newPeriod);
    }

    /**
     * @notice Update the minimum voting power required to create a proposal.
     * @dev DEFAULT_ADMIN_ROLE-gated. Reverts if outside
     *      [MIN_PROPOSAL_THRESHOLD, MAX_PROPOSAL_THRESHOLD].
     * @param newThreshold New proposal threshold in wei.
     */
    function setProposalThreshold(uint256 newThreshold)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            newThreshold < MIN_PROPOSAL_THRESHOLD ||
            newThreshold > MAX_PROPOSAL_THRESHOLD
        ) {
            revert ParameterOutOfBounds();
        }
        uint256 previous = proposalThreshold;
        proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(previous, newThreshold);
    }

    /**
     * @notice Update the quorum, expressed in basis points of snapshot supply.
     * @dev DEFAULT_ADMIN_ROLE-gated. Reverts if outside
     *      [MIN_QUORUM_BPS, MAX_QUORUM_BPS]. The bounds prevent a hostile or
     *      buggy proposal from setting quorum to 0 (anything passes) or to an
     *      unreachable level (permanent gridlock).
     * @param newQuorumBps New quorum in basis points.
     */
    function setQuorumBps(uint256 newQuorumBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newQuorumBps < MIN_QUORUM_BPS || newQuorumBps > MAX_QUORUM_BPS) {
            revert ParameterOutOfBounds();
        }
        uint256 previous = quorumBps;
        quorumBps = newQuorumBps;
        emit QuorumBpsUpdated(previous, newQuorumBps);
    }

    /**
     * @notice Replace the set of holders excluded from the quorum denominator.
     * @dev DEFAULT_ADMIN_ROLE-gated (deployer in Pioneer; timelock after
     *      handoff). These are contracts holding undistributed/locked XOM that
     *      cannot vote (validator-reward pool, bonus pool, unclaimed legacy,
     *      founder vest). Their live balances are subtracted from totalSupply
     *      to form each new proposal's quorum denominator. Pass the full set
     *      (replaces, not appends). Zero addresses are rejected.
     * @param holders The complete list of excluded holder addresses.
     */
    function setQuorumExcludedHolders(address[] calldata holders)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        delete quorumExcludedHolders;
        for (uint256 i = 0; i < holders.length; ++i) {
            if (holders[i] == address(0)) revert InvalidAddress();
            quorumExcludedHolders.push(holders[i]);
        }
        emit QuorumExcludedHoldersUpdated(holders.length);
    }

    /**
     * @notice Re-point the governance execution target to a (re)deployed
     *         OmniTimelockController.
     * @dev DEFAULT_ADMIN_ROLE-gated (deployer in Pioneer; timelock after the
     *      handoff). The `timelock` address is otherwise set once in
     *      {initialize} and has no setter — this exists so the governance
     *      handover can first point governance at a hardened timelock, then
     *      call {transferAdminToTimelock}. Must be called BEFORE any proposal
     *      is queued against the new timelock.
     * @param newTimelock Address of the new OmniTimelockController.
     */
    function setTimelock(address newTimelock)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newTimelock == address(0)) revert InvalidAddress();
        address previous = timelock;
        timelock = newTimelock;
        emit TimelockUpdated(previous, newTimelock);
    }

    /**
     * @notice Transfer all admin authority to the timelock (irreversible)
     * @dev H-01 fix: One-shot function that atomically grants ADMIN_ROLE and
     *      DEFAULT_ADMIN_ROLE to the timelock, then revokes both from the
     *      caller. This ensures governance cannot be bypassed by the deployer
     *      after the system is operational.
     *
     *      Expected deployment sequence:
     *      1. Deploy OmniGovernance via proxy with admin = deployer
     *      2. Deploy OmniTimelockController
     *      3. Configure all roles and contracts
     *      4. Call transferAdminToTimelock() to hand over control
     *      5. After this call, only governance proposals through the
     *         timelock can exercise admin powers
     */
    function transferAdminToTimelock()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        address timelockAddr = timelock;
        if (timelockAddr == address(0)) revert InvalidAddress();

        // M-01 audit fix: use _msgSender() for ERC-2771 consistency.
        // The onlyRole modifier uses _msgSender() internally, so the
        // revocation must target the same address that passed the check.
        address caller = _msgSender();

        // Grant DEFAULT_ADMIN_ROLE to the timelock
        _grantRole(DEFAULT_ADMIN_ROLE, timelockAddr);

        // Revoke DEFAULT_ADMIN_ROLE from the caller
        _revokeRole(DEFAULT_ADMIN_ROLE, caller);

        emit AdminTransferredToTimelock(caller, timelockAddr);
    }

    // =========================================================================
    // Internal Functions
    // =========================================================================

    /**
     * @notice Authorize UUPS upgrades (admin only, respects ossification)
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }

    /**
     * @notice Internal vote casting logic
     * @param proposalId Proposal to vote on
     * @param voter Address casting the vote
     * @param support Vote type (0=Against, 1=For, 2=Abstain)
     */
    function _castVote(
        uint256 proposalId,
        address voter,
        uint8 support
    ) internal {
        ProposalState currentState = state(proposalId);
        if (currentState != ProposalState.Active) {
            revert InvalidProposalState(
                currentState, ProposalState.Active
            );
        }

        if (hasVoted[proposalId][voter]) revert AlreadyVoted();

        // Snapshot-block power for BOTH delegated and staked (ATK-H02)
        Proposal storage proposal = proposals[proposalId];
        uint256 weight = getVotingPowerAt(
            voter, proposal.snapshotBlock
        );

        // Voting-power-cap sidecar (founder-authorized 2026-05-29).
        // When wired (votingPowerCap != address(0)), clamp the voter's
        // weight to the configured per-voter cap as a fraction of the
        // proposal's snapshot total supply. Uncapped voters pass
        // through unchanged. See OmniVotingPowerCap.sol for the
        // BASIS_POINTS math.
        //
        // Defensive-min hardening (audit I-3): take the LESSER of the
        // raw weight and the cap's return value. A malicious or buggy
        // cap implementation can never inflate the voter's weight
        // above the snapshot-derived raw value.
        IOmniVotingPowerCap cap = votingPowerCap;
        if (address(cap) != address(0)) {
            uint256 clamped = cap.effectiveWeight(
                voter, weight, proposal.snapshotTotalSupply
            );
            if (clamped < weight) {
                weight = clamped;
            }
        }

        if (weight == 0) revert ZeroVotingPower();

        hasVoted[proposalId][voter] = true;
        voteWeight[proposalId][voter] = weight;

        if (support == uint8(VoteType.For)) {
            proposal.forVotes += weight;
        } else if (support == uint8(VoteType.Against)) {
            proposal.againstVotes += weight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposal.abstainVotes += weight;
        } else {
            revert InvalidVoteType();
        }

        emit VoteCast(proposalId, voter, support, weight);
    }

    /**
     * @notice Check if a proposal passed (majority + quorum)
     * @dev Requires strict majority (forVotes > againstVotes) and
     *      quorum (total votes >= 4% of snapshotted total supply).
     * @param proposal Proposal to check
     * @return True if proposal passed
     */
    function _proposalPassed(
        Proposal storage proposal
    ) internal view returns (bool) {
        // Strict majority: forVotes > againstVotes
        // solhint-disable-next-line gas-strict-inequalities
        if (proposal.forVotes <= proposal.againstVotes) return false;

        // M-01: Quorum: total votes >= 4% of snapshotted supply
        uint256 quorumVotes =
            (proposal.snapshotTotalSupply * proposal.snapshotQuorumBps) /
                BASIS_POINTS;
        uint256 totalVotes = proposal.forVotes +
            proposal.againstVotes +
            proposal.abstainVotes;

        // solhint-disable-next-line gas-strict-inequalities
        return totalVotes >= quorumVotes;
    }

    /**
     * @notice Validate proposal actions arrays
     * @param targets Target addresses
     * @param values ETH values
     * @param calldatas Encoded function calls
     */
    function _validateActions(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) internal pure {
        if (
            targets.length == 0 ||
            targets.length != values.length ||
            targets.length != calldatas.length
        ) {
            revert InvalidActionsLength();
        }
        if (targets.length > MAX_ACTIONS) revert TooManyActions();
    }

    /**
     * @notice Validate that calldata does not contain critical selectors
     * @dev M-02 fix: Queries the timelock's isCriticalSelector() for each
     *      action's function selector. Reverts if any ROUTINE proposal
     *      contains a critical selector, preventing misclassification that
     *      would cause the proposal to become stuck at queue time.
     * @param calldatas Array of encoded function calls to validate
     */
    function _validateNoCriticalSelectors(
        bytes[] calldata calldatas
    ) internal view {
        for (uint256 i = 0; i < calldatas.length; ++i) {
            // solhint-disable-next-line gas-strict-inequalities
            if (calldatas[i].length >= 4) {
                bytes4 selector = bytes4(calldatas[i][:4]);
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, bytes memory data) = timelock.staticcall(
                    abi.encodeWithSignature(
                        "isCriticalSelector(bytes4)",
                        selector
                    )
                );
                /* solhint-disable gas-strict-inequalities */
                if (
                    success &&
                    data.length >= 32 &&
                    abi.decode(data, (bool))
                ) {
                /* solhint-enable gas-strict-inequalities */
                    revert CriticalActionInRoutineProposal();
                }
            }
        }
    }

    /**
     * @notice Get current staked XOM amount for an address from OmniCore
     * @dev Reads the stakes mapping from OmniCore. Returns 0 if the
     *      call fails (e.g., OmniCore is paused or unavailable).
     * @param account Address to query
     * @return amount Staked XOM amount (0 if no active stake)
     */
    function _getStakedAmount(
        address account
    ) internal view returns (uint256 amount) {
        // OmniCore.stakes(address) returns (amount, tier, duration, lockTime, active)
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = omniCore.staticcall(
            abi.encodeWithSignature("stakes(address)", account)
        );

        if (success && data.length > 0) {
            // Decode first two values: amount and skip to active (5th)
            (uint256 stakedAmount, , , , bool active) = abi.decode(
                data, (uint256, uint256, uint256, uint256, bool)
            );
            if (active) return stakedAmount;
        }

        return 0;
    }

    /**
     * @notice Get staked XOM amount at a specific past block from OmniCore
     * @dev ATK-H02 fix: Uses OmniCore.getStakedAt() for checkpoint-based
     *      snapshot. Returns 0 if getStakedAt() is not available or reverts.
     *      The previous fallback to current staking amount was REMOVED because
     *      it enabled vote inflation: an attacker could stake XOM after a
     *      proposal's snapshot block and still have their current (post-snapshot)
     *      stake counted as voting power. Without historical snapshots, the
     *      only safe default is zero.
     * @param account Address to query
     * @param blockNumber Block number to query
     * @return amount Staked XOM amount at the given block (0 if unavailable)
     */
    function _getStakedAmountAt(
        address account,
        uint256 blockNumber
    ) internal view returns (uint256 amount) {
        // Try snapshot-based query (OmniCore with checkpoints)
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = omniCore.staticcall(
            abi.encodeWithSignature(
                "getStakedAt(address,uint256)",
                account,
                blockNumber
            )
        );

        if (success && data.length > 0) {
            return abi.decode(data, (uint256));
        }

        // ATK-H02: No fallback to current balance — prevents
        // post-snapshot stake inflation from inflating vote weight
        return 0;
    }

    /**
     * @notice Compute the timelock operation ID for a proposal
     * @dev Matches TimelockController.hashOperationBatch() computation
     * @param proposalId Proposal to compute ID for
     * @return Timelock operation bytes32 ID
     */
    function _getTimelockId(
        uint256 proposalId
    ) internal view returns (bytes32) {
        ProposalActions storage actions = _proposalActions[proposalId];
        bytes32 salt = keccak256(
            abi.encodePacked("OmniGov", proposalId)
        );

        return keccak256(abi.encode(
            actions.targets,
            actions.values,
            actions.calldatas,
            bytes32(0), // no predecessor
            salt
        ));
    }

    // =========================================================================
    // ERC2771Context Overrides (resolve diamond inheritance)
    // =========================================================================

    /**
     * @notice Resolve _msgSender between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Returns the original user address when called through the
     *      trusted forwarder. Used by user-facing functions (propose,
     *      castVote, cancel) to identify the actual user.
     * @return The original transaction signer when relayed, or
     *         msg.sender when direct
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
     * @notice Resolve _msgData between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Strips the appended sender address from calldata when
     *      relayed
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
     * @notice Resolve _contextSuffixLength between
     *         ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev Returns 20 (address length) for ERC2771 context suffix
     *      stripping
     * @return The number of bytes appended to calldata by the
     *         forwarder (20)
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
/* solhint-enable max-states-count, ordering */

