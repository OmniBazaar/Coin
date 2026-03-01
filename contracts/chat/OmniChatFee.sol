// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";

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
 * - Fee distribution: 70% validator, 20% staking pool, 10% ODDAO
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
contract OmniChatFee is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                            CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Free messages per user per month
    uint256 public constant FREE_TIER_LIMIT = 20;

    /// @notice Bulk message fee multiplier (10x)
    uint256 public constant BULK_FEE_MULTIPLIER = 10;

    /// @notice Fee split: validator/host (7000 = 70%)
    uint256 public constant VALIDATOR_SHARE = 7000;

    /// @notice Fee split: staking pool (2000 = 20%)
    uint256 public constant STAKING_SHARE = 2000;

    /// @notice Fee split: ODDAO (1000 = 10%)
    uint256 public constant ODDAO_SHARE = 1000;

    /// @notice Basis points denominator
    uint256 private constant BPS = 10_000;

    /// @notice Seconds in 30 days (approximate month)
    uint256 private constant MONTH_SECONDS = 30 days;

    /// @notice Minimum fee per message (0.001 XOM = 1e15 wei)
    /// @dev Prevents precision loss when fee splits round to zero
    uint256 public constant MIN_FEE = 1e15;

    // ══════════════════════════════════════════════════════════════════
    //                          STATE VARIABLES
    // ══════════════════════════════════════════════════════════════════

    /// @notice XOM token
    IERC20 public immutable xomToken;

    /// @notice Staking pool address (receives 20%)
    address public stakingPool;

    /// @notice ODDAO treasury (receives 10%)
    address public oddaoTreasury;

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

    /// @notice Accumulated fees per validator (pull pattern)
    mapping(address => uint256) public pendingValidatorFees;

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

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

    /// @notice Emitted when a validator claims fees
    /// @param validator Address of the claiming validator
    /// @param amount Amount of XOM claimed
    event ValidatorFeesClaimed(
        address indexed validator,
        uint256 amount
    );

    /// @notice Emitted when base fee is updated
    /// @param oldFee Previous base fee in XOM
    /// @param newFee New base fee in XOM
    event BaseFeeUpdated(uint256 oldFee, uint256 newFee);

    /// @notice Emitted when fee recipient addresses are updated
    /// @param stakingPool New staking pool address
    /// @param oddaoTreasury New ODDAO treasury address
    event RecipientsUpdated(
        address stakingPool,
        address oddaoTreasury
    );

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the chat fee contract
     * @dev Validates all addresses are non-zero and base fee meets
     *      minimum threshold.
     * @param _xomToken XOM token address
     * @param _stakingPool Staking pool address
     * @param _oddaoTreasury ODDAO treasury address
     * @param _baseFee Base fee per message in XOM (18 decimals)
     */
    constructor(
        address _xomToken,
        address _stakingPool,
        address _oddaoTreasury,
        uint256 _baseFee
    ) Ownable(msg.sender) {
        if (_xomToken == address(0)) revert ZeroChatAddress();
        if (_stakingPool == address(0)) revert ZeroChatAddress();
        if (_oddaoTreasury == address(0)) revert ZeroChatAddress();
        if (_baseFee == 0) revert ZeroBaseFee();

        xomToken = IERC20(_xomToken);
        stakingPool = _stakingPool;
        oddaoTreasury = _oddaoTreasury;
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

        uint256 month = _currentMonth();
        uint256 used = monthlyMessageCount[msg.sender][month];
        uint256 msgIndex = userMessageIndex[msg.sender]++;

        if (used < FREE_TIER_LIMIT) {
            // Free tier
            monthlyMessageCount[msg.sender][month] = used + 1;
            paymentProofs[msg.sender][channelId][msgIndex] = true;

            emit FreeMessageUsed(
                msg.sender,
                channelId,
                msgIndex,
                FREE_TIER_LIMIT - used - 1
            );
        } else {
            // Paid message — CEI: update state before external calls
            monthlyMessageCount[msg.sender][month] = used + 1;
            paymentProofs[msg.sender][channelId][msgIndex] = true;
            _collectFee(msg.sender, baseFee, validator);

            emit MessageFeePaid(
                msg.sender,
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

        uint256 fee = baseFee * BULK_FEE_MULTIPLIER;
        uint256 month = _currentMonth();
        uint256 msgIndex = userMessageIndex[msg.sender]++;

        // CEI: update state before external calls
        monthlyMessageCount[msg.sender][month]++;
        paymentProofs[msg.sender][channelId][msgIndex] = true;
        _collectFee(msg.sender, fee, validator);

        emit MessageFeePaid(
            msg.sender,
            channelId,
            msgIndex,
            fee,
            validator
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //                      VALIDATOR FEE CLAIMS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Validator claims accumulated fees
     * @dev Pull-based pattern: validators call this to withdraw their
     *      accumulated share. Returns silently if no fees pending.
     */
    function claimValidatorFees() external nonReentrant {
        uint256 amount = pendingValidatorFees[msg.sender];
        if (amount == 0) return;

        pendingValidatorFees[msg.sender] = 0;
        xomToken.safeTransfer(msg.sender, amount);

        emit ValidatorFeesClaimed(msg.sender, amount);
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
     * @notice Update fee recipient addresses
     * @dev L-02 fix: Emits RecipientsUpdated event on any change.
     *      Reverts if both addresses are zero (no-op guard).
     *      Pass address(0) for either param to leave it unchanged.
     * @param _stakingPool New staking pool address (0 = no change)
     * @param _oddaoTreasury New ODDAO treasury address (0 = no change)
     */
    function updateRecipients(
        address _stakingPool,
        address _oddaoTreasury
    ) external onlyOwner {
        if (
            _stakingPool == address(0) &&
            _oddaoTreasury == address(0)
        ) {
            revert NoRecipientsProvided();
        }
        if (_stakingPool != address(0)) stakingPool = _stakingPool;
        if (_oddaoTreasury != address(0)) {
            oddaoTreasury = _oddaoTreasury;
        }
        emit RecipientsUpdated(stakingPool, oddaoTreasury);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Collect fee from user and distribute
     * @dev Enforces MIN_FEE floor on all splits to prevent
     *      precision loss from rounding the fee to zero.
     * @param user User paying the fee
     * @param fee Total fee amount
     * @param validator Validator to receive 70% share
     */
    function _collectFee(
        address user,
        uint256 fee,
        address validator
    ) internal {
        // M-01 (precision): Enforce minimum fee
        if (fee < MIN_FEE) fee = MIN_FEE;

        // Transfer full fee from user to this contract
        xomToken.safeTransferFrom(user, address(this), fee);

        // Calculate splits
        uint256 validatorAmount = (fee * VALIDATOR_SHARE) / BPS;
        uint256 stakingAmount = (fee * STAKING_SHARE) / BPS;
        uint256 oddaoAmount = fee - validatorAmount - stakingAmount;

        // Distribute
        pendingValidatorFees[validator] += validatorAmount;
        xomToken.safeTransfer(stakingPool, stakingAmount);
        xomToken.safeTransfer(oddaoTreasury, oddaoAmount);

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
}
