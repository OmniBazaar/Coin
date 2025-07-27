// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReputationSystemBase} from "./ReputationSystemBase.sol";
import {ITrustSystem} from "./interfaces/IReputationSystem.sol";
import {MpcCore, gtBool, gtUint64, ctUint64, itUint64} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title OmniCoinTrustSystem
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
    // CONSTANTS
    // =============================================================================
    
    uint256 public constant MIN_VOTE_AMOUNT = 100 * 10**6; // 100 tokens minimum
    uint256 public constant VOTE_DECAY_PERIOD = 90 days;   // Votes decay after 90 days
    uint256 public constant MAX_DELEGATIONS = 10;          // Max candidates a voter can support
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    bytes32 public constant TRUST_MANAGER_ROLE = keccak256("TRUST_MANAGER_ROLE");
    bytes32 public constant COTI_ORACLE_ROLE = keccak256("COTI_ORACLE_ROLE");
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @dev User trust data
    mapping(address => TrustData) public trustData;
    
    /// @dev Vote records: voter => candidate => vote record
    mapping(address => mapping(address => Vote)) public voteRecords;
    
    /// @dev Delegation count per voter
    mapping(address => uint256) public voterDelegationCount;
    
    /// @dev List of candidates a voter has voted for
    mapping(address => address[]) public voterCandidates;
    
    /// @dev Total encrypted votes in the system
    gtUint64 public totalSystemVotes;
    
    /// @dev Whether COTI PoT is globally enabled
    bool public cotiPoTEnabled;
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
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
     * @dev Cast DPoS vote for a candidate
     * @param candidate Candidate address
     * @param votes Encrypted vote amount
     */
    function castDPoSVote(
        address candidate,
        itUint64 calldata votes
    ) external override whenNotPaused nonReentrant {
        if (candidate == address(0)) revert InvalidCandidate();
        if (candidate == msg.sender) revert InvalidCandidate();
        if (voterDelegationCount[msg.sender] >= MAX_DELEGATIONS) 
            revert ExceedsMaxDelegations();
        
        // Validate vote amount
        gtUint64 gtVotes = _validateInput(votes);
        
        if (isMpcAvailable) {
            gtBool isEnough = MpcCore.ge(gtVotes, MpcCore.setPublic64(uint64(MIN_VOTE_AMOUNT)));
            if (!MpcCore.decrypt(isEnough)) revert InsufficientVoteAmount();
        } else {
            uint64 voteAmount = uint64(gtUint64.unwrap(gtVotes));
            if (voteAmount < uint64(MIN_VOTE_AMOUNT)) revert InsufficientVoteAmount();
        }
        
        Vote storage record = voteRecords[msg.sender][candidate];
        TrustData storage candidateTrust = trustData[candidate];
        
        // If first vote for this candidate, update counts
        if (!record.isActive) {
            voterDelegationCount[msg.sender]++;
            voterCandidates[msg.sender].push(candidate);
            candidateTrust.publicVoterCount++;
        }
        
        // Apply decay to existing votes before adding new ones
        _applyVoteDecay(candidate);
        
        // Update vote record
        if (record.isActive && isMpcAvailable) {
            // Add to existing votes
            record.encryptedAmount = MpcCore.add(record.encryptedAmount, gtVotes);
        } else if (record.isActive) {
            // Fallback addition
            uint64 existing = uint64(gtUint64.unwrap(record.encryptedAmount));
            uint64 newVotes = uint64(gtUint64.unwrap(gtVotes));
            record.encryptedAmount = gtUint64.wrap(existing + newVotes);
        } else {
            record.encryptedAmount = gtVotes;
        }
        
        record.timestamp = block.timestamp;
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
        
        candidateTrust.lastTrustUpdate = block.timestamp;
        
        // Update reputation core with trust score
        _updateReputationInCore(candidate, COMPONENT_TRUST_SCORE, votes);
        
        emit DPoSVoteCast(msg.sender, candidate, block.timestamp);
    }
    
    /**
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
        if (isMpcAvailable) {
            gtBool hasEnough = MpcCore.ge(record.encryptedAmount, gtVotes);
            if (!MpcCore.decrypt(hasEnough)) revert InsufficientVoteAmount();
        } else {
            uint64 currentVotes = uint64(gtUint64.unwrap(record.encryptedAmount));
            uint64 withdrawAmount = uint64(gtUint64.unwrap(gtVotes));
            if (currentVotes < withdrawAmount) revert InsufficientVoteAmount();
        }
        
        // Update vote record
        if (isMpcAvailable) {
            record.encryptedAmount = MpcCore.sub(record.encryptedAmount, gtVotes);
            
            // Check if all votes withdrawn
            gtBool isEmpty = MpcCore.eq(record.encryptedAmount, MpcCore.setPublic64(0));
            if (MpcCore.decrypt(isEmpty)) {
                record.isActive = false;
                voterDelegationCount[msg.sender]--;
                candidateTrust.publicVoterCount--;
                _removeCandidate(msg.sender, candidate);
            }
        } else {
            uint64 currentVotes = uint64(gtUint64.unwrap(record.encryptedAmount));
            uint64 withdrawAmount = uint64(gtUint64.unwrap(gtVotes));
            uint64 remaining = currentVotes - withdrawAmount;
            record.encryptedAmount = gtUint64.wrap(remaining);
            
            if (remaining == 0) {
                record.isActive = false;
                voterDelegationCount[msg.sender]--;
                candidateTrust.publicVoterCount--;
                _removeCandidate(msg.sender, candidate);
            }
        }
        
        // Update candidate's total votes
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
        
        emit DPoSVoteWithdrawn(msg.sender, candidate, block.timestamp);
    }
    
    // =============================================================================
    // COTI PROOF OF TRUST INTEGRATION
    // =============================================================================
    
    /**
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
        userData.lastTrustUpdate = block.timestamp;
        
        // Convert to encrypted format for reputation update
        // Create input type with score embedded in ciphertext
        itUint64 memory encryptedScore = itUint64({
            ciphertext: ctUint64.wrap(uint64(score)),
            signature: new bytes(32)
        });
        
        _updateReputationInCoreMemory(user, COMPONENT_TRUST_SCORE, encryptedScore);
        
        emit CotiPoTScoreUpdated(user, score, block.timestamp);
    }
    
    /**
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
        emit TrustMethodChanged(user, useCoti, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Get user's trust score (DPoS or COTI PoT)
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
            uint256 timeSinceUpdate = block.timestamp - userData.lastDecayCalculation;
            
            if (timeSinceUpdate > VOTE_DECAY_PERIOD) {
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
    }
    
    /**
     * @dev Get voter count for a candidate
     */
    function getVoterCount(address user) external view override returns (uint256) {
        return trustData[user].publicVoterCount;
    }
    
    /**
     * @dev Get COTI Proof of Trust score
     */
    function getCotiProofOfTrustScore(address user) external view override returns (uint256) {
        return trustData[user].cotiProofOfTrustScore;
    }
    
    /**
     * @dev Get user's encrypted votes (for user viewing)
     */
    function getUserEncryptedVotes(address user) external view returns (ctUint64) {
        if (msg.sender != user) revert UnauthorizedAccess();
        return trustData[user].userEncryptedVotes;
    }
    
    /**
     * @dev Get vote record details
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
     * @dev Get voter's candidates
     */
    function getVoterCandidates(address voter) external view returns (address[] memory) {
        return voterCandidates[voter];
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @dev Apply vote decay based on time
     */
    function _applyVoteDecay(address candidate) internal {
        TrustData storage candidateTrust = trustData[candidate];
        uint256 timeSinceLastDecay = block.timestamp - candidateTrust.lastDecayCalculation;
        
        if (timeSinceLastDecay == 0) return;
        
        if (timeSinceLastDecay >= VOTE_DECAY_PERIOD) {
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
        
        candidateTrust.lastDecayCalculation = block.timestamp;
    }
    
    /**
     * @dev Remove candidate from voter's list
     */
    function _removeCandidate(address voter, address candidate) internal {
        address[] storage candidates = voterCandidates[voter];
        for (uint256 i = 0; i < candidates.length; i++) {
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
     * @dev Enable/disable COTI PoT globally
     */
    function setCotiPoTEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        cotiPoTEnabled = enabled;
        emit CotiPoTEnabledChanged(enabled, block.timestamp);
    }
    
    /**
     * @dev Add COTI oracle
     */
    function addCotiOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        if (oracle == address(0)) revert InvalidCandidate();
        _grantRole(COTI_ORACLE_ROLE, oracle);
        emit CotiOracleAdded(oracle);
    }
    
    /**
     * @dev Remove COTI oracle
     */
    function removeCotiOracle(address oracle) external onlyRole(ADMIN_ROLE) {
        _revokeRole(COTI_ORACLE_ROLE, oracle);
        emit CotiOracleRemoved(oracle);
    }
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event DPoSVoteWithdrawn(
        address indexed voter,
        address indexed candidate,
        uint256 timestamp
    );
    
    event CotiPoTScoreUpdated(
        address indexed user,
        uint256 score,
        uint256 timestamp
    );
    
    event TrustMethodChanged(
        address indexed user,
        bool useCotiPoT,
        uint256 timestamp
    );
    
    event CotiPoTEnabledChanged(bool enabled, uint256 timestamp);
    event CotiOracleAdded(address indexed oracle);
    event CotiOracleRemoved(address indexed oracle);
}