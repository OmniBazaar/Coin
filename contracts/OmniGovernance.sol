// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OmniCore} from "./OmniCore.sol";

/**
 * @title OmniGovernance
 * @author OmniCoin Development Team
 * @notice Ultra-lean governance contract for on-chain voting only
 * @dev Minimal implementation - proposal details stored off-chain
 */
contract OmniGovernance is ReentrancyGuard {
    // Type declarations
    /// @notice Vote options
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    /// @notice Minimal proposal data
    struct Proposal {
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bytes32 proposalHash; // Hash of off-chain proposal details
        bool executed;
        bool canceled;
    }

    // Constants
    /// @notice Service identifier for OmniCoin token
    bytes32 public constant OMNICOIN_SERVICE = keccak256("OMNICOIN");
    
    /// @notice Default voting period (3 days)
    uint256 public constant VOTING_PERIOD = 3 days;
    
    /// @notice Minimum voting power to create proposal (10k tokens)
    uint256 public constant PROPOSAL_THRESHOLD = 10000e18;
    
    /// @notice Quorum requirement (4% of total supply)
    uint256 public constant QUORUM_PERCENTAGE = 400; // basis points

    // State variables
    /// @notice Core contract reference
    OmniCore public immutable CORE;
    
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
    /// @param startTime Voting start timestamp
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

    /**
     * @notice Initialize governance with core contract
     * @param _core Address of OmniCore contract
     */
    constructor(address _core) {
        CORE = OmniCore(_core);
    }

    /**
     * @notice Create a new proposal
     * @dev Proposal details stored off-chain, only hash on-chain
     * @param proposalHash Hash of off-chain proposal data
     * @return proposalId Unique proposal identifier
     */
    function propose(bytes32 proposalHash) external nonReentrant returns (uint256 proposalId) {
        // Get OmniCoin token from core
        address tokenAddress = CORE.getService(OMNICOIN_SERVICE);
        IERC20 token = IERC20(tokenAddress);
        
        // Check proposer has sufficient tokens
        if (token.balanceOf(msg.sender) < PROPOSAL_THRESHOLD) {
            revert InsufficientBalance();
        }
        
        // Create proposal
        proposalId = ++proposalCount;
        uint256 startTime = block.timestamp; // solhint-disable-line not-rely-on-time
        uint256 endTime = startTime + VOTING_PERIOD;
        
        proposals[proposalId] = Proposal({
            startTime: startTime,
            endTime: endTime,
            forVotes: 0,
            againstVotes: 0,
            abstainVotes: 0,
            proposalHash: proposalHash,
            executed: false,
            canceled: false
        });
        
        emit ProposalCreated(proposalId, msg.sender, proposalHash, startTime, endTime);
    }

    /**
     * @notice Cast a vote on a proposal
     * @dev Voting power based on token balance at proposal creation
     * @param proposalId Proposal to vote on
     * @param support Vote type (0=against, 1=for, 2=abstain)
     */
    function vote(uint256 proposalId, uint8 support) external nonReentrant {
        // Validate inputs
        _validateProposalActive(proposalId);
        _validateNotVoted(proposalId);
        
        // Get voting weight
        uint256 weight = _getVotingWeight();
        
        // Record and count vote
        _recordVote(proposalId, msg.sender, support, weight);
    }
    
    /**
     * @notice Validate proposal is active
     * @param proposalId Proposal to check
     */
    function _validateProposalActive(uint256 proposalId) private view {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.startTime == 0 || proposal.canceled) {
            revert ProposalNotActive();
        }
        
        uint256 currentTime = block.timestamp; // solhint-disable-line not-rely-on-time
        if (currentTime < proposal.startTime || currentTime > proposal.endTime) {
            revert ProposalNotActive();
        }
    }
    
    /**
     * @notice Validate user hasn't voted
     * @param proposalId Proposal to check
     */
    function _validateNotVoted(uint256 proposalId) private view {
        if (hasVoted[proposalId][msg.sender]) {
            revert AlreadyVoted();
        }
    }
    
    /**
     * @notice Get voting weight for caller
     * @return weight Voting power
     */
    function _getVotingWeight() private view returns (uint256 weight) {
        address tokenAddress = CORE.getService(OMNICOIN_SERVICE);
        weight = IERC20(tokenAddress).balanceOf(msg.sender);
        
        if (weight == 0) {
            revert InsufficientBalance();
        }
    }
    
    /**
     * @notice Record vote and update counts
     * @param proposalId Proposal being voted on
     * @param voter Address casting vote
     * @param support Vote type
     * @param weight Voting power
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
     * @notice Execute a passed proposal
     * @dev Actual execution happens off-chain via validators
     * @param proposalId Proposal to execute
     */
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        // Validate proposal state
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalNotActive();
        if (block.timestamp < proposal.endTime + 1) revert VotingNotEnded(); // solhint-disable-line not-rely-on-time
        
        // Check if proposal passed
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        if (proposal.forVotes < proposal.againstVotes + 1) {
            revert ProposalNotPassed();
        }
        
        // Check quorum
        address tokenAddress = CORE.getService(OMNICOIN_SERVICE);
        uint256 totalSupply = IERC20(tokenAddress).totalSupply();
        uint256 quorumVotes = (totalSupply * QUORUM_PERCENTAGE) / 10000;
        
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
        if (!CORE.hasRole(CORE.AVALANCHE_VALIDATOR_ROLE(), msg.sender)) {
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
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /**
     * @notice Check if voting is active for a proposal
     * @param proposalId Proposal identifier
     * @return active Whether voting is currently active
     */
    function isVotingActive(uint256 proposalId) external view returns (bool active) {
        Proposal memory proposal = proposals[proposalId];
        uint256 currentTime = block.timestamp; // solhint-disable-line not-rely-on-time
        
        return !proposal.canceled && 
               !proposal.executed && 
               currentTime >= proposal.startTime && 
               currentTime <= proposal.endTime;
    }

    /**
     * @notice Get current voting results
     * @param proposalId Proposal identifier
     * @return forVotes Number of for votes
     * @return againstVotes Number of against votes
     * @return abstainVotes Number of abstain votes
     */
    function getVoteResults(uint256 proposalId) external view returns (
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes
    ) {
        Proposal memory proposal = proposals[proposalId];
        return (proposal.forVotes, proposal.againstVotes, proposal.abstainVotes);
    }
}