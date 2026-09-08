// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockParticipation
 * @author OmniBazaar Development Team
 * @notice Mock OmniParticipation for unit testing OmniChatFee.
 * @dev Returns configurable scores for any address.
 */
contract MockParticipation {
    /// @notice Configurable scores per address
    mapping(address => uint256) public scores;

    /// @notice Whether an address has an explicitly configured score.
    /// @dev Distinguishes a genuine score of 0 (Anonymous tier) from an
    ///      unconfigured address that should fall back to {defaultScore}.
    mapping(address => bool) public hasScore;

    /// @notice Default score for addresses without explicit config
    uint256 public defaultScore;

    /// @notice When true, getTotalScore reverts (simulates a broken scorer)
    bool public revertScores;

    /**
     * @notice Toggle the reverting-scorer simulation for RT-OB-02 tests
     * @param shouldRevert Whether getTotalScore should revert
     */
    function setRevertScores(bool shouldRevert) external {
        revertScores = shouldRevert;
    }

    /**
     * @notice Set participation score for a specific address
     * @param user Address to configure
     * @param score Score to return (0-100)
     */
    function setScore(address user, uint256 score) external {
        scores[user] = score;
        hasScore[user] = true;
    }

    /**
     * @notice Set default score for unconfigured addresses
     * @param score Default score (0-100)
     */
    function setDefaultScore(uint256 score) external {
        defaultScore = score;
    }

    /**
     * @notice Get total participation score for a user
     * @param user Address to check
     * @return Total score (0-100)
     */
    function getTotalScore(
        address user
    ) external view returns (uint256) {
        if (revertScores) revert("scorer unavailable");
        if (!hasScore[user]) return defaultScore;
        return scores[user];
    }
}
