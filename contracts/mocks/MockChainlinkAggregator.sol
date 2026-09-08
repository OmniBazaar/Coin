// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockChainlinkAggregator
 * @author OmniBazaar Team
 * @notice Mock Chainlink V3 aggregator for OmniPriceOracle tests
 * @dev Allows setting arbitrary price/timestamp for unit tests
 */
contract MockChainlinkAggregator {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _updatedAt;
    bool private _shouldRevert;

    /**
     * @notice Deploy mock aggregator
     * @param decimals_ Number of decimals in the feed
     */
    constructor(uint8 decimals_) {
        _decimals = decimals_;
        _updatedAt = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Set the mock answer
     * @param answer Price to return
     */
    function setAnswer(int256 answer) external {
        _answer = answer;
        _updatedAt = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Set the last update timestamp
     * @param updatedAt Timestamp to return
     */
    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    /**
     * @notice Set whether latestRoundData should revert
     * @param shouldRevert True to make it revert
     */
    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    /**
     * @notice Get latest round data (Chainlink V3 interface)
     * @return roundId Round ID (always 1)
     * @return answer Price answer
     * @return startedAt Start timestamp
     * @return updatedAt Update timestamp
     * @return answeredInRound Answered in round (always 1)
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        require(!_shouldRevert, "MockChainlink: forced revert");
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    /**
     * @notice Get feed decimals
     * @return Number of decimals
     */
    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
