// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReputationSystemBase} from "./ReputationSystemBase.sol";
import {ITrustSystem} from "./interfaces/IReputationSystem.sol";
import {MpcCore, gtBool, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title OmniCoinTrustSystem
 * @author OmniCoin Development Team
 * @notice Trust system for DPoS voting and COTI PoT integration
 * @dev Trust system module for DPoS voting and COTI Proof of Trust integration
 * 
 * Features:
 * - Delegated Proof of Stake (DPoS) voting
 * - COTI Proof of Trust score integration
 * - Privacy-preserving vote counts
 * - Vote delegation and withdrawal
 */
contract OmniCoinTrustSystem is ReputationSystemBase, ITrustSystem {
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct TrustData {
        gtUint64 encryptedDPoSVotes;        // Private: total DPoS votes received
        ctUint64 userEncryptedVotes;        // Private: votes encrypted for user viewing
        uint256 publicVoterCount;           // Public: number of unique voters
        uint256 cotiProofOfTrustScore;      // Public: COTI PoT score (if available)
        bool useCotiPoT;                    // Public: whether to use COTI PoT or DPoS
        uint256 lastTrustUpdate;            // Public: last trust update timestamp
        uint256 lastDecayCalculation;       // Last time decay was calculated
    }
    
    struct Vote {
        gtUint64 encryptedAmount;           // Private: vote amount
        uint256 timestamp;                  // When vote was cast
        bool isActive;                      // Whether vote is still active
    }
    
    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Minimum vote amount (100 tokens)
    uint256 public constant MIN_VOTE_AMOUNT = 100 * 10**6;
    /// @notice Vote decay period (90 days)
    uint256 public constant VOTE_DECAY_PERIOD = 90 days;
    /// @notice Maximum delegations per voter
    uint256 public constant MAX_DELEGATIONS = 10;
    
    // Role constants
    /// @notice Trust manager role identifier
    bytes32 public constant TRUST_MANAGER_ROLE = keccak256("TRUST_MANAGER_ROLE");
    /// @notice COTI oracle role identifier
    bytes32 public constant COTI_ORACLE_ROLE = keccak256("COTI_ORACLE_ROLE");
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidVoter();
    error InvalidCandidate();
    error InsufficientVoteAmount();
    error AlreadyVoted();
    error ExceedsMaxDelegations();
    error VoteNotFound();
    error UnauthorizedAccess();
    error ArrayLengthMismatch();
    error CotiNotEnabled();
    error InvalidCotiScore();
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice User trust data
    mapping(address => TrustData) public trustData; // solhint-disable-line ordering
    
    /// @notice Vote records: voter => candidate => vote record
    mapping(address => mapping(address => Vote)) public voteRecords;
    
    /// @notice Delegation count per voter
    mapping(address => uint256) public voterDelegationCount;
    
    /// @notice List of candidates a voter has voted for
    mapping(address => address[]) public voterCandidates;
    
    /// @notice Total encrypted votes in the system
    gtUint64 public totalSystemVotes;
    
    /// @notice Whether COTI PoT is globally enabled
    bool public cotiPoTEnabled;
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the trust system contract
     * @param _admin Admin address
     * @param _reputationCore Reputation core contract address
     */
    constructor(
        address _admin,
        address _reputationCore
    ) ReputationSystemBase(_admin, _reputationCore) {
        _grantRole(TRUST_MANAGER_ROLE, _admin);
        
        // Set default weight for trust component
        componentWeights[COMPONENT_TRUST_SCORE] = 2000; // 20%
        
        // Initialize total votes
        if (isMpcAvailable) {
            totalSystemVotes = MpcCore.setPublic64(0);
        } else {
            totalSystemVotes = gtUint64.wrap(0);
        }
    }
    
    // =============================================================================
    // DPOS VOTING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Cast DPoS vote for a candidate with encrypted vote amount
     * @dev Cast DPoS vote for a candidate
     * @param candidate Candidate address
     * @param votes Encrypted vote amount
     */
    function castDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external override whenNotPaused nonReentrant {
        // Validate parameters
        _validateVoteParameters(candidate);
        
        // Validate vote amount
        gtUint64 gtVotes = _validateInput(votes);
        _validateVoteAmount(gtVotes);
        
        Vote storage record = voteRecords[msg.sender][candidate];
        TrustData storage candidateTrust = trustData[candidate];
        
        // Update counts for new votes
        _updateVoteCounts(record, candidateTrust, candidate);
        
        // Apply decay to existing votes before adding new ones
        _applyVoteDecay(candidate);
        
        // Update vote amounts
        _updateVoteAmounts(record, candidateTrust, gtVotes, candidate);
        
        // Update reputation core with trust score
        _updateReputationInCore(candidate, COMPONENT_TRUST_SCORE, votes);
        
        // solhint-disable-next-line not-rely-on-time
        emit DPoSVoteCast(msg.sender, candidate, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Withdraw DPoS vote from a candidate with encrypted amount
     * @dev Withdraw DPoS vote from a candidate
     * @param candidate Candidate address
     * @param votes Encrypted vote amount to withdraw
     */
    function withdrawDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external override whenNotPaused nonReentrant {
        Vote storage record = voteRecords[msg.sender][candidate];
        if (!record.isActive) revert VoteNotFound();
        
        gtUint64 gtVotes = _validateInput(votes);
        TrustData storage candidateTrust = trustData[candidate];
        
        // Apply decay before withdrawal
        _applyVoteDecay(candidate);
        
        // Validate withdrawal amount
        _validateWithdrawalAmount(record, gtVotes);
        
        // Process withdrawal
        _processWithdrawal(record, candidateTrust, gtVotes, candidate);
        
        // Update candidate's total votes
        _updateCandidateVotesAfterWithdrawal(candidateTrust, gtVotes, candidate);
        
        emit DPoSVoteWithdrawn(msg.sender, candidate, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // COTI PROOF OF TRUST INTEGRATION
    // =============================================================================
    
    /**
     * @notice Update COTI Proof of Trust score for a user
     * @dev Update COTI Proof of Trust score
     * @param user User address
     * @param score COTI PoT score
     */
    function updateCotiPoTScore(
        address user,
        uint256 score
    ) external override whenNotPaused onlyRole(COTI_ORACLE_ROLE) {
        if (!cotiPoTEnabled) revert CotiNotEnabled();
        
        TrustData storage userData = trustData[user];
        userData.cotiProofOfTrustScore = score;
        userData.lastTrustUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
        
        // Convert to encrypted format for reputation update
        // Create input type with score embedded in ciphertext
        itUint64 memory encryptedScore = itUint64({
            ciphertext: ctUint64.wrap(uint64(score)),
            signature: new bytes(32)
        });
        
        _updateReputationInCoreMemory(user, COMPONENT_TRUST_SCORE, encryptedScore);
        
        emit CotiPoTScoreUpdated(user, score, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Set whether user uses COTI PoT or DPoS for trust scoring
     * @dev Set whether user uses COTI PoT or DPoS
     * @param user User address
     * @param useCoti Whether to use COTI PoT
     */
    function setUseCotiPoT(
        address user,
        bool useCoti
    ) external override whenNotPaused onlyRole(TRUST_MANAGER_ROLE) {
        if (!cotiPoTEnabled && useCoti) revert CotiNotEnabled();
        
        trustData[user].useCotiPoT = useCoti;
        emit TrustMethodChanged(user, useCoti, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get user's trust score (DPoS or COTI PoT)
     * @dev Get user's trust score (DPoS or COTI PoT)
     * @param user User address to get trust score for
     * @return gtUint64 Encrypted trust score
     */
    function getTrustScore(address user) external override returns (gtUint64) {
        TrustData storage userData = trustData[user];
        
        if (userData.useCotiPoT && cotiPoTEnabled) {
            // Return COTI PoT score as encrypted value
            if (isMpcAvailable) {
                return MpcCore.setPublic64(uint64(userData.cotiProofOfTrustScore));
            } else {
                return gtUint64.wrap(uint64(userData.cotiProofOfTrustScore));
            }
        } else {
            // Return DPoS votes (with decay applied)
            gtUint64 votes = userData.encryptedDPoSVotes;
            // solhint-disable-next-line not-rely-on-time
            uint256 timeSinceUpdate = block.timestamp - userData.lastDecayCalculation;
            
            return _calculateDecayedVotes(votes, timeSinceUpdate);
        }
    }
    
    /**
     * @notice Get voter count for a candidate
     * @dev Get voter count for a candidate
     * @param user Candidate address
     * @return uint256 Number of voters
     */
    function getVoterCount(address user) external view override returns (uint256) {
        return trustData[user].publicVoterCount;
    }
    
    /**
     * @notice Get COTI Proof of Trust score for a user
     * @dev Get COTI Proof of Trust score
     * @param user User address
     * @return uint256 COTI PoT score
     */
    function getCotiProofOfTrustScore(address user) external view override returns (uint256) {
        return trustData[user].cotiProofOfTrustScore;
    }
    
    /**
     * @notice Get user's encrypted votes (only accessible by the user)
     * @dev Get user's encrypted votes (for user viewing)
     * @param user User address
     * @return ctUint64 Encrypted votes for user viewing
     */
    function getUserEncryptedVotes(address user) external view returns (ctUint64) {
        if (msg.sender != user) revert UnauthorizedAccess();
        return trustData[user].userEncryptedVotes;
    }
    
    /**
     * @notice Get vote record details for a voter-candidate pair
     * @dev Get vote record details
     * @param voter Voter address
     * @param candidate Candidate address
     * @return isActive Whether the vote is active
     * @return timestamp When the vote was cast
     * @return encryptedAmount Encrypted vote amount
     */
    function getVote(
        address voter,
        address candidate
    ) external returns (
        bool isActive,
        uint256 timestamp,
        ctUint64 encryptedAmount
    ) {
        if (msg.sender != voter) revert UnauthorizedAccess();
        Vote storage record = voteRecords[voter][candidate];
        
        if (isMpcAvailable && record.isActive) {
            encryptedAmount = MpcCore.offBoardToUser(record.encryptedAmount, voter);
        } else {
            encryptedAmount = ctUint64.wrap(uint64(gtUint64.unwrap(record.encryptedAmount)));
        }
        
        return (record.isActive, record.timestamp, encryptedAmount);
    }
    
    /**
     * @notice Get list of candidates a voter has voted for
     * @dev Get voter's candidates
     * @param voter Voter address
     * @return address[] Array of candidate addresses
     */
    function getVoterCandidates(address voter) external view returns (address[] memory) {
        return voterCandidates[voter];
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Validate vote parameters for casting
     * @dev Validates candidate address and delegation limits
     * @param candidate Candidate address
     */
    function _validateVoteParameters(address candidate) internal view {
        if (candidate == address(0)) revert InvalidCandidate();
        if (candidate == msg.sender) revert InvalidCandidate();
        if (voterDelegationCount[msg.sender] > MAX_DELEGATIONS - 1) 
            revert ExceedsMaxDelegations();
    }
    
    /**
     * @notice Validate vote amount meets minimum requirement
     * @dev Checks if vote amount is above minimum threshold
     * @param gtVotes Encrypted vote amount
     */
    function _validateVoteAmount(gtUint64 gtVotes) internal {
        if (isMpcAvailable) {
            gtBool isEnough = MpcCore.ge(gtVotes, MpcCore.setPublic64(uint64(MIN_VOTE_AMOUNT)));
            if (!MpcCore.decrypt(isEnough)) revert InsufficientVoteAmount();
        } else {
            uint64 voteAmount = uint64(gtUint64.unwrap(gtVotes));
            if (voteAmount < uint64(MIN_VOTE_AMOUNT)) revert InsufficientVoteAmount();
        }
    }
    
    /**
     * @notice Update vote counts and records
     * @dev Updates voter count and candidate list for new votes
     * @param record Vote record storage reference
     * @param candidateTrust Trust data storage reference
     * @param candidate Candidate address
     */
    function _updateVoteCounts(
        Vote storage record,
        TrustData storage candidateTrust,
        address candidate
    ) internal {
        if (!record.isActive) {
            ++voterDelegationCount[msg.sender];
            voterCandidates[msg.sender].push(candidate);
            ++candidateTrust.publicVoterCount;
        }
    }
    
    /**
     * @notice Update encrypted vote amounts
     * @dev Updates both vote record and candidate total votes
     * @param record Vote record storage reference
     * @param candidateTrust Trust data storage reference
     * @param gtVotes Encrypted vote amount to add
     * @param candidate Candidate address
     */
    function _updateVoteAmounts(
        Vote storage record,
        TrustData storage candidateTrust,
        gtUint64 gtVotes,
        address candidate
    ) internal {
        // Update vote record
        if (record.isActive && isMpcAvailable) {
            record.encryptedAmount = MpcCore.add(record.encryptedAmount, gtVotes);
        } else if (record.isActive) {
            uint64 existing = uint64(gtUint64.unwrap(record.encryptedAmount));
            uint64 newVotes = uint64(gtUint64.unwrap(gtVotes));
            record.encryptedAmount = gtUint64.wrap(existing + newVotes);
        } else {
            record.encryptedAmount = gtVotes;
        }
        
        record.timestamp = block.timestamp; // solhint-disable-line not-rely-on-time
        record.isActive = true;
        
        // Update candidate's total votes
        if (isMpcAvailable) {
            candidateTrust.encryptedDPoSVotes = MpcCore.add(
                candidateTrust.encryptedDPoSVotes,
                gtVotes
            );
            candidateTrust.userEncryptedVotes = MpcCore.offBoardToUser(
                candidateTrust.encryptedDPoSVotes,
                candidate
            );
            totalSystemVotes = MpcCore.add(totalSystemVotes, gtVotes);
        } else {
            uint64 currentVotes = uint64(gtUint64.unwrap(candidateTrust.encryptedDPoSVotes));
            uint64 addVotes = uint64(gtUint64.unwrap(gtVotes));
            candidateTrust.encryptedDPoSVotes = gtUint64.wrap(currentVotes + addVotes);
            candidateTrust.userEncryptedVotes = ctUint64.wrap(currentVotes + addVotes);
            
            uint64 totalVotes = uint64(gtUint64.unwrap(totalSystemVotes));
            totalSystemVotes = gtUint64.wrap(totalVotes + addVotes);
        }
        
        candidateTrust.lastTrustUpdate = block.timestamp; // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Validate withdrawal amount against current vote
     * @dev Checks if user has enough votes to withdraw
     * @param record Vote record to check
     * @param gtVotes Amount to withdraw
     */
    function _validateWithdrawalAmount(
        Vote storage record,
        gtUint64 gtVotes
    ) internal {
        if (isMpcAvailable) {
            gtBool hasEnough = MpcCore.ge(record.encryptedAmount, gtVotes);
            if (!MpcCore.decrypt(hasEnough)) revert InsufficientVoteAmount();
        } else {
            uint64 currentVotes = uint64(gtUint64.unwrap(record.encryptedAmount));
            uint64 withdrawAmount = uint64(gtUint64.unwrap(gtVotes));
            if (currentVotes < withdrawAmount) revert InsufficientVoteAmount();
        }
    }
    
    /**
     * @notice Process vote withdrawal and update records
     * @dev Updates vote record and handles complete withdrawal
     * @param record Vote record storage reference
     * @param candidateTrust Trust data storage reference
     * @param gtVotes Amount to withdraw
     * @param candidate Candidate address
     */
    function _processWithdrawal(
        Vote storage record,
        TrustData storage candidateTrust,
        gtUint64 gtVotes,
        address candidate
    ) internal {
        if (isMpcAvailable) {
            record.encryptedAmount = MpcCore.sub(record.encryptedAmount, gtVotes);
            
            // Check if all votes withdrawn
            gtBool isEmpty = MpcCore.eq(record.encryptedAmount, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(isEmpty)) {
                _handleCompleteWithdrawal(record, candidateTrust, candidate);
            }
        } else {
            uint64 currentVotes = uint64(gtUint64.unwrap(record.encryptedAmount));
            uint64 withdrawAmount = uint64(gtUint64.unwrap(gtVotes));
            uint64 remaining = currentVotes - withdrawAmount;
            record.encryptedAmount = gtUint64.wrap(remaining);
            
            if (remaining == 0) {
                _handleCompleteWithdrawal(record, candidateTrust, candidate);
            }
        }
    }
    
    /**
     * @notice Handle complete withdrawal of all votes
     * @dev Updates counts and removes candidate from voter's list
     * @param record Vote record storage reference
     * @param candidateTrust Trust data storage reference
     * @param candidate Candidate address
     */
    function _handleCompleteWithdrawal(
        Vote storage record,
        TrustData storage candidateTrust,
        address candidate
    ) internal {
        record.isActive = false;
        --voterDelegationCount[msg.sender];
        --candidateTrust.publicVoterCount;
        _removeCandidate(msg.sender, candidate);
    }
    
    /**
     * @notice Update candidate votes after withdrawal
     * @dev Subtracts withdrawn amount from candidate and system totals
     * @param candidateTrust Trust data storage reference
     * @param gtVotes Amount withdrawn
     * @param candidate Candidate address
     */
    function _updateCandidateVotesAfterWithdrawal(
        TrustData storage candidateTrust,
        gtUint64 gtVotes,
        address candidate
    ) internal {
        if (isMpcAvailable) {
            candidateTrust.encryptedDPoSVotes = MpcCore.sub(
                candidateTrust.encryptedDPoSVotes,
                gtVotes
            );
            candidateTrust.userEncryptedVotes = MpcCore.offBoardToUser(
                candidateTrust.encryptedDPoSVotes,
                candidate
            );
            totalSystemVotes = MpcCore.sub(totalSystemVotes, gtVotes);
        } else {
            uint64 currentTotal = uint64(gtUint64.unwrap(candidateTrust.encryptedDPoSVotes));
            uint64 withdrawAmount = uint64(gtUint64.unwrap(gtVotes));
            candidateTrust.encryptedDPoSVotes = gtUint64.wrap(currentTotal - withdrawAmount);
            candidateTrust.userEncryptedVotes = ctUint64.wrap(currentTotal - withdrawAmount);
            
            uint64 totalVotes = uint64(gtUint64.unwrap(totalSystemVotes));
            totalSystemVotes = gtUint64.wrap(totalVotes - withdrawAmount);
        }
    }
    
    /**
     * @notice Calculate decayed vote value
     * @dev Applies time-based decay to vote amount
     * @param votes Current vote amount
     * @param timeSinceUpdate Time elapsed since last update
     * @return gtUint64 Decayed vote amount
     */
    function _calculateDecayedVotes(
        gtUint64 votes,
        uint256 timeSinceUpdate
    ) internal returns (gtUint64) {
        if (timeSinceUpdate > VOTE_DECAY_PERIOD - 1) {
            // Apply full decay
            return gtUint64.wrap(0);
        } else if (timeSinceUpdate > 0 && isMpcAvailable) {
            // Apply partial decay
            uint64 decayFactor = uint64(
                (VOTE_DECAY_PERIOD - timeSinceUpdate) * 10000 / VOTE_DECAY_PERIOD
            );
            gtUint64 factor = MpcCore.setPublic64(decayFactor);
            votes = MpcCore.mul(votes, factor);
            votes = MpcCore.div(votes, MpcCore.setPublic64(10000));
        }
        return votes;
    }
    
    /**
     * @notice Apply vote decay based on time elapsed
     * @dev Apply vote decay based on time
     * @param candidate Candidate address to apply decay to
     */
    function _applyVoteDecay(address candidate) internal {
        TrustData storage candidateTrust = trustData[candidate];
        // solhint-disable-next-line not-rely-on-time
        uint256 timeSinceLastDecay = block.timestamp - candidateTrust.lastDecayCalculation;
        
        if (timeSinceLastDecay == 0) return;
        
        if (timeSinceLastDecay > VOTE_DECAY_PERIOD - 1) {
            // Full decay - reset votes
            candidateTrust.encryptedDPoSVotes = _toEncrypted(0);
            candidateTrust.userEncryptedVotes = ctUint64.wrap(0);
        } else if (isMpcAvailable) {
            // Partial decay
            uint64 decayFactor = uint64(
                (VOTE_DECAY_PERIOD - timeSinceLastDecay) * 10000 / VOTE_DECAY_PERIOD
            );
            gtUint64 factor = MpcCore.setPublic64(decayFactor);
            candidateTrust.encryptedDPoSVotes = MpcCore.mul(
                candidateTrust.encryptedDPoSVotes,
                factor
            );
            candidateTrust.encryptedDPoSVotes = MpcCore.div(
                candidateTrust.encryptedDPoSVotes,
                MpcCore.setPublic64(10000)
            );
        }
        
        candidateTrust.lastDecayCalculation = block.timestamp; // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Remove candidate from voter's list of voted candidates
     * @dev Remove candidate from voter's list
     * @param voter Voter address
     * @param candidate Candidate address to remove
     */
    function _removeCandidate(address voter, address candidate) internal {
        address[] storage candidates = voterCandidates[voter];
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (candidates[i] == candidate) {
                candidates[i] = candidates[candidates.length - 1];
                candidates.pop();
                break;
            }
        }
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Enable or disable COTI PoT globally for the system
     * @dev Enable/disable COTI PoT globally
     * @param enabled Whether to enable COTI PoT
     */
    function setCotiPoTEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        cotiPoTEnabled = enabled;
        emit CotiPoTEnabledChanged(enabled, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Add a new COTI oracle address
     * @dev Add COTI oracle
     * @param oracle Oracle address to add
     */
    function addCotiOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        if (oracle == address(0)) revert InvalidCandidate();
        _grantRole(COTI_ORACLE_ROLE, oracle);
        emit CotiOracleAdded(oracle);
    }
    
    /**
     * @notice Remove a COTI oracle address
     * @dev Remove COTI oracle
     * @param oracle Oracle address to remove
     */
    function removeCotiOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        _revokeRole(COTI_ORACLE_ROLE, oracle);
        emit CotiOracleRemoved(oracle);
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when a DPoS vote is withdrawn
     * @param voter Address of the voter withdrawing the vote
     * @param candidate Address of the candidate losing the vote
     * @param timestamp Time when the vote was withdrawn
     */
    event DPoSVoteWithdrawn(
        address indexed voter,
        address indexed candidate,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when COTI Proof of Trust score is updated
     * @param user Address of the user whose score is updated
     * @param score New COTI PoT score
     * @param timestamp Time when the score was updated
     */
    event CotiPoTScoreUpdated(
        address indexed user,
        uint256 indexed score,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when user's trust method is changed
     * @param user Address of the user changing trust method
     * @param useCotiPoT Whether to use COTI PoT (true) or DPoS (false)
     * @param timestamp Time when the method was changed
     */
    event TrustMethodChanged(
        address indexed user,
        bool indexed useCotiPoT,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Emitted when COTI PoT is enabled or disabled globally
     * @param enabled Whether COTI PoT is enabled
     * @param timestamp Time when the setting was changed
     */
    event CotiPoTEnabledChanged(bool indexed enabled, uint256 indexed timestamp);
    /**
     * @notice Emitted when a new COTI oracle is added
     * @param oracle Address of the oracle being added
     */
    event CotiOracleAdded(address indexed oracle);
    /**
     * @notice Emitted when a COTI oracle is removed
     * @param oracle Address of the oracle being removed
     */
    event CotiOracleRemoved(address indexed oracle);
}