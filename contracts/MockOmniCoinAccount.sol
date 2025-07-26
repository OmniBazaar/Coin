// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockOmniCoinAccount
 * @dev Mock contract for testing OmniCoinArbitration
 */
contract MockOmniCoinAccount {
    mapping(address => uint256) public reputationScore;
    mapping(address => uint256[6]) private accountStatus;

    function setReputationScore(address account, uint256 score) external {
        reputationScore[account] = score;
    }

    function setAccountStatus(address account, uint256[6] memory status) external {
        accountStatus[account] = status;
    }

    function getAccountStatus(address account) external view returns (
        uint256 balance,
        uint256 stakingAmount,
        uint256 privacyLevel,
        bool isActive,
        uint256 nonce,
        uint256 reputation
    ) {
        uint256[6] memory status = accountStatus[account];
        return (
            status[0],
            status[1],
            status[2],
            status[3] == 1,
            status[4],
            status[5]
        );
    }
}