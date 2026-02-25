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
    EIP712Upgradeable
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

    /// @notice Admin role for governance upgrades (held by timelock)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /* solhint-disable gas-small-strings */
    /// @notice EIP-712 typehash for vote-by-signature
    bytes32 public constant VOTE_TYPEHASH = keccak256(
        "Vote(uint256 proposalId,uint8 support,uint256 nonce)"
    );
    /* solhint-enable gas-small-strings */

    /// @notice Delay between proposal creation and voting start (1 day)
    uint256 public constant VOTING_DELAY = 1 days;

    /// @notice Voting period duration (5 days)
    uint256 public constant VOTING_PERIOD = 5 days;

    /// @notice Minimum voting power to create proposal (10,000 XOM)
    uint256 public constant PROPOSAL_THRESHOLD = 10_000e18;

    /// @notice Quorum: 4% of total supply at snapshot (400 basis points)
    uint256 public constant QUORUM_BPS = 400;

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

    /// @notice Storage gap for future upgrades
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

    // =========================================================================
    // Constructor & Initializer
    // =========================================================================

    /**
     * @notice Disable initializers on implementation contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
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
        _grantRole(ADMIN_ROLE, admin);

        omniCoin = IVotes(_omniCoin);
        omniCoinERC20 = IERC20(_omniCoin);
        omniCore = _omniCore;
        timelock = _timelock;
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

        uint256 votingPower = getVotingPower(msg.sender);
        if (votingPower < PROPOSAL_THRESHOLD) {
            revert InsufficientVotingPower();
        }

        proposalId = ++proposalCount;

        // Snapshot for flash-loan protection
        // solhint-disable-next-line not-rely-on-time
        uint256 voteStart = block.timestamp + VOTING_DELAY;
        uint256 voteEnd = voteStart + VOTING_PERIOD;

        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            proposalType: proposalType,
            descriptionHash: keccak256(bytes(description)),
            snapshotBlock: block.number,
            snapshotTotalSupply: omniCoinERC20.totalSupply(),
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
            proposalId, msg.sender, proposalType, voteStart
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
        _castVote(proposalId, msg.sender, support);
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
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.executed || proposal.cancelled) {
            revert InvalidProposalState(
                state(proposalId), ProposalState.Pending
            );
        }

        // Only proposer or admin can cancel
        bool isProposer = msg.sender == proposal.proposer;
        bool isAdmin = hasRole(ADMIN_ROLE, msg.sender);

        if (!isProposer && !isAdmin) {
            revert InvalidProposalState(
                state(proposalId), ProposalState.Pending
            );
        }

        proposal.cancelled = true;

        // If queued, also cancel in timelock
        if (proposal.queued) {
            bytes32 timelockId = _getTimelockId(proposalId);
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = timelock.call(
                abi.encodeWithSignature("cancel(bytes32)", timelockId)
            );
            // If timelock cancel fails (already executed/not pending),
            // the governance cancel still proceeds
            success; // silence unused warning
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

        if (proposal.voteStart == 0) {
            return ProposalState.Pending; // non-existent
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
     * @notice Get voting power for an address (delegated + staked)
     * @dev Combines ERC20Votes delegation power with OmniCore staking.
     *      Uses current values (1-day voting delay provides flash-loan
     *      protection). Future upgrade can use snapshot-based staking.
     * @param account Address to query
     * @return Total voting power
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
     * @dev Uses ERC20Votes.getPastVotes for delegated power.
     *      Uses current staking amount (snapshot staking in future upgrade).
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
        return (proposals[proposalId].snapshotTotalSupply * QUORUM_BPS)
            / BASIS_POINTS;
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
    function ossify() external onlyRole(ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
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
    ) internal view override onlyRole(ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        // newImplementation validated by UUPSUpgradeable
        (newImplementation);
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

        // Use snapshot block for delegated power, current for staked
        Proposal storage proposal = proposals[proposalId];
        uint256 weight = getVotingPowerAt(
            voter, proposal.snapshotBlock
        );
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
     * @param proposal Proposal to check
     * @return True if proposal passed
     */
    function _proposalPassed(
        Proposal storage proposal
    ) internal view returns (bool) {
        // Strict majority: forVotes > againstVotes
        // solhint-disable-next-line gas-strict-inequalities
        if (proposal.forVotes <= proposal.againstVotes) return false;

        // Quorum: total votes >= 4% of snapshotted supply
        uint256 quorumVotes =
            (proposal.snapshotTotalSupply * QUORUM_BPS) / BASIS_POINTS;
        uint256 totalVotes = proposal.forVotes +
            proposal.againstVotes +
            proposal.abstainVotes;

        return totalVotes > quorumVotes - 1;
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
     * @dev Uses OmniCore.getStakedAt() for checkpoint-based snapshot.
     *      Falls back to current staking amount if getStakedAt() is not
     *      available (backward compatibility with older OmniCore versions).
     * @param account Address to query
     * @param blockNumber Block number to query
     * @return amount Staked XOM amount at the given block
     */
    function _getStakedAmountAt(
        address account,
        uint256 blockNumber
    ) internal view returns (uint256 amount) {
        // Try snapshot-based query first (OmniCore with checkpoints)
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

        // Fallback to current amount if getStakedAt not available
        return _getStakedAmount(account);
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
}
/* solhint-enable max-states-count, ordering */

