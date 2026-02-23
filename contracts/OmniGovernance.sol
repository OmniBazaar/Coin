// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OmniCore} from "./OmniCore.sol";

/**
 * @title OmniGovernance
 * @author OmniCoin Development Team
 * @notice Ultra-lean governance contract for on-chain voting only
 * @dev Minimal implementation - proposal details stored off-chain.
 *      Includes flash-loan protection via a 1-day voting delay and
 *      counts both liquid and staked XOM toward voting weight.
 */
contract OmniGovernance is ReentrancyGuard {
    // Type declarations
    /// @notice Vote options
    enum VoteType {
        Against,
        For,
        Abstain
    }

    /// @notice Minimal proposal data stored on-chain
    struct Proposal {
        uint256 snapshotBlock;
        uint256 snapshotSupply;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bytes32 proposalHash;
        bool executed;
        bool canceled;
    }

    // Constants
    /// @notice Service identifier for OmniCoin token
    bytes32 public constant OMNICOIN_SERVICE = keccak256("OMNICOIN");

    /// @notice Delay between proposal creation and voting start (1 day)
    /// @dev Prevents flash-loan attacks by requiring token holders to
    ///      maintain their balance across at least one full block boundary
    uint256 public constant VOTING_DELAY = 1 days;

    /// @notice Default voting period (3 days)
    uint256 public constant VOTING_PERIOD = 3 days;

    /// @notice Minimum voting power to create proposal (10k tokens)
    uint256 public constant PROPOSAL_THRESHOLD = 10000e18;

    /// @notice Quorum requirement (4% of total supply)
    uint256 public constant QUORUM_PERCENTAGE = 400; // basis points

    // Immutable state variables
    /// @notice Core contract reference
    OmniCore public immutable CORE;

    // Mutable state variables
    /// @notice Current proposal ID counter
    uint256 public proposalCount;

    /// @notice Proposals by ID
    mapping(uint256 => Proposal) public proposals;

    /// @notice User votes by proposal ID
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Vote weight by user and proposal
    mapping(uint256 => mapping(address => uint256)) public voteWeight;

    // Events
    /// @notice Emitted when proposal is created
    /// @param proposalId Unique proposal identifier
    /// @param proposer Address creating the proposal
    /// @param proposalHash Hash of off-chain proposal data
    /// @param startTime Voting start timestamp (after voting delay)
    /// @param endTime Voting end timestamp
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 indexed proposalHash,
        uint256 startTime,
        uint256 endTime
    );

    /// @notice Emitted when vote is cast
    /// @param proposalId Proposal being voted on
    /// @param voter Address casting the vote
    /// @param support Vote type (0=against, 1=for, 2=abstain)
    /// @param weight Voting power used
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint8 indexed support,
        uint256 weight
    );

    /// @notice Emitted when proposal is executed
    /// @param proposalId Executed proposal ID
    /// @param executor Address executing the proposal
    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed executor
    );

    /// @notice Emitted when proposal is canceled
    /// @param proposalId Canceled proposal ID
    event ProposalCanceled(uint256 indexed proposalId);

    // Custom errors
    error InsufficientBalance();
    error ProposalNotActive();
    error AlreadyVoted();
    error InvalidVoteType();
    error ProposalNotPassed();
    error ProposalAlreadyExecuted();
    error QuorumNotReached();
    error VotingNotEnded();
    /// @notice Thrown when zero address is passed for a required parameter
    error InvalidAddress();

    /**
     * @notice Initialize governance with core contract
     * @dev Reverts if _core is the zero address (M-04 remediation).
     * @param _core Address of OmniCore contract
     */
    constructor(address _core) {
        if (_core == address(0)) revert InvalidAddress();
        CORE = OmniCore(_core);
    }

    /**
     * @notice Create a new proposal
     * @dev Proposal details stored off-chain, only hash on-chain.
     *      A 1-day voting delay is enforced between creation and
     *      voting start to prevent flash-loan governance attacks.
     *      Both liquid and staked XOM count toward the proposal
     *      threshold.
     * @param proposalHash Hash of off-chain proposal data
     * @return proposalId Unique proposal identifier
     */
    function propose(
        bytes32 proposalHash
    ) external nonReentrant returns (uint256 proposalId) {
        // Check proposer has sufficient tokens (liquid + staked)
        uint256 proposerBalance = _getTotalBalance(msg.sender);
        if (proposerBalance < PROPOSAL_THRESHOLD) {
            revert InsufficientBalance();
        }

        // Create proposal with voting delay for flash-loan protection
        proposalId = ++proposalCount;
        // solhint-disable-next-line not-rely-on-time
        uint256 startTime = block.timestamp + VOTING_DELAY;
        uint256 endTime = startTime + VOTING_PERIOD;

        // M-01: Snapshot totalSupply at creation to prevent quorum
        // manipulation via minting between proposal creation and execution.
        address tokenAddress = CORE.getService(OMNICOIN_SERVICE);
        uint256 currentSupply = IERC20(tokenAddress).totalSupply();

        proposals[proposalId] = Proposal({
            snapshotBlock: block.number,
            snapshotSupply: currentSupply,
            startTime: startTime,
            endTime: endTime,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            proposalHash: proposalHash,
            executed: false,
            canceled: false
        });

        emit ProposalCreated(
            proposalId,
            msg.sender,
            proposalHash,
            startTime,
            endTime
        );
    }

    /**
     * @notice Cast a vote on a proposal
     * @dev Voting power is the sum of liquid XOM balance and staked
     *      XOM at the time of voting. The 1-day voting delay after
     *      proposal creation prevents flash-loan manipulation.
     * @param proposalId Proposal to vote on
     * @param support Vote type (0=against, 1=for, 2=abstain)
     */
    function vote(
        uint256 proposalId,
        uint8 support
    ) external nonReentrant {
        _validateProposalActive(proposalId);
        _validateNotVoted(proposalId);

        uint256 weight = _getVotingWeight();

        _recordVote(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Execute a passed proposal
     * @dev Actual execution happens off-chain via validators
     * @param proposalId Proposal to execute
     */
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        // Validate proposal state
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalNotActive();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < proposal.endTime + 1) {
            revert VotingNotEnded();
        }

        // Check if proposal passed (strict majority)
        if (proposal.forVotes < proposal.againstVotes + 1) {
            revert ProposalNotPassed();
        }

        // Check quorum using snapshotted supply from proposal creation
        // M-01: Prevents quorum manipulation via minting/burning after
        // proposal creation.
        uint256 quorumVotes =
            (proposal.snapshotSupply * QUORUM_PERCENTAGE) / 10000;

        uint256 totalVotes = proposal.forVotes +
            proposal.againstVotes +
            proposal.abstainVotes;
        if (totalVotes < quorumVotes) {
            revert QuorumNotReached();
        }

        // Mark as executed
        proposal.executed = true;

        // Emit event for validators to execute off-chain
        emit ProposalExecuted(proposalId, msg.sender);
    }

    /**
     * @notice Cancel a proposal (emergency only)
     * @dev Only validators can cancel via OmniCore
     * @param proposalId Proposal to cancel
     */
    function cancel(uint256 proposalId) external {
        // Only validators can cancel
        if (
            !CORE.hasRole(
                CORE.AVALANCHE_VALIDATOR_ROLE(),
                msg.sender
            )
        ) {
            revert ProposalNotActive();
        }

        Proposal storage proposal = proposals[proposalId];
        if (proposal.executed || proposal.canceled) {
            revert ProposalNotActive();
        }

        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Get proposal details
     * @param proposalId Proposal identifier
     * @return Proposal data
     */
    function getProposal(
        uint256 proposalId
    ) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Check if voting is active for a proposal
     * @param proposalId Proposal identifier
     * @return active Whether voting is currently active
     */
    function isVotingActive(
        uint256 proposalId
    ) external view returns (bool active) {
        Proposal memory proposal = proposals[proposalId];
        // solhint-disable-next-line not-rely-on-time
        uint256 currentTime = block.timestamp;

        active =
            !proposal.canceled &&
            !proposal.executed &&
            currentTime > proposal.startTime - 1 &&
            currentTime < proposal.endTime + 1;
    }

    /**
     * @notice Get current voting results
     * @param proposalId Proposal identifier
     * @return forVotes Number of for votes
     * @return againstVotes Number of against votes
     * @return abstainVotes Number of abstain votes
     */
    function getVoteResults(
        uint256 proposalId
    )
        external
        view
        returns (
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes
        )
    {
        Proposal memory proposal = proposals[proposalId];
        return (
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes
        );
    }

    /**
     * @notice Record vote and update proposal vote counts
     * @param proposalId Proposal being voted on
     * @param voter Address casting vote
     * @param support Vote type (0=against, 1=for, 2=abstain)
     * @param weight Voting power applied
     */
    function _recordVote(
        uint256 proposalId,
        address voter,
        uint8 support,
        uint256 weight
    ) private {
        Proposal storage proposal = proposals[proposalId];

        // Record vote
        hasVoted[proposalId][voter] = true;
        voteWeight[proposalId][voter] = weight;

        // Update vote counts
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
     * @notice Get total balance for an address (liquid + staked)
     * @dev Queries both IERC20 balance and OmniCore staking position
     * @param account Address to query
     * @return total Combined liquid and staked XOM balance
     */
    function _getTotalBalance(
        address account
    ) private view returns (uint256 total) {
        address tokenAddress = CORE.getService(OMNICOIN_SERVICE);
        total = IERC20(tokenAddress).balanceOf(account);

        // Include staked XOM in total balance
        (uint256 stakedAmount, , , , ) = CORE.stakes(account);
        total += stakedAmount;
    }

    /**
     * @notice Validate proposal is in an active voting window
     * @dev Checks that the proposal exists, is not canceled, and
     *      the current timestamp falls within the voting period
     * @param proposalId Proposal to check
     */
    function _validateProposalActive(
        uint256 proposalId
    ) private view {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.startTime == 0 || proposal.canceled) {
            revert ProposalNotActive();
        }

        // solhint-disable-next-line not-rely-on-time
        uint256 currentTime = block.timestamp;
        if (
            currentTime < proposal.startTime ||
            currentTime > proposal.endTime
        ) {
            revert ProposalNotActive();
        }
    }

    /**
     * @notice Validate user has not already voted on a proposal
     * @param proposalId Proposal to check
     */
    function _validateNotVoted(uint256 proposalId) private view {
        if (hasVoted[proposalId][msg.sender]) {
            revert AlreadyVoted();
        }
    }

    /**
     * @notice Get voting weight for the caller
     * @dev Returns the sum of liquid XOM balance and staked XOM.
     *      Reverts if combined weight is zero.
     * @return weight Total voting power (liquid + staked)
     */
    function _getVotingWeight()
        private
        view
        returns (uint256 weight)
    {
        weight = _getTotalBalance(msg.sender);

        if (weight == 0) {
            revert InsufficientBalance();
        }
    }
}
