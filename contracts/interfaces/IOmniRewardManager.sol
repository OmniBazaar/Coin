// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOmniRewardManager
 * @author OmniCoin Development Team
 * @notice Interface for the OmniRewardManager contract
 * @dev Defines all external functions for interacting with the reward manager
 */
interface IOmniRewardManager {
    // ============ Enums ============

    /// @notice Types of bonus pools
    enum PoolType {
        WelcomeBonus,
        ReferralBonus,
        FirstSaleBonus,
        ValidatorRewards
    }

    // ============ Structs ============

    /// @notice Parameters for referral bonus distribution
    struct ReferralParams {
        address referrer;
        address secondLevelReferrer;
        uint256 primaryAmount;
        uint256 secondaryAmount;
    }

    /// @notice Parameters for validator reward distribution
    struct ValidatorRewardParams {
        address validator;
        uint256 validatorAmount;
        address stakingPool;
        uint256 stakingAmount;
        address oddao;
        uint256 oddaoAmount;
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

    /// @notice Emitted when validator rewards are distributed
    /// @param virtualBlockHeight Virtual block height for this distribution
    /// @param validator Address of the selected validator
    /// @param totalAmount Combined amount distributed
    event ValidatorRewardDistributed(
        uint256 indexed virtualBlockHeight,
        address indexed validator,
        uint256 indexed totalAmount
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

    /// @notice Emitted when a merkle root is updated
    /// @param poolType Type of pool whose merkle root was updated
    /// @param oldRoot Previous merkle root
    /// @param newRoot New merkle root
    event MerkleRootUpdated(
        PoolType indexed poolType,
        bytes32 indexed oldRoot,
        bytes32 indexed newRoot
    );

    // ============ Errors ============

    /// @notice Thrown when pool has insufficient funds
    error InsufficientPoolBalance(PoolType poolType, uint256 requested, uint256 available);

    /// @notice Thrown when user has already claimed a one-time bonus
    error BonusAlreadyClaimed(address user, PoolType bonusType);

    /// @notice Thrown when merkle proof verification fails
    error InvalidMerkleProof(address user, PoolType poolType);

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

    /// @notice Emitted when welcome bonus is claimed via trustless relay
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

    // ============ Bonus Distribution Functions ============

    /**
     * @notice Claim welcome bonus for a user
     * @param user Address of the user receiving the bonus
     * @param amount Amount of XOM to transfer
     * @param merkleProof Merkle proof verifying user eligibility
     */
    function claimWelcomeBonus(
        address user,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external;

    /**
     * @notice Claim referral bonus for referrers
     * @param params Struct containing referral distribution parameters
     * @param merkleProof Merkle proof verifying referral relationship
     */
    function claimReferralBonus(
        ReferralParams calldata params,
        bytes32[] calldata merkleProof
    ) external;

    /**
     * @notice Claim first sale bonus for a seller
     * @param seller Address of the seller receiving the bonus
     * @param amount Amount of XOM to transfer
     * @param merkleProof Merkle proof verifying first sale completion
     */
    function claimFirstSaleBonus(
        address seller,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external;

    /**
     * @notice Claim welcome bonus permissionlessly (requires registration)
     * @dev Users call this directly after registration
     */
    function claimWelcomeBonusPermissionless() external;

    /**
     * @notice Claim welcome bonus using trustless on-chain verification
     * @dev Users call this after completing KYC Tier 1 via on-chain verification.
     *      Requires user to have:
     *      1. Registered in OmniRegistration contract
     *      2. Submitted phone verification proof on-chain
     *      3. Submitted social verification proof on-chain
     *      4. Achieved KYC Tier 1 status (hasKycTier1 returns true)
     */
    function claimWelcomeBonusTrustless() external;

    /**
     * @notice Claim welcome bonus with user signature (trustless relay)
     * @dev ANYONE can relay this - NO SPECIAL ROLES REQUIRED.
     *      Security comes from verifying the USER'S signature, not caller's role.
     *      This is the GASLESS version - relayer pays gas, user receives bonus.
     *
     *      The user signs an EIP-712 ClaimWelcomeBonus message with their wallet.
     *      Any relayer can submit the signed message and pay gas.
     *      The contract verifies the USER signed it, then transfers bonus to USER.
     *
     * @param user The address of the user claiming (must match signer)
     * @param nonce User's current claim nonce (for replay protection)
     * @param deadline Claim request expiration timestamp
     * @param signature User's EIP-712 signature
     */
    function claimWelcomeBonusRelayed(
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

    /**
     * @notice Claim first sale bonus permissionlessly
     * @dev Sellers call this after completing their first sale
     */
    function claimFirstSaleBonusPermissionless() external;

    // ============ Validator Reward Functions ============

    /**
     * @notice Distribute validator reward for a virtual block
     * @param params Struct containing validator reward distribution parameters
     */
    function distributeValidatorReward(
        ValidatorRewardParams calldata params
    ) external;

    // ============ Admin Functions ============

    /**
     * @notice Update merkle root for a bonus pool
     * @param poolType Type of pool to update
     * @param newRoot New merkle root
     */
    function updateMerkleRoot(PoolType poolType, bytes32 newRoot) external;

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
     * @return validatorRewards Remaining validator rewards pool balance
     */
    function getPoolBalances()
        external
        view
        returns (
            uint256 welcomeBonus,
            uint256 referralBonus,
            uint256 firstSaleBonus,
            uint256 validatorRewards
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
            uint256[4] memory initialAmounts,
            uint256[4] memory remainingAmounts,
            uint256[4] memory distributedAmounts
        );
}
