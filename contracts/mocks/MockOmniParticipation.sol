// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockOmniParticipation
 * @author OmniBazaar Team
 * @notice Mock contract for testing OmniValidatorRewards
 * @dev Simulates OmniParticipation for unit tests
 */
contract MockOmniParticipation {
    mapping(address => uint256) private _scores;
    mapping(address => bool) private _canBeValidator;
    mapping(address => bool) private _canBeListingNode;

    /**
     * @notice Set total score for user
     * @param user User address
     * @param score Total participation score (0-100)
     */
    function setTotalScore(address user, uint256 score) external {
        _scores[user] = score;
    }

    /**
     * @notice Set validator eligibility for user
     * @param user User address
     * @param eligible Whether user can be a validator
     */
    function setCanBeValidator(address user, bool eligible) external {
        _canBeValidator[user] = eligible;
    }

    /**
     * @notice Set listing node eligibility for user
     * @param user User address
     * @param eligible Whether user can be a listing node
     */
    function setCanBeListingNode(address user, bool eligible) external {
        _canBeListingNode[user] = eligible;
    }

    // Interface implementations

    /**
     * @notice Get user's total participation score
     * @param user Address to check
     * @return Total score (0-100)
     */
    function getTotalScore(address user) external view returns (uint256) {
        return _scores[user];
    }

    /**
     * @notice Check if user can be a validator
     * @param user Address to check
     * @return True if qualified
     */
    function canBeValidator(address user) external view returns (bool) {
        return _canBeValidator[user];
    }

    /**
     * @notice Check if user can be a listing node
     * @param user Address to check
     * @return True if qualified
     */
    function canBeListingNode(address user) external view returns (bool) {
        return _canBeListingNode[user];
    }
}
