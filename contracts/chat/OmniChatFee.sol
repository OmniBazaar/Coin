// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";

// ══════════════════════════════════════════════════════════════════════
//                          INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title IParticipationScorer
 * @author OmniBazaar Team
 * @notice Minimal interface for OmniParticipation score lookup
 * @dev Only the gas-efficient getTotalScore() is needed
 */
interface IParticipationScorer {
    /// @notice Get total participation score for a user
    /// @param user Address to check
    /// @return Total score (0-100)
    function getTotalScore(address user)
        external
        view
        returns (uint256);
}

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Channel ID is zero
error InvalidChannelId();

/// @notice Listing ID is zero for marketplace message
error InvalidListingId();

/// @notice Zero address provided
error ZeroChatAddress();

/// @notice Base fee cannot be zero (disables anti-spam)
error ZeroBaseFee();

/// @notice Base fee exceeds the maximum allowed value
error FeeExceedsMaximum();

/// @notice Invalid tier configuration
error InvalidTierConfig();

/// @notice Caller is already initialized
error AlreadyInitialized();

/**
 * @title OmniChatFee
 * @author OmniBazaar Team
 * @notice Participation-based chat fee management for OmniBazaar
 *
 * @dev UUPS upgradeable contract with 5 participation-based fee tiers
 *      that reads scores from OmniParticipation.sol on-chain.
 *
 * Fee Tiers (by participation score):
 *   Anonymous  (0-9):    5 free/month,   25 XOM excess
 *   Basic      (10-24):  20 free/month,  10 XOM excess
 *   Established(25-49):  100 free/month,  5 XOM excess
 *   Trusted    (50-74):  500 free/month,  1 XOM excess
 *   Elite      (75-100): Unlimited,       0 XOM (free)
 *
 * Marketplace exemption: payMarketplaceMessageFee() records proof
 * with zero charge and zero quota impact. The escrow deposit is
 * the anti-spam mechanism for buyer-seller chat.
 *
 * Features:
 * - Participation-score-based tiers (reads OmniParticipation)
 * - Marketplace messages always free (escrow gated)
 * - Fee distribution: 100% to UnifiedFeeVault (70/20/10 split)
 * - Proof of payment: hasValidPayment() for validator verification
 * - Bulk messaging: 10x excess fee (anti-spam, always paid)
 * - Monthly reset: 30-day approximation
 *
 * Security:
 * - UUPS upgradeable (owner-controlled)
 * - AccessControl (ADMIN_ROLE for config, UPGRADER_ROLE for UUPS)
 * - ReentrancyGuard on all transfers
 * - CEI-compliant: state updates before external calls
 */
contract OmniChatFee is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                             STRUCTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Configuration for a single fee tier
    /// @param minScore Minimum participation score for this tier
    /// @param freePerMonth Free messages per month (UNLIMITED for no cap)
    /// @param excessFee Fee per message after free tier exhausted (18 dec)
    struct TierConfig {
        uint8 minScore;
        uint256 freePerMonth;
        uint256 excessFee;
    }

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Role for administrative operations (set fees, tiers)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for UUPS upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Number of fee tiers
    uint256 public constant TIER_COUNT = 5;

    /// @notice Bulk message fee multiplier (10x)
    uint256 public constant BULK_FEE_MULTIPLIER = 10;

    /// @notice Target block time in seconds (Subnet-EVM `targetBlockRate`)
    /// @dev OmniCoin L1 produces one block every ~2 seconds
    uint256 private constant BLOCK_SECONDS = 2;

    /// @notice Blocks in 30 days (approximate month)
    /// @dev Anchored to block.number, which cannot be manipulated by a
    ///      block producer the way block.timestamp can (S-01).
    uint256 private constant MONTH_BLOCKS = (30 days) / BLOCK_SECONDS;

    /// @notice Minimum fee per paid message (0.001 XOM = 1e15 wei)
    /// @dev Prevents fees rounding to zero
    uint256 public constant MIN_FEE = 1e15;

    /// @notice Maximum excess fee per message (1000 XOM)
    /// @dev Prevents accidental or malicious fee escalation
    uint256 public constant MAX_EXCESS_FEE = 1000e18;

    /// @notice Maximum bulk fee per message = MAX_EXCESS_FEE × BULK_FEE_MULTIPLIER
    /// @dev Bounds the post-multiplier bulk fee (RT-AC-04): the single-message
    ///      cap alone left the bulk path able to charge 10× the stated ceiling.
    uint256 public constant MAX_BULK_FEE =
        MAX_EXCESS_FEE * BULK_FEE_MULTIPLIER;

    /// @notice Sentinel value for unlimited free messages
    uint256 public constant UNLIMITED = type(uint256).max;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice XOM token
    IERC20 public xomToken;

    /// @notice UnifiedFeeVault (receives 100% of fees for distribution)
    address public feeVault;

    /// @notice OmniParticipation contract for score lookups
    IParticipationScorer public participation;

    /// @notice Fee tier configurations (index 0 = lowest, 4 = highest)
    TierConfig[5] public tiers;

    /// @notice Per-user monthly non-marketplace message count:
    ///         user => month => count
    mapping(address => mapping(uint256 => uint256))
        public monthlyMessageCount;

    /// @notice Payment proof: user => channel => messageIndex => bool
    mapping(address => mapping(bytes32 => mapping(uint256 => bool)))
        public paymentProofs;

    /// @notice Per-user total message index (monotonically increasing)
    mapping(address => uint256) public userMessageIndex;

    /// @notice Marketplace message proof:
    ///         user => listingId => messageIndex => bool
    mapping(address =>
        mapping(bytes32 => mapping(uint256 => bool)))
        public marketplaceProofs;

    /// @notice Total fees collected (in XOM wei)
    uint256 public totalFeesCollected;

    /// @notice Total marketplace messages sent (no fees)
    uint256 public totalMarketplaceMessages;

    /// @notice Storage gap for future upgrades
    /// @dev Prevents storage collision when adding state in V3+
    uint256[40] private __gap;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a message fee is paid (excess tier)
    /// @param user Address that paid the fee
    /// @param channelId Chat channel identifier
    /// @param validator Validator hosting the channel for the message
    /// @param messageIndex User's global message index
    /// @param fee Amount of XOM paid
    /// @param tier User's participation tier at time of payment
    event MessageFeePaid(
        address indexed user,
        bytes32 indexed channelId,
        address indexed validator,
        uint256 messageIndex,
        uint256 fee,
        uint8 tier
    );

    /// @notice Emitted when a free-tier message is used
    /// @param user Address that sent the free message
    /// @param channelId Chat channel identifier
    /// @param messageIndex User's global message index
    /// @param remaining Free messages remaining this month
    /// @param tier User's participation tier
    event FreeMessageUsed(
        address indexed user,
        bytes32 indexed channelId,
        uint256 messageIndex,
        uint256 remaining,
        uint8 tier
    );

    /// @notice Emitted for marketplace (escrow-gated) messages
    /// @param user Address that sent the marketplace message
    /// @param listingId Marketplace listing identifier
    /// @param messageIndex User's global message index
    event MarketplaceMessageSent(
        address indexed user,
        bytes32 indexed listingId,
        uint256 messageIndex
    );

    /// @notice Emitted when tier configuration is updated
    /// @param tierIndex Which tier was updated (0-4)
    /// @param minScore New minimum participation score
    /// @param freePerMonth New free message count per month
    /// @param excessFee New excess fee per message
    event TierUpdated(
        uint8 indexed tierIndex,
        uint8 minScore,
        uint256 freePerMonth,
        uint256 excessFee
    );

    /// @notice Emitted when the participation contract is updated
    /// @param oldParticipation Previous participation contract
    /// @param newParticipation New participation contract
    event ParticipationContractUpdated(
        address indexed oldParticipation,
        address indexed newParticipation
    );

    /// @notice Emitted when the fee vault address is updated
    /// @param oldFeeVault Previous fee vault address
    /// @param newFeeVault New fee vault address
    event FeeVaultUpdated(
        address indexed oldFeeVault,
        address indexed newFeeVault
    );

    // ══════════════════════════════════════════════════════════════════
    //                     INITIALIZER (replaces constructor)
    // ══════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the chat fee contract
     * @dev Sets up default 5-tier configuration matching the plan:
     *      Tier 0 (Anonymous):   score 0-9,   5 free,   25 XOM
     *      Tier 1 (Basic):       score 10-24, 20 free,  10 XOM
     *      Tier 2 (Established): score 25-49, 100 free,  5 XOM
     *      Tier 3 (Trusted):     score 50-74, 500 free,  1 XOM
     *      Tier 4 (Elite):       score 75+,   unlimited, 0 XOM
     * @param _xomToken XOM token address
     * @param _feeVault UnifiedFeeVault address
     * @param _participation OmniParticipation contract address
     */
    function initialize(
        address _xomToken,
        address _feeVault,
        address _participation
    ) external initializer {
        if (_xomToken == address(0)) revert ZeroChatAddress();
        if (_feeVault == address(0)) revert ZeroChatAddress();
        if (_participation == address(0)) revert ZeroChatAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        xomToken = IERC20(_xomToken);
        feeVault = _feeVault;
        participation = IParticipationScorer(_participation);

        // Default tier configuration
        tiers[0] = TierConfig({
            minScore: 0,
            freePerMonth: 5,
            excessFee: 25e18
        });
        tiers[1] = TierConfig({
            minScore: 10,
            freePerMonth: 20,
            excessFee: 10e18
        });
        tiers[2] = TierConfig({
            minScore: 25,
            freePerMonth: 100,
            excessFee: 5e18
        });
        tiers[3] = TierConfig({
            minScore: 50,
            freePerMonth: 500,
            excessFee: 1e18
        });
        tiers[4] = TierConfig({
            minScore: 75,
            freePerMonth: UNLIMITED,
            excessFee: 0
        });
    }

    // ══════════════════════════════════════════════════════════════════
    //                        FEE PAYMENT
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Pay fee for a single message
     * @dev Determines user's tier from participation score,
     *      uses free tier if available, otherwise charges
     *      the tier-specific excess fee. CEI-compliant.
     * @param channelId Chat channel identifier
     * @param validator Validator hosting the channel
     */
    function payMessageFee(
        bytes32 channelId,
        address validator
    ) external whenNotPaused nonReentrant {
        if (channelId == bytes32(0)) revert InvalidChannelId();
        if (validator == address(0)) revert ZeroChatAddress();

        address caller = _msgSender();
        uint8 tierIdx = getUserTier(caller);
        TierConfig memory tier = tiers[tierIdx];
        uint256 month = _currentMonth();
        uint256 used = monthlyMessageCount[caller][month];
        uint256 msgIndex = userMessageIndex[caller];
        ++userMessageIndex[caller];

        if (tier.freePerMonth == UNLIMITED || used < tier.freePerMonth) {
            // Free tier — CEI: state before events
            monthlyMessageCount[caller][month] = used + 1;
            paymentProofs[caller][channelId][msgIndex] = true;

            uint256 remaining = tier.freePerMonth == UNLIMITED
                ? UNLIMITED
                : tier.freePerMonth - used - 1;

            emit FreeMessageUsed(
                caller, channelId, msgIndex, remaining, tierIdx
            );
        } else {
            // Paid message — CEI: state before external calls
            monthlyMessageCount[caller][month] = used + 1;
            paymentProofs[caller][channelId][msgIndex] = true;
            // Emit the ACTUAL charged amount: _collectFee raises sub-floor
            // fees to MIN_FEE, so emitting tier.excessFee would make the
            // event disagree with the vault transfer.
            uint256 charged = _collectFee(caller, tier.excessFee);

            emit MessageFeePaid(
                caller, channelId, validator, msgIndex, charged, tierIdx
            );
        }
    }

    /**
     * @notice Pay fee for a bulk/broadcast message (10x excess fee)
     * @dev Always charges full bulk fee regardless of free tier.
     *      Bulk messaging is an anti-spam mechanism that must
     *      always be paid. Elite tier (0 excess) pays 0 for bulk.
     *      CEI-compliant.
     * @param channelId Chat channel identifier
     * @param validator Validator hosting the channel
     */
    function payBulkMessageFee(
        bytes32 channelId,
        address validator
    ) external whenNotPaused nonReentrant {
        if (channelId == bytes32(0)) revert InvalidChannelId();
        if (validator == address(0)) revert ZeroChatAddress();

        address caller = _msgSender();
        uint8 tierIdx = getUserTier(caller);
        uint256 fee = tiers[tierIdx].excessFee * BULK_FEE_MULTIPLIER;
        // RT-AC-04: enforce the bulk ceiling POST-multiplier so the bulk path
        // can never charge more than MAX_BULK_FEE per message, regardless of
        // future changes to BULK_FEE_MULTIPLIER or tier configuration.
        if (fee > MAX_BULK_FEE) revert FeeExceedsMaximum();
        uint256 month = _currentMonth();
        uint256 msgIndex = userMessageIndex[caller];
        ++userMessageIndex[caller];

        // CEI: state before external calls
        ++monthlyMessageCount[caller][month];
        paymentProofs[caller][channelId][msgIndex] = true;

        if (fee > 0) {
            // Emit the ACTUAL charged amount (raised to MIN_FEE when
            // below), mirroring the single-message path so the event
            // always agrees with the vault transfer.
            fee = _collectFee(caller, fee);
        }

        emit MessageFeePaid(
            caller, channelId, validator, msgIndex, fee, tierIdx
        );
    }

    /**
     * @notice Record a marketplace (escrow-gated) message
     * @dev Marketplace messages are always free. The escrow deposit
     *      is the anti-spam mechanism. Does NOT increment monthly
     *      message count (no quota impact). Both buyer and seller
     *      benefit from this exemption.
     * @param listingId Marketplace listing identifier (non-zero)
     * @param channelId Chat channel for payment proof lookup
     */
    function payMarketplaceMessageFee(
        bytes32 listingId,
        bytes32 channelId
    ) external whenNotPaused nonReentrant {
        if (listingId == bytes32(0)) revert InvalidListingId();
        if (channelId == bytes32(0)) revert InvalidChannelId();

        address caller = _msgSender();
        uint256 msgIndex = userMessageIndex[caller];
        ++userMessageIndex[caller];

        // Record the marketplace proof ONLY in `marketplaceProofs` — never
        // in `paymentProofs`. `paymentProofs` is what `hasValidPayment`
        // (the paid-message/quota gate) reads, so writing it here would
        // let any caller mint a free paid-message proof for an arbitrary
        // channel and bypass the tier fee (anti-spam) entirely.
        marketplaceProofs[caller][listingId][msgIndex] = true;
        ++totalMarketplaceMessages;

        emit MarketplaceMessageSent(caller, listingId, msgIndex);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Determine the fee tier index for a user
     * @dev Iterates tiers from highest (4) to lowest (0), returning
     *      the first tier whose minScore the user meets. This is
     *      the canonical tier determination used by all fee methods.
     * @param user Address to check
     * @return tierIndex The tier index (0-4)
     */
    function getUserTier(
        address user
    ) public view returns (uint8 tierIndex) {
        // RT-OB-02: a reverting participation scorer must not halt every
        // message. Wrap the external score lookup in a try/catch and fail
        // OPEN to the Anonymous tier (score 0) — the highest-fee tier is the
        // safe default when the score is unknowable, and messaging stays up.
        uint256 score;
        try participation.getTotalScore(user) returns (uint256 s) {
            score = s;
        } catch {
            score = 0;
        }
        return _getUserTier(score);
    }

    /**
     * @notice Determine the fee tier index for a given score
     * @dev Iterates tiers from highest (4) to lowest (0), returning
     *      the first tier whose minScore the score meets. Kept internal
     *      so callers that already hold a score can avoid a second
     *      `participation.getTotalScore()` external call (M-02).
     * @param score Participation score (0-100)
     * @return tierIndex The tier index (0-4)
     */
    function _getUserTier(
        uint256 score
    ) internal view returns (uint8 tierIndex) {
        // Iterate from highest tier downward
        for (uint256 i = TIER_COUNT; i > 0;) {
            unchecked { --i; }
            if (score >= tiers[i].minScore) {
                return uint8(i);
            }
        }
        return 0;
    }

    /**
     * @notice Check if a user has valid payment for a message
     * @dev Called by validator before relaying a message
     * @param user User address
     * @param channelId Channel identifier
     * @param messageIndex Message index
     * @return True if payment proof exists (free, paid, or marketplace)
     */
    function hasValidPayment(
        address user,
        bytes32 channelId,
        uint256 messageIndex
    ) external view returns (bool) {
        return paymentProofs[user][channelId][messageIndex];
    }

    /**
     * @notice Check if a message was a marketplace message
     * @dev Used by validators to verify marketplace exemption
     * @param user User address
     * @param listingId Listing identifier
     * @param messageIndex Message index
     * @return True if message was marketplace-exempt
     */
    function isMarketplaceMessage(
        address user,
        bytes32 listingId,
        uint256 messageIndex
    ) external view returns (bool) {
        return marketplaceProofs[user][listingId][messageIndex];
    }

    /**
     * @notice Get remaining free messages for user this month
     * @dev Returns UNLIMITED for Elite tier (score >= 75)
     * @param user User address
     * @return remaining Free messages remaining (UNLIMITED if uncapped)
     */
    function freeMessagesRemaining(
        address user
    ) external view returns (uint256 remaining) {
        uint8 tierIdx = getUserTier(user);
        TierConfig memory tier = tiers[tierIdx];

        if (tier.freePerMonth == UNLIMITED) return UNLIMITED;

        uint256 month = _currentMonth();
        uint256 used = monthlyMessageCount[user][month];
        if (used >= tier.freePerMonth) return 0;
        return tier.freePerMonth - used;
    }

    /**
     * @notice Get the excess fee for a user based on their tier
     * @dev Convenience view for frontends/validators
     * @param user User address
     * @return fee Excess fee in XOM (18 decimals), 0 for Elite
     */
    function getExcessFee(
        address user
    ) external view returns (uint256 fee) {
        return tiers[getUserTier(user)].excessFee;
    }

    /**
     * @notice Get current month identifier
     * @dev 30-day approximation: block.number / MONTH_BLOCKS
     * @return Month number
     */
    function currentMonth() external view returns (uint256) {
        return _currentMonth();
    }

    /**
     * @notice Get user's next message index
     * @param user User address
     * @return Next message index
     */
    function nextMessageIndex(
        address user
    ) external view returns (uint256) {
        return userMessageIndex[user];
    }

    /**
     * @notice Get full tier configuration for a tier index
     * @param tierIndex Tier index (0-4)
     * @return minScore Minimum participation score
     * @return freePerMonth Free messages per month
     * @return excessFee Fee after free tier exhausted
     */
    function getTierConfig(
        uint8 tierIndex
    ) external view returns (
        uint8 minScore,
        uint256 freePerMonth,
        uint256 excessFee
    ) {
        TierConfig memory t = tiers[tierIndex];
        return (t.minScore, t.freePerMonth, t.excessFee);
    }

    /**
     * @notice Get complete user fee info in a single call
     * @dev Gas-efficient: single call returns everything frontends need
     * @param user User address
     * @return tierIndex Current tier (0-4)
     * @return freeRemaining Free messages remaining this month
     * @return excessFee Per-message fee after free tier
     * @return monthlyUsed Messages used this month
     * @return score Participation score (0-100)
     */
    function getUserFeeInfo(
        address user
    ) external view returns (
        uint8 tierIndex,
        uint256 freeRemaining,
        uint256 excessFee,
        uint256 monthlyUsed,
        uint256 score
    ) {
        // RT-OB-02 (completeness): keep this view consistent with the
        // guarded getUserTier so the fee-info display cannot diverge from
        // the charging path when the participation scorer reverts.
        uint256 resolved;
        try participation.getTotalScore(user) returns (uint256 s) {
            resolved = s;
        } catch {
            resolved = 0;
        }
        score = resolved;
        tierIndex = _getUserTier(resolved);
        TierConfig memory tier = tiers[tierIndex];

        uint256 month = _currentMonth();
        monthlyUsed = monthlyMessageCount[user][month];
        excessFee = tier.excessFee;

        if (tier.freePerMonth == UNLIMITED) {
            freeRemaining = UNLIMITED;
        } else if (monthlyUsed >= tier.freePerMonth) {
            freeRemaining = 0;
        } else {
            freeRemaining = tier.freePerMonth - monthlyUsed;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update a specific tier configuration
     * @dev Tiers must remain in ascending minScore order. The excess
     *      fee must not exceed MAX_EXCESS_FEE. Tier 0 must have
     *      minScore of 0.
     * @param tierIndex Tier index to update (0-4)
     * @param minScore Minimum participation score
     * @param freePerMonth Free messages per month (UNLIMITED for no cap)
     * @param excessFee Fee per excess message (18 decimals)
     */
    function setTier(
        uint8 tierIndex,
        uint8 minScore,
        uint256 freePerMonth,
        uint256 excessFee
    ) external onlyRole(ADMIN_ROLE) {
        if (tierIndex >= TIER_COUNT) revert InvalidTierConfig();
        if (tierIndex == 0 && minScore != 0) revert InvalidTierConfig();
        if (excessFee > MAX_EXCESS_FEE) revert FeeExceedsMaximum();

        // Ensure ascending minScore order
        if (tierIndex > 0 &&
            minScore <= tiers[tierIndex - 1].minScore) {
            revert InvalidTierConfig();
        }
        if (tierIndex < TIER_COUNT - 1 &&
            minScore >= tiers[tierIndex + 1].minScore) {
            revert InvalidTierConfig();
        }

        tiers[tierIndex] = TierConfig({
            minScore: minScore,
            freePerMonth: freePerMonth,
            excessFee: excessFee
        });

        emit TierUpdated(tierIndex, minScore, freePerMonth, excessFee);
    }

    /**
     * @notice Update the OmniParticipation contract reference
     * @dev Required if OmniParticipation is upgraded to a new proxy
     * @param newParticipation New OmniParticipation proxy address
     */
    function setParticipationContract(
        address newParticipation
    ) external onlyRole(ADMIN_ROLE) {
        if (newParticipation == address(0)) revert ZeroChatAddress();
        address old = address(participation);
        participation = IParticipationScorer(newParticipation);
        emit ParticipationContractUpdated(old, newParticipation);
    }

    /**
     * @notice Update the fee vault address
     * @dev Required if UnifiedFeeVault is redeployed
     * @param newFeeVault New UnifiedFeeVault address
     */
    function setFeeVault(
        address newFeeVault
    ) external onlyRole(ADMIN_ROLE) {
        if (newFeeVault == address(0)) revert ZeroChatAddress();
        address old = feeVault;
        feeVault = newFeeVault;
        emit FeeVaultUpdated(old, newFeeVault);
    }

    /**
     * @notice Pause all message-fee collection (circuit breaker)
     * @dev Only callable by ADMIN_ROLE. Halts payMessageFee(),
     *      payBulkMessageFee(), and payMarketplaceMessageFee() in an
     *      emergency (e.g. OmniParticipation failure). Admin config
     *      functions remain callable so the issue can be fixed.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Resume message-fee collection after an emergency
     * @dev Only callable by ADMIN_ROLE.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Collect fee from user and send to UnifiedFeeVault
     * @dev Enforces MIN_FEE floor to prevent precision-loss.
     *      Vault handles 70/20/10 distribution.
     * @param user User paying the fee
     * @param fee Total fee amount
     * @return The amount actually charged (fee raised to MIN_FEE when below)
     */
    function _collectFee(
        address user,
        uint256 fee
    ) internal returns (uint256) {
        if (fee < MIN_FEE) fee = MIN_FEE;
        // S-02: Record the actual received amount via balance delta, so
        // totalFeesCollected stays accurate even if the token applies a
        // transfer fee (fee-on-transfer) on the way to the vault.
        uint256 before = xomToken.balanceOf(feeVault);
        xomToken.safeTransferFrom(user, feeVault, fee);
        uint256 received = xomToken.balanceOf(feeVault) - before;
        totalFeesCollected += received;
        return fee;
    }

    /**
     * @notice Get current month identifier
     * @dev 30-day approximation anchored to block.number, which is not
     *      miner-manipulable (unlike block.timestamp).
     * @return Month number based on block.number
     */
    function _currentMonth() internal view returns (uint256) {
        return block.number / MONTH_BLOCKS;
    }

    /**
     * @notice Authorize UUPS upgrade
     * @dev Only UPGRADER_ROLE can upgrade the implementation
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {} // solhint-disable-line no-empty-blocks

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
