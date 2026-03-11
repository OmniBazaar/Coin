// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from
    "@openzeppelin/contracts/utils/Context.sol";

// ══════════════════════════════════════════════════════════════════════
//                           CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════════════

/// @notice Channel ID is zero
error InvalidChannelId();

/// @notice Insufficient XOM allowance for fee payment
error InsufficientAllowance();

/// @notice Monthly message index exceeds free tier
error FreeTierExhausted(uint256 used, uint256 limit);

/// @notice Zero address provided
error ZeroChatAddress();

/// @notice Base fee cannot be zero (disables anti-spam)
error ZeroBaseFee();

/// @notice Both recipient addresses are zero (no-op)
error NoRecipientsProvided();

/// @notice Recipient update timelock has not elapsed
error RecipientTimelockActive();

/// @notice No recipient update has been scheduled
error NoRecipientUpdateScheduled();

/**
 * @title OmniChatFee
 * @author OmniBazaar Team
 * @notice Trustless chat fee management for OmniBazaar messaging
 *
 * @dev Lightweight, non-upgradeable contract handling per-message
 *      fees with a free tier (20 messages/month per user). Prevents
 *      validators from waiving fees selectively, overcharging users,
 *      or pocketing fees without delivering messages.
 *
 * Features:
 * - Pay-per-message: user calls payMessageFee(channelId)
 * - Free tier: first 20 messages/month tracked on-chain
 * - Fee distribution: 70% ODDAO, 20% Staking Pool, 10% Protocol
 * - Proof of payment: hasValidPayment() for validator verification
 * - Bulk messaging: 10x fee for broadcast (anti-spam, always paid)
 * - Monthly reset: based on block.timestamp month boundaries
 * - Minimum fee enforcement to prevent precision-loss rounding to 0
 *
 * Security:
 * - Non-upgradeable (immutable once deployed)
 * - Ownable2Step (two-step ownership transfer)
 * - ReentrancyGuard on all transfers
 * - On-chain payment proof prevents fee manipulation
 * - CEI-compliant: state updates before external calls
 */
contract OmniChatFee is ReentrancyGuard, Ownable2Step, ERC2771Context {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Free messages per user per month
    uint256 public constant FREE_TIER_LIMIT = 20;

    /// @notice Bulk message fee multiplier (10x)
    uint256 public constant BULK_FEE_MULTIPLIER = 10;

    /// @notice Fee split: ODDAO treasury (7000 = 70%)
    uint256 public constant ODDAO_SHARE = 7000;

    /// @notice Fee split: staking pool (2000 = 20%)
    uint256 public constant STAKING_SHARE = 2000;

    /// @notice Fee split: protocol treasury (1000 = 10%)
    uint256 public constant PROTOCOL_SHARE = 1000;

    /// @notice Basis points denominator
    uint256 private constant BPS = 10_000;

    /// @notice Seconds in 30 days (approximate month)
    uint256 private constant MONTH_SECONDS = 30 days;

    /// @notice Minimum fee per message (0.001 XOM = 1e15 wei)
    /// @dev Prevents precision loss when fee splits round to zero
    uint256 public constant MIN_FEE = 1e15;

    /// @notice Timelock delay for recipient address changes (24 hours)
    /// @dev M-02 Round 6: prevents a compromised owner key from
    ///      immediately redirecting all fee revenue. Gives the
    ///      community 24 hours to detect and react to malicious
    ///      recipient changes.
    uint256 public constant RECIPIENT_TIMELOCK = 24 hours;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice XOM token
    IERC20 public immutable xomToken;

    /// @notice Staking pool address (receives 20%)
    address public stakingPool;

    /// @notice ODDAO treasury (receives 70%)
    address public oddaoTreasury;

    /// @notice Protocol treasury (receives 10%)
    address public protocolTreasury;

    /// @notice Base fee per message in XOM (18 decimals)
    uint256 public baseFee;

    /// @notice Per-user payment tracking:
    ///         user => month => messageCount
    mapping(address => mapping(uint256 => uint256))
        public monthlyMessageCount;

    /// @notice Payment proof: user => channel => messageIndex => bool
    mapping(address => mapping(bytes32 => mapping(uint256 => bool)))
        public paymentProofs;

    /// @notice Per-user total message index (monotonically increasing)
    mapping(address => uint256) public userMessageIndex;

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

    /// @notice Pending staking pool address for timelocked update
    address public pendingStakingPool;

    /// @notice Pending ODDAO treasury address for timelocked update
    address public pendingOddaoTreasury;

    /// @notice Timestamp when recipient update was scheduled
    /// @dev Zero means no update is pending
    uint256 public recipientUpdateScheduledAt;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a message fee is paid
    /// @param user Address that paid the fee
    /// @param channelId Chat channel identifier
    /// @param messageIndex User's global message index
    /// @param fee Amount of XOM paid
    /// @param validator Validator that will receive the fee share
    event MessageFeePaid(
        address indexed user,
        bytes32 indexed channelId,
        uint256 messageIndex,
        uint256 fee,
        address validator
    );

    /// @notice Emitted when free tier message is used
    /// @param user Address that sent the free message
    /// @param channelId Chat channel identifier
    /// @param messageIndex User's global message index
    /// @param remaining Free messages remaining this month
    event FreeMessageUsed(
        address indexed user,
        bytes32 indexed channelId,
        uint256 messageIndex,
        uint256 remaining
    );

    /// @notice Emitted when base fee is updated
    /// @param oldFee Previous base fee in XOM
    /// @param newFee New base fee in XOM
    event BaseFeeUpdated(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when fee recipient addresses are updated
    /// @param stakingPool New staking pool address
    /// @param oddaoTreasury New ODDAO treasury address
    /// @param protocolTreasury New protocol treasury address
    event RecipientsUpdated(
        address stakingPool,
        address oddaoTreasury,
        address protocolTreasury
    );

    /// @notice Emitted when a recipient update is scheduled
    /// @param newStakingPool Pending staking pool address
    /// @param newOddaoTreasury Pending ODDAO treasury address
    /// @param readyAt Timestamp when the update can be executed
    event RecipientUpdateScheduled(
        address newStakingPool,
        address newOddaoTreasury,
        uint256 readyAt
    );

    /// @notice Emitted when a scheduled recipient update is cancelled
    event RecipientUpdateCancelled();

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the chat fee contract
     * @dev Validates all addresses are non-zero and base fee meets
     *      minimum threshold.
     * @param _xomToken XOM token address
     * @param _stakingPool Staking pool address (20%)
     * @param _oddaoTreasury ODDAO treasury address (10%)
     * @param _protocolTreasury Protocol treasury address (legacy)
     * @param _baseFee Base fee per message in XOM (18 decimals)
     * @param trustedForwarder_ OmniForwarder address for gasless
     *        relay (address(0) to disable)
     */
    constructor(
        address _xomToken,
        address _stakingPool,
        address _oddaoTreasury,
        address _protocolTreasury,
        uint256 _baseFee,
        address trustedForwarder_
    ) Ownable(msg.sender) ERC2771Context(trustedForwarder_) {
        if (_xomToken == address(0)) revert ZeroChatAddress();
        if (_stakingPool == address(0)) revert ZeroChatAddress();
        if (_oddaoTreasury == address(0)) revert ZeroChatAddress();
        if (_protocolTreasury == address(0)) revert ZeroChatAddress();
        if (_baseFee == 0) revert ZeroBaseFee();

        xomToken = IERC20(_xomToken);
        stakingPool = _stakingPool;
        oddaoTreasury = _oddaoTreasury;
        protocolTreasury = _protocolTreasury;
        baseFee = _baseFee;
    }

    // ══════════════════════════════════════════════════════════════════
    //                        FEE PAYMENT
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Pay fee for a single message
     * @dev Uses free tier if available, otherwise charges baseFee.
     *      Validator address is recorded for fee distribution.
     *      M-01 fix: State updates (CEI) occur before external calls.
     * @param channelId Chat channel identifier
     * @param validator Validator hosting the channel
     */
    function payMessageFee(
        bytes32 channelId,
        address validator
    ) external nonReentrant {
        if (channelId == bytes32(0)) revert InvalidChannelId();
        if (validator == address(0)) revert ZeroChatAddress();

        address caller = _msgSender();
        uint256 month = _currentMonth();
        uint256 used = monthlyMessageCount[caller][month];
        uint256 msgIndex = userMessageIndex[caller]++;

        if (used < FREE_TIER_LIMIT) {
            // Free tier
            monthlyMessageCount[caller][month] = used + 1;
            paymentProofs[caller][channelId][msgIndex] = true;

            emit FreeMessageUsed(
                caller,
                channelId,
                msgIndex,
                FREE_TIER_LIMIT - used - 1
            );
        } else {
            // Paid message — CEI: update state before external calls
            monthlyMessageCount[caller][month] = used + 1;
            paymentProofs[caller][channelId][msgIndex] = true;
            _collectFee(caller, baseFee);

            emit MessageFeePaid(
                caller,
                channelId,
                msgIndex,
                baseFee,
                validator
            );
        }
    }

    /**
     * @notice Pay fee for a bulk/broadcast message (10x base fee)
     * @dev Always charges the full bulk fee regardless of free tier
     *      status. This is intentional: bulk messaging is an anti-spam
     *      mechanism and must always be paid.
     *      M-01 fix: State updates (CEI) occur before external calls.
     * @param channelId Chat channel identifier
     * @param validator Validator hosting the channel
     */
    function payBulkMessageFee(
        bytes32 channelId,
        address validator
    ) external nonReentrant {
        if (channelId == bytes32(0)) revert InvalidChannelId();
        if (validator == address(0)) revert ZeroChatAddress();

        address caller = _msgSender();
        uint256 fee = baseFee * BULK_FEE_MULTIPLIER;
        uint256 month = _currentMonth();
        uint256 msgIndex = userMessageIndex[caller]++;

        // CEI: update state before external calls
        monthlyMessageCount[caller][month]++;
        paymentProofs[caller][channelId][msgIndex] = true;
        _collectFee(caller, fee);

        emit MessageFeePaid(
            caller,
            channelId,
            msgIndex,
            fee,
            validator
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a user has valid payment for a message
     * @dev Called by validator before relaying a message
     * @param user User address
     * @param channelId Channel identifier
     * @param messageIndex Message index
     * @return True if payment exists (free or paid)
     */
    function hasValidPayment(
        address user,
        bytes32 channelId,
        uint256 messageIndex
    ) external view returns (bool) {
        return paymentProofs[user][channelId][messageIndex];
    }

    /**
     * @notice Get remaining free messages for user this month
     * @param user User address
     * @return remaining Messages remaining in free tier
     */
    function freeMessagesRemaining(
        address user
    ) external view returns (uint256 remaining) {
        uint256 month = _currentMonth();
        uint256 used = monthlyMessageCount[user][month];
        if (used >= FREE_TIER_LIMIT) return 0;
        return FREE_TIER_LIMIT - used;
    }

    /**
     * @notice Get the current month identifier
     * @dev Month number computed as block.timestamp / 30 days.
     *      This is a 30-day approximation and does not align
     *      precisely with calendar months (28-31 days).
     * @return Month number (block.timestamp / 30 days)
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

    // ══════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update base fee (owner only)
     * @dev L-01 fix: Rejects zero value to prevent disabling all
     *      fee collection and the anti-spam mechanism.
     * @param newBaseFee New base fee in XOM (18 decimals)
     */
    function setBaseFee(uint256 newBaseFee) external onlyOwner {
        if (newBaseFee == 0) revert ZeroBaseFee();
        uint256 oldFee = baseFee;
        baseFee = newBaseFee;
        emit BaseFeeUpdated(oldFee, newBaseFee);
    }

    /**
     * @notice Schedule a recipient address update with timelock
     * @dev M-02 Round 6: recipient updates are timelocked to prevent
     *      a compromised owner from immediately redirecting fees.
     *      Pass address(0) for any param to leave it unchanged when
     *      the update is executed.
     * @param _stakingPool New staking pool address (0 = no change)
     * @param _oddaoTreasury New ODDAO treasury address (0 = no change)
     */
    function scheduleRecipientUpdate(
        address _stakingPool,
        address _oddaoTreasury
    ) external onlyOwner {
        if (
            _stakingPool == address(0) &&
            _oddaoTreasury == address(0)
        ) {
            revert NoRecipientsProvided();
        }
        pendingStakingPool = _stakingPool;
        pendingOddaoTreasury = _oddaoTreasury;
        // solhint-disable-next-line not-rely-on-time
        recipientUpdateScheduledAt = block.timestamp;

        emit RecipientUpdateScheduled(
            _stakingPool,
            _oddaoTreasury,
            block.timestamp + RECIPIENT_TIMELOCK // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Execute a previously scheduled recipient update
     * @dev Can only be called after RECIPIENT_TIMELOCK has elapsed.
     *      Applies the pending addresses and clears the schedule.
     */
    function executeRecipientUpdate() external onlyOwner {
        if (recipientUpdateScheduledAt == 0) {
            revert NoRecipientUpdateScheduled();
        }
        if (
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
                < recipientUpdateScheduledAt + RECIPIENT_TIMELOCK
        ) {
            revert RecipientTimelockActive();
        }

        if (pendingStakingPool != address(0)) {
            stakingPool = pendingStakingPool;
        }
        if (pendingOddaoTreasury != address(0)) {
            oddaoTreasury = pendingOddaoTreasury;
        }

        // Clear pending state
        pendingStakingPool = address(0);
        pendingOddaoTreasury = address(0);
        recipientUpdateScheduledAt = 0;

        emit RecipientsUpdated(
            stakingPool, oddaoTreasury, protocolTreasury
        );
    }

    /**
     * @notice Cancel a previously scheduled recipient update
     * @dev Clears the pending addresses and schedule timestamp
     */
    function cancelRecipientUpdate() external onlyOwner {
        if (recipientUpdateScheduledAt == 0) {
            revert NoRecipientUpdateScheduled();
        }

        pendingStakingPool = address(0);
        pendingOddaoTreasury = address(0);
        recipientUpdateScheduledAt = 0;

        emit RecipientUpdateCancelled();
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Collect fee from user and distribute
     * @dev Fee split: 70% ODDAO treasury, 20% staking pool,
     *      10% protocol treasury. Enforces MIN_FEE floor to
     *      prevent precision-loss rounding to zero.
     * @param user User paying the fee
     * @param fee Total fee amount
     */
    function _collectFee(
        address user,
        uint256 fee
    ) internal {
        // Enforce minimum fee to prevent precision loss
        if (fee < MIN_FEE) fee = MIN_FEE;

        // Transfer full fee from user to this contract
        xomToken.safeTransferFrom(user, address(this), fee);

        // Calculate splits
        uint256 stakingAmount = (fee * STAKING_SHARE) / BPS;
        uint256 protocolAmount = (fee * PROTOCOL_SHARE) / BPS;
        // ODDAO gets remainder (avoids rounding dust)
        uint256 oddaoAmount =
            fee - stakingAmount - protocolAmount;

        // Distribute: 70% ODDAO, 20% staking, 10% protocol
        xomToken.safeTransfer(oddaoTreasury, oddaoAmount);
        xomToken.safeTransfer(stakingPool, stakingAmount);
        xomToken.safeTransfer(protocolTreasury, protocolAmount);

        totalFeesCollected += fee;
    }

    /**
     * @notice Get current month identifier
     * @dev I-02: Uses 30-day approximation. Does not align with
     *      calendar months but is acceptable for on-chain simplicity.
     * @return Month number based on block.timestamp
     */
    function _currentMonth() internal view returns (uint256) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp / MONTH_SECONDS;
    }

    // ══════════════════════════════════════════════════════════════════
    //     ERC2771Context Overrides (resolve diamond with Ownable)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve _msgSender between Context (via Ownable)
     *         and ERC2771Context
     * @dev Returns the original user address when called through
     *      the trusted forwarder. Used by payMessageFee() and
     *      payBulkMessageFee() to identify the actual user.
     * @return The original transaction signer when relayed, or
     *         msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve _msgData between Context (via Ownable)
     *         and ERC2771Context
     * @dev Strips the appended sender address from calldata
     *      when relayed
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between Context
     *         and ERC2771Context
     * @dev Returns 20 (address length) for ERC2771 context
     *      suffix stripping
     * @return The number of bytes appended to calldata by the
     *         forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}
