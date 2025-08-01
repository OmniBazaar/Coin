// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniCoinGovernor
 * @author OmniCoin Development Team
 * @notice Governance contract for OmniCoin protocol
 * @dev Implements a simple governance system with proposals and voting
 */
contract OmniCoinGovernor is RegistryAware, Ownable, ReentrancyGuard {
    // Enums
    enum VoteType {
        Against,
        For,
        Abstain
    }
    
    struct Proposal {
        uint256 id;                             // 32 bytes
        uint256 startTime;                      // 32 bytes
        uint256 endTime;                        // 32 bytes
        uint256 forVotes;                       // 32 bytes
        uint256 againstVotes;                   // 32 bytes
        uint256 abstainVotes;                   // 32 bytes
        address proposer;                       // 20 bytes
        bool executed;                          // 1 byte (packed with address)
        bool canceled;                          // 1 byte (packed with address)
        string description;                     // 32 bytes (dynamic)
        mapping(address => bool) hasVoted;      // separate slot
        mapping(address => uint256) votes;      // separate slot
        // Total: ~8 storage slots (optimized packing)
    }
    
    struct ProposalAction {
        address target;
        uint256 value;
        bytes data;
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice OmniCoin token contract (deprecated, use registry)
    IERC20 public token;
    /// @notice Whether to use private token for governance
    bool public usePrivateToken;
    /// @notice Total number of proposals created
    uint256 public proposalCount;
    /// @notice Duration of voting period
    uint256 public votingPeriod;
    /// @notice Minimum tokens required to create a proposal
    uint256 public proposalThreshold;
    /// @notice Minimum votes required for proposal to pass
    uint256 public quorum;

    /// @notice Mapping from proposal ID to proposal data
    mapping(uint256 => Proposal) public proposals;
    /// @notice Mapping from proposal ID to proposal actions
    mapping(uint256 => ProposalAction[]) public proposalActions;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================

    error InsufficientBalance();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalNotPending();
    error AlreadyVoted();
    error InvalidVoteType();
    error ProposalNotPassed();
    error ProposalAlreadyExecuted();
    error InvalidVotingPeriod();
    error InvalidProposalThreshold();
    error InvalidQuorum();

    /**
     * @notice Emitted when a proposal is created
     * @param proposalId The proposal ID
     * @param proposer The proposal creator
     * @param description The proposal description
     * @param startTime When voting starts
     * @param endTime When voting ends
     */
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 indexed startTime,
        uint256 endTime
    );
    
    /**
     * @notice Emitted when a proposal is canceled
     * @param proposalId The proposal ID
     */
    event ProposalCanceled(uint256 indexed proposalId);
    
    /**
     * @notice Emitted when a proposal is executed
     * @param proposalId The proposal ID
     */
    event ProposalExecuted(uint256 indexed proposalId);
    
    /**
     * @notice Emitted when a vote is cast
     * @param proposalId The proposal ID
     * @param voter The voter address
     * @param support The vote type (0=against, 1=for, 2=abstain)
     * @param weight The vote weight
     */
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        uint256 indexed support,
        uint256 weight
    );
    
    /**
     * @notice Emitted when voting period is updated
     * @param oldPeriod Previous voting period
     * @param newPeriod New voting period
     */
    event VotingPeriodUpdated(uint256 indexed oldPeriod, uint256 indexed newPeriod);
    
    /**
     * @notice Emitted when proposal threshold is updated
     * @param oldThreshold Previous threshold
     * @param newThreshold New threshold
     */
    event ProposalThresholdUpdated(uint256 indexed oldThreshold, uint256 indexed newThreshold);
    
    /**
     * @notice Emitted when quorum is updated
     * @param oldQuorum Previous quorum
     * @param newQuorum New quorum
     */
    event QuorumUpdated(uint256 indexed oldQuorum, uint256 indexed newQuorum);

    /**
     * @notice Initialize the governor contract
     * @param _registry Registry contract address
     * @param _token The governance token address (deprecated, use registry)
     * @param initialOwner The initial owner address
     */
    constructor(address _registry, address _token, address initialOwner) 
        RegistryAware(_registry) 
        Ownable(initialOwner) {
        token = IERC20(_token);
        votingPeriod = 3 days;
        proposalThreshold = 1000 * 10 ** 6; // 1000 tokens (6 decimals)
        quorum = 10000 * 10 ** 6; // 10000 tokens (6 decimals)
        usePrivateToken = false; // Default to public token for governance
    }

    /**
     * @notice Create a new proposal
     * @param description The proposal description
     * @param actions The actions to execute if proposal passes
     * @return The proposal ID
     */
    function propose(
        string calldata description,
        ProposalAction[] calldata actions
    ) external nonReentrant returns (uint256) {
        address governanceToken = getGovernanceToken();
        if (IERC20(governanceToken).balanceOf(msg.sender) < proposalThreshold) 
            revert InsufficientBalance();

        uint256 proposalId = ++proposalCount;
        uint256 startTime = block.timestamp; // solhint-disable-line not-rely-on-time
        uint256 endTime = startTime + votingPeriod;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.startTime = startTime;
        proposal.endTime = endTime;

        for (uint256 i = 0; i < actions.length; ++i) {
            proposalActions[proposalId].push(actions[i]);
        }

        emit ProposalCreated(
            proposalId,
            msg.sender,
            description,
            startTime,
            endTime
        );

        return proposalId;
    }

    /**
     * @notice Cancel a proposal
     * @param proposalId The proposal ID to cancel
     */
    function cancel(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (msg.sender != proposal.proposer) revert ProposalNotFound();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalNotPending();

        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    /**
     * @notice Execute a passed proposal
     * @param proposalId The proposal ID to execute
     */
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalNotPending();
        if (block.timestamp < proposal.endTime) revert ProposalNotActive(); // solhint-disable-line not-rely-on-time
        if (proposal.forVotes < proposal.againstVotes + 1) revert ProposalNotPassed();
        if (proposal.forVotes + proposal.againstVotes + proposal.abstainVotes < quorum) 
            revert ProposalNotPassed();

        proposal.executed = true;

        ProposalAction[] storage actions = proposalActions[proposalId];
        for (uint256 i = 0; i < actions.length; ++i) {
            (bool success, ) = actions[i].target.call{value: actions[i].value}(
                actions[i].data
            );
            if (!success) revert ProposalNotPassed();
        }

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Cast a vote on a proposal
     * @param proposalId The proposal ID
     * @param support The vote type (0=against, 1=for, 2=abstain)
     */
    function castVote(
        uint256 proposalId,
        VoteType support
    ) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.canceled) revert ProposalNotPending();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < proposal.startTime || block.timestamp > proposal.endTime) 
            revert ProposalNotActive();
        if (proposal.hasVoted[msg.sender]) revert AlreadyVoted();

        address governanceToken = getGovernanceToken();
        uint256 weight = IERC20(governanceToken).balanceOf(msg.sender);
        if (weight == 0) revert InsufficientBalance();

        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = weight;

        if (support == VoteType.For) {
            proposal.forVotes += weight;
        } else if (support == VoteType.Against) {
            proposal.againstVotes += weight;
        } else if (support == VoteType.Abstain) {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, uint256(support), weight);
    }

    /**
     * @notice Set the voting period duration
     * @param _period The new voting period in seconds
     */
    function setVotingPeriod(uint256 _period) external onlyOwner {
        emit VotingPeriodUpdated(votingPeriod, _period);
        votingPeriod = _period;
    }

    /**
     * @notice Set the proposal creation threshold
     * @param _threshold The new threshold in tokens
     */
    function setProposalThreshold(uint256 _threshold) external onlyOwner {
        emit ProposalThresholdUpdated(proposalThreshold, _threshold);
        proposalThreshold = _threshold;
    }

    /**
     * @notice Set the quorum requirement
     * @param _quorum The new quorum in tokens
     */
    function setQuorum(uint256 _quorum) external onlyOwner {
        emit QuorumUpdated(quorum, _quorum);
        quorum = _quorum;
    }

    /**
     * @notice Get proposal details
     * @param proposalId The proposal ID
     * @return id The proposal ID
     * @return proposer The proposal creator
     * @return description The proposal description
     * @return startTime When voting started
     * @return endTime When voting ends
     * @return forVotes Total votes for
     * @return againstVotes Total votes against
     * @return abstainVotes Total abstain votes
     * @return executed Whether proposal was executed
     * @return canceled Whether proposal was canceled
     */
    function getProposal(
        uint256 proposalId
    )
        external
        view
        returns (
            uint256 id,
            address proposer,
            string memory description,
            uint256 startTime,
            uint256 endTime,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            bool executed,
            bool canceled
        )
    {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.description,
            proposal.startTime,
            proposal.endTime,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.executed,
            proposal.canceled
        );
    }

    /**
     * @notice Get a specific action from a proposal
     * @param proposalId The proposal ID
     * @param index The action index
     * @return target The target address
     * @return data The call data
     * @return value The ETH value
     */
    function getProposalAction(
        uint256 proposalId,
        uint256 index
    ) external view returns (address target, bytes memory data, uint256 value) {
        ProposalAction storage action = proposalActions[proposalId][index];
        return (action.target, action.data, action.value);
    }

    /**
     * @notice Get the number of actions in a proposal
     * @param proposalId The proposal ID
     * @return The number of actions
     */
    function getProposalActionCount(
        uint256 proposalId
    ) external view returns (uint256) {
        return proposalActions[proposalId].length;
    }

    /**
     * @notice Check if an address has voted on a proposal
     * @param proposalId The proposal ID
     * @param voter The voter address
     * @return Whether the address has voted
     */
    function hasVoted(
        uint256 proposalId,
        address voter
    ) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }

    /**
     * @notice Get the vote weight for a voter on a proposal
     * @param proposalId The proposal ID
     * @param voter The voter address
     * @return The vote weight
     */
    function getVotes(
        uint256 proposalId,
        address voter
    ) external view returns (uint256) {
        return proposals[proposalId].votes[voter];
    }
    
    /**
     * @notice Get the governance token address
     * @dev Returns either OmniCoin or PrivateOmniCoin based on configuration
     * @return governanceToken The token used for governance
     */
    function getGovernanceToken() public view returns (address governanceToken) {
        if (usePrivateToken) {
            governanceToken = _getContract(REGISTRY.PRIVATE_OMNICOIN());
        } else {
            governanceToken = _getContract(REGISTRY.OMNICOIN());
        }
        
        // Fallback to legacy token if registry not configured
        if (governanceToken == address(0) && address(token) != address(0)) {
            governanceToken = address(token);
        }
    }
    
    /**
     * @notice Set whether to use private token for governance
     * @param _usePrivate Whether to use PrivateOmniCoin for voting
     */
    function setUsePrivateToken(bool _usePrivate) external onlyOwner {
        usePrivateToken = _usePrivate;
    }
}
