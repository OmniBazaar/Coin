// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOmniRewardManager
 * @author OmniCoin Development Team
 * @notice Interface for the OmniRewardManager contract
 * @dev Defines all external functions for interacting with the reward manager.
 *      All bonus claims use the gasless relay pattern: user signs EIP-712 intent,
 *      validator relays the transaction and pays gas.
 */
interface IOmniRewardManager {
    // ============ Enums ============

    /// @notice Types of bonus pools
    enum PoolType {
        WelcomeBonus,
        ReferralBonus,
        FirstSaleBonus
    }

    // ============ Events ============

    /// @notice Emitted when a user claims their welcome bonus
    /// @param user Address of the bonus recipient
    /// @param amount Amount of XOM transferred
    /// @param remainingPool Remaining balance in welcome bonus pool
    event WelcomeBonusClaimed(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed remainingPool
    );

    /// @notice Emitted when referral bonuses are distributed
    /// @param referrer Primary referrer address
    /// @param secondLevelReferrer Secondary referrer address
    /// @param totalAmount Combined amount sent to both referrers
    event ReferralBonusClaimed(
        address indexed referrer,
        address indexed secondLevelReferrer,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when a seller claims their first sale bonus
    /// @param seller Address of the bonus recipient
    /// @param amount Amount of XOM transferred
    /// @param remainingPool Remaining balance in first sale bonus pool
    event FirstSaleBonusClaimed(
        address indexed seller,
        uint256 indexed amount,
        uint256 indexed remainingPool
    );

    /// @notice Emitted when a pool balance drops below warning threshold
    /// @param poolType Type of pool that is running low
    /// @param remainingAmount Current remaining balance
    /// @param threshold Warning threshold that was crossed
    event PoolLowWarning(
        PoolType indexed poolType,
        uint256 indexed remainingAmount,
        uint256 indexed threshold
    );

    /// @notice Emitted when welcome bonus is claimed via relay
    /// @param user User who received the bonus
    /// @param amount Amount of XOM transferred
    /// @param relayer Address that submitted the transaction (paid gas)
    /// @param referrer Referrer who will receive referral bonus (if any)
    event WelcomeBonusClaimedRelayed(
        address indexed user,
        uint256 indexed amount,
        address relayer,
        address referrer
    );

    // ============ Errors ============

    /// @notice Thrown when pool has insufficient funds
    error InsufficientPoolBalance(PoolType poolType, uint256 requested, uint256 available);

    /// @notice Thrown when user has already claimed a one-time bonus
    error BonusAlreadyClaimed(address user, PoolType bonusType);

    /// @notice Thrown when zero address is provided
    error ZeroAddressNotAllowed();

    /// @notice Thrown when zero amount is provided
    error ZeroAmountNotAllowed();

    /// @notice Thrown when user has not completed KYC Tier 1
    error KycTier1Required(address user);

    /// @notice Thrown when claim deadline has expired
    error ClaimDeadlineExpired();

    /// @notice Thrown when claim nonce doesn't match expected
    /// @param user User address
    /// @param provided Provided nonce
    /// @param expected Expected nonce
    error InvalidClaimNonce(address user, uint256 provided, uint256 expected);

    /// @notice Thrown when recovered signer doesn't match user
    /// @param expectedUser Expected user address
    /// @param recoveredSigner Recovered signer from signature
    error InvalidUserSignature(address expectedUser, address recoveredSigner);

    // ============ Bonus Claim Functions (Gasless Relay) ============

    /**
     * @notice Claim welcome bonus with user signature (gasless relay)
     * @param user The address of the user claiming (must match signer)
     * @param nonce User's current claim nonce (for replay protection)
     * @param deadline Claim request expiration timestamp
     * @param signature User's EIP-712 signature
     */
    function claimWelcomeBonus(
        address user,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /**
     * @notice Claim accumulated referral bonus with user signature (gasless relay)
     * @param user Address of referrer claiming (must match signer)
     * @param nonce User's current claim nonce
     * @param deadline Claim request expiration
     * @param signature User's EIP-712 signature
     */
    function claimReferralBonus(
        address user,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /**
     * @notice Claim first sale bonus with user signature (gasless relay)
     * @param user Address of seller claiming (must match signer)
     * @param nonce User's current claim nonce
     * @param deadline Claim request expiration
     * @param signature User's EIP-712 signature
     */
    function claimFirstSaleBonus(
        address user,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /**
     * @notice Get user's current claim nonce
     * @param user Address to check
     * @return Current nonce for the user
     */
    function getClaimNonce(address user) external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Pause all distribution functions
     */
    function pause() external;

    /**
     * @notice Unpause distribution functions
     */
    function unpause() external;

    // ============ View Functions ============

    /**
     * @notice Get all pool balances
     * @return welcomeBonus Remaining welcome bonus pool balance
     * @return referralBonus Remaining referral bonus pool balance
     * @return firstSaleBonus Remaining first sale bonus pool balance
     */
    function getPoolBalances()
        external
        view
        returns (
            uint256 welcomeBonus,
            uint256 referralBonus,
            uint256 firstSaleBonus
        );

    /**
     * @notice Get total undistributed tokens across all pools
     * @return total Sum of all remaining pool balances
     */
    function getTotalUndistributed() external view returns (uint256 total);

    /**
     * @notice Get total tokens distributed across all pools
     * @return total Sum of all distributed tokens
     */
    function getTotalDistributed() external view returns (uint256 total);

    /**
     * @notice Check if a user has claimed their welcome bonus
     * @param user Address to check
     * @return claimed True if already claimed
     */
    function hasClaimedWelcomeBonus(address user) external view returns (bool claimed);

    /**
     * @notice Check if a seller has claimed their first sale bonus
     * @param seller Address to check
     * @return claimed True if already claimed
     */
    function hasClaimedFirstSaleBonus(address seller) external view returns (bool claimed);

    /**
     * @notice Get total referral bonuses earned by an address
     * @param referrer Address to check
     * @return earned Total XOM earned through referrals
     */
    function getReferralBonusesEarned(address referrer) external view returns (uint256 earned);

    /**
     * @notice Get detailed statistics for all pools
     * @return initialAmounts Initial amounts for each pool
     * @return remainingAmounts Remaining amounts for each pool
     * @return distributedAmounts Distributed amounts for each pool
     */
    function getPoolStatistics()
        external
        view
        returns (
            uint256[3] memory initialAmounts,
            uint256[3] memory remainingAmounts,
            uint256[3] memory distributedAmounts
        );
}
