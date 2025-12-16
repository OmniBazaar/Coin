// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockOmniRegistration
 * @author OmniBazaar Team
 * @notice Mock contract for testing OmniParticipation
 * @dev Simulates OmniRegistration for unit tests
 */
contract MockOmniRegistration {
    mapping(address => bool) private _registered;
    mapping(address => bool) private _kycTier1;
    mapping(address => bool) private _kycTier2;
    mapping(address => bool) private _kycTier3;
    mapping(address => bool) private _kycTier4;
    mapping(address => uint256) private _referralCount;

    /**
     * @notice Set registration status for user
     * @param user User address
     * @param status Registration status
     */
    function setRegistered(address user, bool status) external {
        _registered[user] = status;
    }

    /**
     * @notice Set KYC Tier 1 status
     * @param user User address
     * @param status KYC status
     */
    function setKycTier1(address user, bool status) external {
        _kycTier1[user] = status;
    }

    /**
     * @notice Set KYC Tier 2 status
     * @param user User address
     * @param status KYC status
     */
    function setKycTier2(address user, bool status) external {
        _kycTier2[user] = status;
    }

    /**
     * @notice Set KYC Tier 3 status
     * @param user User address
     * @param status KYC status
     */
    function setKycTier3(address user, bool status) external {
        _kycTier3[user] = status;
    }

    /**
     * @notice Set KYC Tier 4 status
     * @param user User address
     * @param status KYC status
     */
    function setKycTier4(address user, bool status) external {
        _kycTier4[user] = status;
    }

    /**
     * @notice Set referral count for user
     * @param user User address
     * @param count Number of referrals
     */
    function setReferralCount(address user, uint256 count) external {
        _referralCount[user] = count;
    }

    // Interface implementations

    /**
     * @notice Check if user is registered
     * @param user Address to check
     * @return True if registered
     */
    function isRegistered(address user) external view returns (bool) {
        return _registered[user];
    }

    /**
     * @notice Check if user has KYC Tier 1
     * @param user Address to check
     * @return True if has Tier 1
     */
    function hasKycTier1(address user) external view returns (bool) {
        return _kycTier1[user];
    }

    /**
     * @notice Check if user has KYC Tier 2
     * @param user Address to check
     * @return True if has Tier 2
     */
    function hasKycTier2(address user) external view returns (bool) {
        return _kycTier2[user];
    }

    /**
     * @notice Check if user has KYC Tier 3
     * @param user Address to check
     * @return True if has Tier 3
     */
    function hasKycTier3(address user) external view returns (bool) {
        return _kycTier3[user];
    }

    /**
     * @notice Check if user has KYC Tier 4
     * @param user Address to check
     * @return True if has Tier 4
     */
    function hasKycTier4(address user) external view returns (bool) {
        return _kycTier4[user];
    }

    /**
     * @notice Get user's referral count
     * @param user Address to check
     * @return Number of referrals
     */
    function getReferralCount(address user) external view returns (uint256) {
        return _referralCount[user];
    }
}
