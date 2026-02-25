// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ECDSA
} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    EIP712
} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title DEXSettlement
 * @author OmniCoin Development Team
 * @notice Trustless on-chain trade settlement with
 *         commit-reveal MEV protection
 * @dev Atomic settlement of matched orders with dual
 *      signature verification.
 *
 * Architecture (Trustless):
 * 1. Users commit order hash (optional, MEV protection)
 * 2. Users reveal and sign orders with EIP-712
 * 3. Validators match orders off-chain
 * 4. ANYONE can submit matched orders for settlement
 * 5. Contract verifies signatures + matching logic
 * 6. Atomic swap executed, fees distributed
 *
 * Key Security Features:
 * - No single validator controls settlement
 * - Dual signature verification (both parties sign)
 * - Contract verifies order matching logic
 * - Commit-reveal prevents front-running
 * - Fee attribution to matching validator (not submitter)
 * - Emergency circuit breakers
 * - Intent-based settlement with real token escrow
 *
 * Fee Distribution:
 * - 70% -> ODDAO (governance operations)
 * - 20% -> Staking Pool (incentivizes staking)
 * - 10% -> Matching Validator (processing the trade)
 *
 * Audit Remediations Applied:
 * - H-01: settleIntent() access control
 * - H-02: Token binding in IntentCollateral
 * - H-03: Real token escrow in lockIntentCollateral()
 * - H-04: Fee deducted from input token
 * - H-05: Force-claim pending fees on recipient change
 * - H-06: incrementNonce() for order cancellation
 * - M-01: Nonce bitmap for concurrent orders
 * - M-04: Timelock on critical admin functions
 * - M-06: maxSlippageBps enforced in settlement
 * - M-07: Fee-on-transfer token incompatibility guard
 */
contract DEXSettlement is
    EIP712,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ================================================================
    // STRUCTS (ordered before state per Solidity style guide)
    // ================================================================

    /**
     * @notice Order structure for EIP-712 signing
     * @param trader Address of the trader
     * @param isBuy True if buy order, false if sell order
     * @param tokenIn Token being sold
     * @param tokenOut Token being bought
     * @param amountIn Amount of tokenIn
     * @param amountOut Amount of tokenOut
     * @param price Price in basis points (for matching)
     * @param deadline Order expiration timestamp
     * @param salt Random value for uniqueness
     * @param matchingValidator Validator expected to match
     * @param nonce Unique nonce to prevent replay
     */
    struct Order {
        address trader;
        bool isBuy;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 price;
        uint256 deadline;
        bytes32 salt;
        address matchingValidator;
        uint256 nonce;
    }

    /**
     * @notice Order commitment for MEV protection
     * @param orderHash Hash of the order
     * @param commitBlock Block number when committed
     * @param revealed Whether order has been revealed
     */
    struct Commitment {
        bytes32 orderHash;
        uint256 commitBlock;
        bool revealed;
    }

    /**
     * @notice Fee distribution addresses
     * @param oddao Address of ODDAO treasury (70%)
     * @param stakingPool Address of staking pool (20%)
     */
    struct FeeRecipients {
        address oddao;
        address stakingPool;
    }

    /**
     * @notice Intent collateral record with token binding
     *         and real escrow (H-01, H-02, H-03)
     * @param trader Trader address who created the intent
     * @param locked Whether collateral is locked
     * @param settled Whether settlement is complete
     * @param solver Designated solver address (H-01)
     * @param tokenIn Token the trader is selling (H-02)
     * @param tokenOut Token the trader is buying (H-02)
     * @param traderAmount Amount trader provides (escrowed)
     * @param solverAmount Amount solver must provide
     * @param deadline Settlement deadline timestamp
     */
    struct IntentCollateral {
        address trader; // 20 bytes
        bool locked; // 1 byte  (packed w/ trader)
        bool settled; // 1 byte  (packed w/ trader)
        address solver; // 20 bytes (slot 2)
        address tokenIn; // 20 bytes (slot 3)
        address tokenOut; // 20 bytes (slot 4)
        uint256 traderAmount; // 32 bytes (slot 5)
        uint256 solverAmount; // 32 bytes (slot 6)
        uint256 deadline; // 32 bytes (slot 7)
    }

    // ================================================================
    // CONSTANTS
    // ================================================================

    /* solhint-disable max-line-length,gas-small-strings */
    /// @notice EIP-712 type hash for Order struct
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,bool isBuy,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,uint256 price,uint256 deadline,bytes32 salt,address matchingValidator,uint256 nonce)"
    );
    /* solhint-enable max-line-length,gas-small-strings */

    /// @notice Minimum blocks between commit and reveal
    uint256 public constant MIN_COMMIT_BLOCKS = 2;

    /// @notice Maximum blocks for reveal after commit
    uint256 public constant MAX_COMMIT_BLOCKS = 100;

    /// @notice Maximum slippage in basis points (10%)
    uint256 public constant MAX_SLIPPAGE_BPS = 1000;

    /// @notice Basis points divisor (100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice ODDAO fee share (70%)
    uint256 public constant ODDAO_SHARE = 7000;

    /// @notice Staking pool fee share (20%)
    uint256 public constant STAKING_POOL_SHARE = 2000;

    /// @notice Validator fee share (10%)
    uint256 public constant VALIDATOR_SHARE = 1000;

    /// @notice Spot market maker fee (0.1%)
    uint256 public constant SPOT_MAKER_FEE = 10;

    /// @notice Spot market taker fee (0.2%)
    uint256 public constant SPOT_TAKER_FEE = 20;

    /// @notice Maximum number of tracked fee tokens
    uint256 public constant MAX_FEE_TOKENS = 100;

    /// @notice Timelock delay for critical admin functions (M-04)
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // ================================================================
    // STATE VARIABLES
    // ================================================================

    /// @notice Trader => orderHash => commitment
    mapping(address => mapping(bytes32 => Commitment))
        public commitments;

    /// @notice OrderHash => filled status
    mapping(bytes32 => bool) public filledOrders;

    /// @notice Trader => nonce word index => bitmap of used nonces (M-01)
    /// @dev Each bit represents a single nonce. Allows concurrent orders
    ///      by using any unused nonce from any word in the bitmap.
    mapping(address => mapping(uint256 => uint256))
        public nonceBitmap;

    /// @notice Fee recipient addresses
    FeeRecipients public feeRecipients;

    /// @notice Total trading volume
    uint256 public totalTradingVolume;

    /// @notice Total fees collected (approximate cross-token)
    uint256 public totalFeesCollected;

    /// @notice Emergency stop flag
    bool public emergencyStop;

    /// @notice Maximum trade size
    uint256 public maxTradeSize;

    /// @notice Daily volume limit
    uint256 public dailyVolumeLimit;

    /// @notice Daily volume used
    uint256 public dailyVolumeUsed;

    /// @notice Last reset day for volume tracking
    uint256 public lastResetDay;

    /// @notice Maximum slippage in basis points
    uint256 public maxSlippageBps;

    /// @notice Accrued fees: recipient => token => amount
    mapping(address => mapping(address => uint256))
        public accruedFees;

    /// @notice List of tokens that have had fees collected
    address[] public feeTokens;

    /// @notice Whether a token is already tracked in feeTokens
    mapping(address => bool) public isFeeToken;

    /// @notice IntentId => collateral record
    mapping(bytes32 => IntentCollateral) public intentCollateral;

    /// @notice Pending fee recipient change (M-04)
    FeeRecipients public pendingFeeRecipients;

    /// @notice Timestamp when pending fee recipients can be applied
    uint256 public feeRecipientsTimelockExpiry;

    /// @notice Pending trading limits change (M-04)
    uint256 public pendingMaxTradeSize;

    /// @notice Pending daily volume limit
    uint256 public pendingDailyVolumeLimit;

    /// @notice Pending max slippage in basis points
    uint256 public pendingMaxSlippageBps;

    /// @notice Timestamp when pending trading limits can be applied
    uint256 public tradingLimitsTimelockExpiry;

    // ================================================================
    // EVENTS
    // ================================================================

    /**
     * @notice Emitted when an order is committed
     * @param trader Trader address
     * @param orderHash Hash of the order
     * @param commitBlock Block number of commitment
     */
    event OrderCommitted(
        address indexed trader,
        bytes32 indexed orderHash,
        uint256 indexed commitBlock
    );

    /**
     * @notice Emitted when a trade is settled
     * @param tradeId Unique trade identifier
     * @param maker Address of the maker
     * @param taker Address of the taker
     * @param tokenIn Token being sold
     * @param tokenOut Token being bought
     * @param amountIn Amount of tokenIn
     * @param amountOut Amount of tokenOut
     * @param makerFee Fee paid by maker
     * @param takerFee Fee paid by taker
     * @param matchingValidator Validator who matched
     * @param settler Address that submitted settlement
     */
    event TradeSettled(
        bytes32 indexed tradeId,
        address indexed maker,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 makerFee,
        uint256 takerFee,
        address matchingValidator,
        address settler
    );

    /**
     * @notice Emitted when fees are distributed
     * @param matchingValidator Validator who matched
     * @param oddaoAmount Amount to ODDAO (70%)
     * @param stakingPoolAmount Amount to staking pool (20%)
     * @param validatorAmount Amount to validator (10%)
     * @param timestamp Distribution timestamp
     */
    event FeesDistributed(
        address indexed matchingValidator,
        uint256 indexed oddaoAmount,
        uint256 indexed stakingPoolAmount,
        uint256 validatorAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when accrued fees are claimed
     * @param recipient Address claiming fees
     * @param token Token claimed
     * @param amount Amount claimed
     */
    event FeesClaimed(
        address indexed recipient,
        address indexed token,
        uint256 indexed amount
    );

    /**
     * @notice Emitted when emergency stop is triggered
     * @param triggeredBy Address that triggered the stop
     * @param reason Reason for emergency stop
     */
    event EmergencyStop(
        address indexed triggeredBy,
        string reason
    );

    /**
     * @notice Emitted when trading is resumed
     * @param triggeredBy Address that resumed trading
     */
    event TradingResumed(address indexed triggeredBy);

    /**
     * @notice Emitted when trading limits are updated
     * @param maxTradeSizeVal New maximum trade size
     * @param dailyVolumeLimitVal New daily volume limit
     * @param maxSlippageBpsVal New max slippage in bps
     */
    event TradingLimitsUpdated(
        uint256 indexed maxTradeSizeVal,
        uint256 indexed dailyVolumeLimitVal,
        uint256 indexed maxSlippageBpsVal
    );

    /**
     * @notice Emitted when fee recipients are updated
     * @param newOddao New ODDAO address
     * @param newStakingPool New staking pool address
     */
    event FeeRecipientsUpdated(
        address indexed newOddao,
        address indexed newStakingPool
    );

    /**
     * @notice Emitted when a nonce is used or invalidated (M-01)
     * @param user Address of the user
     * @param wordIndex Bitmap word index
     * @param bitIndex Bit position within the word
     */
    event NonceUsed(
        address indexed user,
        uint256 indexed wordIndex,
        uint256 indexed bitIndex
    );

    /**
     * @notice Emitted when fee recipient change is scheduled (M-04)
     * @param newOddao Proposed new ODDAO address
     * @param newStakingPool Proposed new staking pool address
     * @param effectiveAt Timestamp when the change can be applied
     */
    event FeeRecipientsChangeScheduled(
        address indexed newOddao,
        address indexed newStakingPool,
        uint256 indexed effectiveAt
    );

    /**
     * @notice Emitted when trading limits change is scheduled (M-04)
     * @param newMaxTradeSize Proposed max trade size
     * @param newDailyVolumeLimit Proposed daily volume limit
     * @param effectiveAt Timestamp when the change can be applied
     */
    event TradingLimitsChangeScheduled(
        uint256 indexed newMaxTradeSize,
        uint256 indexed newDailyVolumeLimit,
        uint256 indexed effectiveAt
    );

    /**
     * @notice Emitted when intent collateral is locked
     * @param intentId Intent identifier
     * @param trader Trader address
     * @param solver Solver address
     * @param traderAmount Trader collateral
     * @param solverAmount Solver collateral
     */
    event IntentCollateralLocked(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        uint256 traderAmount,
        uint256 solverAmount
    );

    /**
     * @notice Emitted when intent is settled
     * @param intentId Intent identifier
     * @param trader Trader address
     * @param solver Solver address
     * @param traderAmount Amount from trader
     * @param solverAmount Amount from solver
     */
    event IntentSettled(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        uint256 traderAmount,
        uint256 solverAmount
    );

    /**
     * @notice Emitted when intent is cancelled
     * @param intentId Intent identifier
     * @param reason Cancellation reason
     */
    event IntentCancelled(
        bytes32 indexed intentId,
        string reason
    );

    // ================================================================
    // CUSTOM ERRORS
    // ================================================================

    /// @notice Thrown when emergency stop is activated
    error EmergencyStopActive();

    /// @notice Thrown when order has expired
    error OrderExpired();

    /// @notice Thrown when order signature is invalid
    error InvalidSignature();

    /// @notice Thrown when orders don't match
    error OrdersDontMatch();

    /// @notice Thrown when order is already filled
    error OrderAlreadyFilled();

    /// @notice Thrown when self-trading is attempted
    error SelfTradingNotAllowed();

    /// @notice Thrown when token balance is insufficient
    error InsufficientBalance(
        address token,
        address account
    );

    /// @notice Thrown when token allowance is insufficient
    error InsufficientAllowance(
        address token,
        address account
    );

    /// @notice Thrown when slippage exceeds maximum
    error SlippageExceedsMaximum();

    /// @notice Thrown when trade size exceeds limit
    error TradeSizeExceedsLimit();

    /// @notice Thrown when daily volume limit is exceeded
    error DailyVolumeLimitExceeded();

    /// @notice Thrown when commitment doesn't exist
    error CommitmentNotFound();

    /// @notice Thrown when revealing too early
    error RevealTooEarly();

    /// @notice Thrown when revealing too late
    error RevealTooLate();

    /// @notice Thrown when commitment hash doesn't match
    error CommitmentHashMismatch();

    /// @notice Thrown when matching validators don't agree
    error MatchingValidatorMismatch();

    /// @notice Thrown when address is invalid
    error InvalidAddress();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when fee shares don't sum to 100%
    error InvalidFeeShares();

    /// @notice Thrown when matching validator is zero address
    error InvalidMatchingValidator();

    /// @notice Thrown when an invalid order hash is provided
    error InvalidOrderHash();

    /// @notice Thrown when collateral is already locked
    error CollateralAlreadyLocked();

    /// @notice Thrown when collateral is not locked
    error CollateralNotLocked();

    /// @notice Thrown when settlement is already complete
    error AlreadySettled();

    /// @notice Thrown when caller is not authorized for
    ///         intent settlement (H-01)
    error UnauthorizedSettler();

    /// @notice Thrown when intent token addresses don't
    ///         match those provided at lock time (H-02)
    error IntentTokenMismatch();

    /// @notice Thrown when intent deadline has not yet
    ///         passed, so cancel is not allowed (M-03)
    error IntentDeadlineNotPassed();

    /// @notice Thrown when fee token list is full
    error FeeTokenListFull();

    /// @notice Thrown when a nonce has already been used (M-01)
    error NonceAlreadyUsed();

    /// @notice Thrown when timelock period has not elapsed (M-04)
    error TimelockNotElapsed();

    /// @notice Thrown when no pending change is scheduled (M-04)
    error NoPendingChange();

    /// @notice Thrown when fee-on-transfer token is detected (M-07)
    error FeeOnTransferNotSupported();

    /// @notice Thrown when slippage exceeds the configured max (M-06)
    error SlippageTooHigh();

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    /**
     * @notice Initialize the DEXSettlement contract
     * @param _oddao ODDAO treasury address (70% of fees)
     * @param _stakingPool Staking pool address (20% of fees)
     */
    constructor(
        address _oddao,
        address _stakingPool
    )
        EIP712("OmniCoin DEX Settlement", "1")
        Ownable(msg.sender)
    {
        if (
            _oddao == address(0)
                || _stakingPool == address(0)
        ) {
            revert InvalidAddress();
        }

        feeRecipients = FeeRecipients({
            oddao: _oddao,
            stakingPool: _stakingPool
        });

        // Initialize default limits
        maxSlippageBps = 500; // 5% default
        maxTradeSize = 1_000_000 * 10 ** 18; // 1M tokens
        dailyVolumeLimit = 10_000_000 * 10 ** 18; // 10M
        // solhint-disable-next-line not-rely-on-time
        lastResetDay = block.timestamp / 1 days;
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - COMMIT-REVEAL
    // ================================================================

    /**
     * @notice Commit order hash (Phase 1 of commit-reveal)
     * @param orderHash Hash of the order to commit
     * @dev Users commit before revealing to prevent
     *      front-running
     */
    function commitOrder(bytes32 orderHash) external {
        if (orderHash == bytes32(0)) {
            revert InvalidOrderHash();
        }

        commitments[msg.sender][orderHash] = Commitment({
            orderHash: orderHash,
            commitBlock: block.number,
            revealed: false
        });

        emit OrderCommitted(
            msg.sender,
            orderHash,
            block.number
        );
    }

    /**
     * @notice Reveal order after commitment
     * @param order Order details
     * @dev Verifies commitment exists and timing is correct
     */
    function revealOrder(Order calldata order) external {
        if (order.trader != msg.sender) {
            revert InvalidSignature();
        }

        bytes32 orderHash =
            _hashTypedDataV4(_hashOrder(order));
        Commitment storage commitment =
            commitments[msg.sender][orderHash];

        if (commitment.commitBlock == 0) {
            revert CommitmentNotFound();
        }
        if (commitment.revealed) {
            revert OrderAlreadyFilled();
        }
        if (
            block.number
                < commitment.commitBlock + MIN_COMMIT_BLOCKS
        ) {
            revert RevealTooEarly();
        }
        if (
            block.number
                > commitment.commitBlock + MAX_COMMIT_BLOCKS
        ) {
            revert RevealTooLate();
        }

        commitment.revealed = true;
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - SETTLEMENT
    // ================================================================

    /**
     * @notice Settle a matched trade (TRUSTLESS)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerSignature Maker's EIP-712 signature
     * @param takerSignature Taker's EIP-712 signature
     * @dev Verifies signatures, matching, and executes
     *      atomic swap. Fees are deducted from input token
     *      amounts (H-04 fix).
     */
    function settleTrade(
        Order calldata makerOrder,
        Order calldata takerOrder,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) external nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();

        _validateOrders(makerOrder, takerOrder);

        _verifySignatures(
            makerOrder,
            takerOrder,
            makerSignature,
            takerSignature
        );

        _verifyOrdersMatch(makerOrder, takerOrder);

        _checkVolumeLimits(makerOrder, takerOrder);

        _checkBalancesAndAllowances(
            makerOrder,
            takerOrder
        );

        // M-06: Enforce maxSlippageBps on settlement
        _checkSlippage(makerOrder, takerOrder);

        // H-04: Calculate fees on input token amounts
        uint256 makerFee = (makerOrder.amountIn
            * SPOT_MAKER_FEE) / BASIS_POINTS_DIVISOR;
        uint256 takerFee = (takerOrder.amountIn
            * SPOT_TAKER_FEE) / BASIS_POINTS_DIVISOR;

        _executeAtomicSettlement(
            makerOrder,
            takerOrder,
            makerFee,
            takerFee
        );

        bytes32 makerHash =
            _hashTypedDataV4(_hashOrder(makerOrder));
        bytes32 takerHash =
            _hashTypedDataV4(_hashOrder(takerOrder));

        filledOrders[makerHash] = true;
        filledOrders[takerHash] = true;

        // M-01: Mark nonces as used in the bitmap
        _useNonce(makerOrder.trader, makerOrder.nonce);
        _useNonce(takerOrder.trader, takerOrder.nonce);

        totalTradingVolume += makerOrder.amountIn;
        dailyVolumeUsed += makerOrder.amountIn;

        // H-04: Fees now come from tokenIn (input token)
        _distributeFees(
            makerFee,
            takerFee,
            makerOrder.tokenIn,
            takerOrder.tokenIn,
            makerOrder.matchingValidator
        );

        bytes32 tradeId = keccak256(
            abi.encodePacked(makerHash, takerHash)
        );

        emit TradeSettled(
            tradeId,
            makerOrder.trader,
            takerOrder.trader,
            makerOrder.tokenIn,
            makerOrder.tokenOut,
            makerOrder.amountIn,
            makerOrder.amountOut,
            makerFee,
            takerFee,
            makerOrder.matchingValidator,
            msg.sender
        );
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - ORDER CANCELLATION (H-06, M-01)
    // ================================================================

    /**
     * @notice Invalidate a specific nonce to cancel a pending
     *         signed order (M-01 bitmap approach)
     * @param nonce The nonce value to invalidate
     * @dev Uses nonce bitmap pattern (like Uniswap Permit2)
     *      so each user can have many concurrent orders. Each
     *      nonce is a single bit in a 256-bit word.
     */
    function invalidateNonce(uint256 nonce) external {
        (uint256 wordIdx, uint256 bitIdx) =
            _noncePosition(nonce);
        uint256 bit = 1 << bitIdx;
        nonceBitmap[msg.sender][wordIdx] |= bit;
        emit NonceUsed(msg.sender, wordIdx, bitIdx);
    }

    /**
     * @notice Invalidate a range of nonces to cancel multiple
     *         pending orders at once (H-06 + M-01)
     * @param wordIndex Bitmap word index to invalidate entirely
     * @dev Sets all 256 nonces in the given word to "used",
     *      effectively cancelling any orders using nonces
     *      from wordIndex*256 to wordIndex*256 + 255.
     */
    function invalidateNonceWord(
        uint256 wordIndex
    ) external {
        nonceBitmap[msg.sender][wordIndex] = type(uint256).max;
        emit NonceUsed(msg.sender, wordIndex, 256);
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - ADMIN
    // ================================================================

    /**
     * @notice Schedule fee recipient address change (M-04)
     * @param _oddao New ODDAO address (receives 70%)
     * @param _stakingPool New staking pool address (20%)
     * @dev Queues the change with a 48-hour timelock. Call
     *      `applyFeeRecipients()` after the delay to apply.
     */
    function scheduleFeeRecipients(
        address _oddao,
        address _stakingPool
    ) external onlyOwner {
        if (
            _oddao == address(0)
                || _stakingPool == address(0)
        ) {
            revert InvalidAddress();
        }

        pendingFeeRecipients = FeeRecipients({
            oddao: _oddao,
            stakingPool: _stakingPool
        });
        feeRecipientsTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        emit FeeRecipientsChangeScheduled(
            _oddao,
            _stakingPool,
            feeRecipientsTimelockExpiry
        );
    }

    /**
     * @notice Apply pending fee recipient change after timelock
     *         has elapsed (M-04, H-05)
     * @dev Force-claims all pending fees to old recipients
     *      before updating addresses.
     */
    function applyFeeRecipients() external onlyOwner {
        if (feeRecipientsTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < feeRecipientsTimelockExpiry) {
            revert TimelockNotElapsed();
        }

        // H-05: Force-claim pending fees to old recipients
        _claimAllPendingFees(feeRecipients.oddao);
        _claimAllPendingFees(feeRecipients.stakingPool);

        feeRecipients = pendingFeeRecipients;
        feeRecipientsTimelockExpiry = 0;

        emit FeeRecipientsUpdated(
            feeRecipients.oddao,
            feeRecipients.stakingPool
        );
    }

    /**
     * @notice Schedule trading limits change (M-04)
     * @param _maxTradeSize Maximum trade size
     * @param _dailyVolumeLimit Daily volume limit
     * @param _maxSlippageBps Maximum slippage in bps
     * @dev Queues the change with a 48-hour timelock. Call
     *      `applyTradingLimits()` after the delay to apply.
     */
    function scheduleTradingLimits(
        uint256 _maxTradeSize,
        uint256 _dailyVolumeLimit,
        uint256 _maxSlippageBps
    ) external onlyOwner {
        if (_maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert SlippageExceedsMaximum();
        }

        pendingMaxTradeSize = _maxTradeSize;
        pendingDailyVolumeLimit = _dailyVolumeLimit;
        pendingMaxSlippageBps = _maxSlippageBps;
        tradingLimitsTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        emit TradingLimitsChangeScheduled(
            _maxTradeSize,
            _dailyVolumeLimit,
            tradingLimitsTimelockExpiry
        );
    }

    /**
     * @notice Apply pending trading limits after timelock
     *         has elapsed (M-04)
     */
    function applyTradingLimits() external onlyOwner {
        if (tradingLimitsTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        if (block.timestamp < tradingLimitsTimelockExpiry) { // solhint-disable-line not-rely-on-time
            revert TimelockNotElapsed();
        }

        maxTradeSize = pendingMaxTradeSize;
        dailyVolumeLimit = pendingDailyVolumeLimit;
        maxSlippageBps = pendingMaxSlippageBps;
        tradingLimitsTimelockExpiry = 0;

        emit TradingLimitsUpdated(
            maxTradeSize,
            dailyVolumeLimit,
            maxSlippageBps
        );
    }

    /**
     * @notice Trigger emergency stop for trading
     * @param reason Reason for emergency stop
     * @dev Can only be called by owner
     */
    function emergencyStopTrading(
        string calldata reason
    ) external onlyOwner {
        emergencyStop = true;
        emit EmergencyStop(msg.sender, reason);
    }

    /**
     * @notice Resume trading after emergency stop
     * @dev Can only be called by owner
     */
    function resumeTrading() external onlyOwner {
        emergencyStop = false;
        emit TradingResumed(msg.sender);
    }

    /**
     * @notice Pause contract
     * @dev Can only be called by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - FEE CLAIMS
    // ================================================================

    /**
     * @notice Claim accrued fees for a specific token
     * @dev Pull pattern: fee recipients call this to
     *      withdraw their accrued fees.
     * @param token ERC20 token to withdraw fees in
     */
    function claimFees(
        address token
    ) external nonReentrant {
        uint256 amount = accruedFees[msg.sender][token];
        if (amount == 0) revert ZeroAmount();

        accruedFees[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit FeesClaimed(msg.sender, token, amount);
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - INTENT SETTLEMENT (Phase 3)
    //   H-01: Access control on settleIntent
    //   H-02: Token binding in IntentCollateral
    //   H-03: Real token escrow
    // ================================================================

    /**
     * @notice Lock collateral for intent settlement with
     *         real token escrow (H-03)
     * @param intentId Intent identifier (bytes32)
     * @param solver Designated solver address (H-01)
     * @param tokenIn Token the trader is selling (H-02)
     * @param tokenOut Token the trader expects (H-02)
     * @param traderAmount Amount trader is providing
     * @param solverAmount Amount solver must provide
     * @param deadline Settlement deadline timestamp
     * @dev Trader's tokens are actually escrowed into this
     *      contract via safeTransferFrom. Trader must have
     *      approved this contract for tokenIn beforehand.
     */
    function lockIntentCollateral(
        bytes32 intentId,
        address solver,
        address tokenIn,
        address tokenOut,
        uint256 traderAmount,
        uint256 solverAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (intentCollateral[intentId].locked) {
            revert CollateralAlreadyLocked();
        }
        if (traderAmount == 0 || solverAmount == 0) {
            revert ZeroAmount();
        }
        // solhint-disable-next-line not-rely-on-time
        if (deadline < block.timestamp) {
            revert OrderExpired();
        }
        if (solver == address(0)) {
            revert InvalidAddress();
        }
        if (
            tokenIn == address(0)
                || tokenOut == address(0)
        ) {
            revert InvalidAddress();
        }

        intentCollateral[intentId] = IntentCollateral({
            trader: msg.sender,
            locked: true,
            settled: false,
            solver: solver,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            traderAmount: traderAmount,
            solverAmount: solverAmount,
            deadline: deadline
        });

        // H-03: Actually escrow trader's tokens
        IERC20(tokenIn).safeTransferFrom(
            msg.sender,
            address(this),
            traderAmount
        );

        emit IntentCollateralLocked(
            intentId,
            msg.sender,
            solver,
            traderAmount,
            solverAmount
        );
    }

    /**
     * @notice Settle intent with bilateral swap (H-01)
     * @param intentId Intent identifier
     * @dev Only the trader or designated solver may call.
     *      Token addresses are validated against the locked
     *      intent record (H-02). Trader's escrowed tokens
     *      go to solver; solver's tokens go to trader.
     */
    function settleIntent(
        bytes32 intentId
    ) external nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();

        IntentCollateral storage coll =
            intentCollateral[intentId];

        if (!coll.locked) revert CollateralNotLocked();
        if (coll.settled) revert AlreadySettled();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > coll.deadline) {
            revert OrderExpired();
        }

        // H-01: Access control
        if (
            msg.sender != coll.trader
                && msg.sender != coll.solver
        ) {
            revert UnauthorizedSettler();
        }

        // Transfer escrowed trader tokens to solver
        IERC20(coll.tokenIn).safeTransfer(
            coll.solver,
            coll.traderAmount
        );

        // Transfer solver tokens to trader
        IERC20(coll.tokenOut).safeTransferFrom(
            coll.solver,
            coll.trader,
            coll.solverAmount
        );

        coll.settled = true;

        emit IntentSettled(
            intentId,
            coll.trader,
            coll.solver,
            coll.traderAmount,
            coll.solverAmount
        );
    }

    /**
     * @notice Cancel intent and return escrowed collateral
     * @param intentId Intent identifier
     * @dev Can only be called by trader after deadline has
     *      passed (M-03 fix). Returns escrowed tokens.
     */
    function cancelIntent(
        bytes32 intentId
    ) external nonReentrant {
        IntentCollateral storage coll =
            intentCollateral[intentId];

        if (!coll.locked) revert CollateralNotLocked();
        if (coll.settled) revert AlreadySettled();
        if (msg.sender != coll.trader) {
            revert InvalidSignature();
        }
        // M-03: Enforce deadline before allowing cancel
        // solhint-disable-next-line not-rely-on-time,gas-strict-inequalities
        if (block.timestamp <= coll.deadline) {
            revert IntentDeadlineNotPassed();
        }

        coll.locked = false;

        // H-03: Return escrowed tokens to trader
        IERC20(coll.tokenIn).safeTransfer(
            coll.trader,
            coll.traderAmount
        );

        emit IntentCancelled(
            intentId,
            "Cancelled by trader"
        );
    }

    // ================================================================
    // VIEW FUNCTIONS
    // ================================================================

    /**
     * @notice Get commitment for a trader and order hash
     * @param trader Trader address
     * @param orderHash Order hash
     * @return Commitment details
     */
    function getCommitment(
        address trader,
        bytes32 orderHash
    ) external view returns (Commitment memory) {
        return commitments[trader][orderHash];
    }

    /**
     * @notice Check if order is filled
     * @param orderHash Order hash
     * @return True if filled
     */
    function isOrderFilled(
        bytes32 orderHash
    ) external view returns (bool) {
        return filledOrders[orderHash];
    }

    /**
     * @notice Check if a specific nonce is used for a trader
     * @param trader Trader address
     * @param nonce Nonce value to check
     * @return used True if the nonce has been used
     */
    function isNonceUsed(
        address trader,
        uint256 nonce
    ) external view returns (bool used) {
        return _isNonceUsed(trader, nonce);
    }

    /**
     * @notice Get trading statistics
     * @return volume Total trading volume
     * @return fees Total fees collected
     * @return dailyUsed Daily volume used
     * @return dailyLimit Daily volume limit
     */
    function getTradingStats()
        external
        view
        returns (
            uint256 volume,
            uint256 fees,
            uint256 dailyUsed,
            uint256 dailyLimit
        )
    {
        return (
            totalTradingVolume,
            totalFeesCollected,
            dailyVolumeUsed,
            dailyVolumeLimit
        );
    }

    /**
     * @notice Get fee recipient addresses
     * @return FeeRecipients struct
     */
    function getFeeRecipients()
        external
        view
        returns (FeeRecipients memory)
    {
        return feeRecipients;
    }

    /**
     * @notice Hash an order for EIP-712 signing
     * @param order Order to hash
     * @return Order hash
     */
    function hashOrder(
        Order calldata order
    ) external view returns (bytes32) {
        return _hashTypedDataV4(_hashOrder(order));
    }

    /**
     * @notice Get intent collateral details
     * @param intentId Intent identifier
     * @return Collateral record
     */
    function getIntentCollateral(
        bytes32 intentId
    ) external view returns (IntentCollateral memory) {
        return intentCollateral[intentId];
    }

    /**
     * @notice Get number of tracked fee tokens
     * @return Count of fee tokens
     */
    function getFeeTokenCount()
        external
        view
        returns (uint256)
    {
        return feeTokens.length;
    }

    // ================================================================
    // INTERNAL FUNCTIONS (state-modifying first, then
    // view, then pure -- per Solidity style guide)
    // ================================================================

    /**
     * @notice Validate order parameters before settlement
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Checks expiry, self-trade, validator address,
     *      validator match, nonces, and daily volume reset
     */
    function _validateOrders(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal {
        // Reset daily volume if new day
        // solhint-disable-next-line not-rely-on-time
        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastResetDay) {
            dailyVolumeUsed = 0;
            lastResetDay = currentDay;
        }

        // Verify orders not expired
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > makerOrder.deadline) {
            revert OrderExpired();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > takerOrder.deadline) {
            revert OrderExpired();
        }

        // No self-trading
        if (makerOrder.trader == takerOrder.trader) {
            revert SelfTradingNotAllowed();
        }

        // Validator must not be zero (M-05)
        if (makerOrder.matchingValidator == address(0)) {
            revert InvalidMatchingValidator();
        }

        // Validators must match
        if (
            makerOrder.matchingValidator
                != takerOrder.matchingValidator
        ) {
            revert MatchingValidatorMismatch();
        }
    }

    /**
     * @notice Execute atomic settlement (H-04, M-07 fix)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFee Fee from maker's input
     * @param takerFee Fee from taker's input
     * @dev Fees are deducted from the input token amounts.
     *      Counterparty receives (amountIn - fee). Fee is
     *      sent to the contract for distribution.
     *      M-07: Uses balance-before/after to detect and
     *      reject fee-on-transfer tokens.
     */
    function _executeAtomicSettlement(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFee,
        uint256 takerFee
    ) internal {
        // Maker sends (amountIn - fee) to taker
        uint256 makerNet = makerOrder.amountIn - makerFee;

        // M-07: Check maker's transfer for fee-on-transfer
        uint256 balBefore = IERC20(makerOrder.tokenIn)
            .balanceOf(takerOrder.trader);
        IERC20(makerOrder.tokenIn).safeTransferFrom(
            makerOrder.trader,
            takerOrder.trader,
            makerNet
        );
        uint256 balAfter = IERC20(makerOrder.tokenIn)
            .balanceOf(takerOrder.trader);
        if (balAfter - balBefore != makerNet) {
            revert FeeOnTransferNotSupported();
        }

        // Maker fee to contract
        if (makerFee > 0) {
            IERC20(makerOrder.tokenIn).safeTransferFrom(
                makerOrder.trader,
                address(this),
                makerFee
            );
        }

        // Taker sends (amountIn - fee) to maker
        uint256 takerNet = takerOrder.amountIn - takerFee;

        // M-07: Check taker's transfer for fee-on-transfer
        balBefore = IERC20(takerOrder.tokenIn)
            .balanceOf(makerOrder.trader);
        IERC20(takerOrder.tokenIn).safeTransferFrom(
            takerOrder.trader,
            makerOrder.trader,
            takerNet
        );
        balAfter = IERC20(takerOrder.tokenIn)
            .balanceOf(makerOrder.trader);
        if (balAfter - balBefore != takerNet) {
            revert FeeOnTransferNotSupported();
        }

        // Taker fee to contract
        if (takerFee > 0) {
            IERC20(takerOrder.tokenIn).safeTransferFrom(
                takerOrder.trader,
                address(this),
                takerFee
            );
        }
    }

    /**
     * @notice Distribute trading fees using pull pattern
     * @param makerFee Fee from maker
     * @param takerFee Fee from taker
     * @param makerFeeToken Token of maker fee
     * @param takerFeeToken Token of taker fee
     * @param matchingValidator Validator who matched
     * @dev 70% ODDAO, 20% Staking Pool, 10% Validator.
     *      Remainder from rounding goes to ODDAO.
     */
    function _distributeFees(
        uint256 makerFee,
        uint256 takerFee,
        address makerFeeToken,
        address takerFeeToken,
        address matchingValidator
    ) internal {
        uint256 totalFees = makerFee + takerFee;
        if (totalFees == 0) return;

        totalFeesCollected += totalFees;

        if (makerFee > 0) {
            _accrueFeeSplit(
                makerFee,
                makerFeeToken,
                matchingValidator
            );
            _trackFeeToken(makerFeeToken);
        }

        if (takerFee > 0) {
            _accrueFeeSplit(
                takerFee,
                takerFeeToken,
                matchingValidator
            );
            _trackFeeToken(takerFeeToken);
        }

        // Aggregate event amounts
        uint256 oddaoAmt = (totalFees * ODDAO_SHARE)
            / BASIS_POINTS_DIVISOR;
        uint256 stakingAmt =
            (totalFees * STAKING_POOL_SHARE)
                / BASIS_POINTS_DIVISOR;
        uint256 valAmt = (totalFees * VALIDATOR_SHARE)
            / BASIS_POINTS_DIVISOR;

        emit FeesDistributed(
            matchingValidator,
            oddaoAmt,
            stakingAmt,
            valAmt,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
        );
    }

    /**
     * @notice Accrue a single fee amount to the three
     *         recipients with remainder to ODDAO
     * @param fee Total fee amount
     * @param token Fee token address
     * @param matchingValidator Validator address
     * @dev Remainder from integer division goes to ODDAO
     *      to prevent dust accumulation (M-02).
     */
    function _accrueFeeSplit(
        uint256 fee,
        address token,
        address matchingValidator
    ) internal {
        uint256 sp = (fee * STAKING_POOL_SHARE)
            / BASIS_POINTS_DIVISOR;
        uint256 vl = (fee * VALIDATOR_SHARE)
            / BASIS_POINTS_DIVISOR;
        // ODDAO gets remainder (avoids rounding dust)
        uint256 od = fee - sp - vl;

        accruedFees[feeRecipients.oddao][token] += od;
        accruedFees[feeRecipients.stakingPool][token]
            += sp;
        accruedFees[matchingValidator][token] += vl;
    }

    /**
     * @notice Track a new fee token for H-05 force-claims
     * @param token Token address to track
     * @dev Adds token to feeTokens array if not already
     *      tracked. Bounded by MAX_FEE_TOKENS.
     */
    function _trackFeeToken(address token) internal {
        if (!isFeeToken[token]) {
            // solhint-disable-next-line gas-strict-inequalities
            if (feeTokens.length >= MAX_FEE_TOKENS) {
                revert FeeTokenListFull();
            }
            isFeeToken[token] = true;
            feeTokens.push(token);
        }
    }

    /**
     * @notice Force-claim all accrued fees for a recipient
     *         across all tracked tokens (H-05)
     * @param recipient Address to claim fees for
     * @dev Called internally before updating fee recipients
     *      to prevent orphaned fee balances. Silently skips
     *      tokens with zero balance.
     */
    function _claimAllPendingFees(
        address recipient
    ) internal {
        uint256 len = feeTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = feeTokens[i];
            uint256 amount =
                accruedFees[recipient][token];
            if (amount > 0) {
                accruedFees[recipient][token] = 0;
                IERC20(token).safeTransfer(
                    recipient,
                    amount
                );
                emit FeesClaimed(
                    recipient,
                    token,
                    amount
                );
            }
        }
    }

    /**
     * @notice Mark a nonce as used in the bitmap (M-01)
     * @param trader Trader address
     * @param nonce Nonce to mark as used
     */
    function _useNonce(
        address trader,
        uint256 nonce
    ) internal {
        (uint256 wordIdx, uint256 bitIdx) =
            _noncePosition(nonce);
        uint256 bit = 1 << bitIdx;
        nonceBitmap[trader][wordIdx] |= bit;
        emit NonceUsed(trader, wordIdx, bitIdx);
    }

    /**
     * @notice Enforce maxSlippageBps between maker and taker
     *         order amounts (M-06)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Compares actual fill ratio against the maker's
     *      stated price ratio, rejecting trades that exceed
     *      the configured slippage tolerance.
     */
    function _checkSlippage(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal view {
        if (maxSlippageBps == 0) return;

        // Check taker gets at least (1 - slippage%) of what
        // the maker advertised they would provide.
        // Expected: takerOrder.amountIn should get at least
        // makerOrder.amountIn * (10000 - slippage) / 10000
        // in exchange value.
        uint256 minAcceptable = (makerOrder.amountOut
            * (BASIS_POINTS_DIVISOR - maxSlippageBps))
            / BASIS_POINTS_DIVISOR;
        if (takerOrder.amountIn < minAcceptable) {
            revert SlippageTooHigh();
        }
    }

    // ================================================================
    // INTERNAL VIEW FUNCTIONS
    // ================================================================

    /**
     * @notice Verify EIP-712 signatures for both orders
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerSignature Maker's signature
     * @param takerSignature Taker's signature
     * @dev Also checks fill status and nonces
     */
    function _verifySignatures(
        Order calldata makerOrder,
        Order calldata takerOrder,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) internal view {
        bytes32 makerHash =
            _hashTypedDataV4(_hashOrder(makerOrder));
        bytes32 takerHash =
            _hashTypedDataV4(_hashOrder(takerOrder));

        if (
            makerHash.recover(makerSignature)
                != makerOrder.trader
        ) {
            revert InvalidSignature();
        }
        if (
            takerHash.recover(takerSignature)
                != takerOrder.trader
        ) {
            revert InvalidSignature();
        }

        if (filledOrders[makerHash]) {
            revert OrderAlreadyFilled();
        }
        if (filledOrders[takerHash]) {
            revert OrderAlreadyFilled();
        }

        // M-01: Check nonce bitmap (not sequential)
        if (_isNonceUsed(makerOrder.trader, makerOrder.nonce)) {
            revert NonceAlreadyUsed();
        }
        if (_isNonceUsed(takerOrder.trader, takerOrder.nonce)) {
            revert NonceAlreadyUsed();
        }
    }

    /**
     * @notice Check volume limits for orders
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Reverts if trade size or daily volume exceeded
     */
    function _checkVolumeLimits(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal view {
        if (
            makerOrder.amountIn > maxTradeSize
                || takerOrder.amountIn > maxTradeSize
        ) {
            revert TradeSizeExceedsLimit();
        }
        if (
            dailyVolumeUsed + makerOrder.amountIn
                > dailyVolumeLimit
        ) {
            revert DailyVolumeLimitExceeded();
        }
    }

    /**
     * @notice Check token balances and allowances
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Reverts if insufficient balance or allowance
     *      for input tokens
     */
    function _checkBalancesAndAllowances(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal view {
        _checkSingleBalance(
            makerOrder.tokenIn,
            makerOrder.trader,
            makerOrder.amountIn
        );
        _checkSingleBalance(
            takerOrder.tokenIn,
            takerOrder.trader,
            takerOrder.amountIn
        );
    }

    /**
     * @notice Check balance and allowance for one party
     * @param token Token address
     * @param trader Trader address
     * @param amount Required amount
     */
    function _checkSingleBalance(
        address token,
        address trader,
        uint256 amount
    ) internal view {
        if (
            IERC20(token).balanceOf(trader) < amount
        ) {
            revert InsufficientBalance(token, trader);
        }
        if (
            IERC20(token).allowance(
                trader,
                address(this)
            ) < amount
        ) {
            revert InsufficientAllowance(token, trader);
        }
    }

    /**
     * @notice Check if a nonce is used in the bitmap (M-01)
     * @param trader Trader address
     * @param nonce Nonce to check
     * @return used True if the nonce has been used
     */
    function _isNonceUsed(
        address trader,
        uint256 nonce
    ) internal view returns (bool used) {
        (uint256 wordIdx, uint256 bitIdx) =
            _noncePosition(nonce);
        uint256 bit = 1 << bitIdx;
        return (nonceBitmap[trader][wordIdx] & bit) != 0;
    }

    // ================================================================
    // INTERNAL PURE FUNCTIONS
    // ================================================================

    /**
     * @notice Hash order struct for EIP-712
     * @param order Order to hash
     * @return Struct hash
     */
    function _hashOrder(
        Order calldata order
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.trader,
                order.isBuy,
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.amountOut,
                order.price,
                order.deadline,
                order.salt,
                order.matchingValidator,
                order.nonce
            )
        );
    }

    /**
     * @notice Verify that two orders match
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Checks sides, token pairs, amounts, and price
     */
    function _verifyOrdersMatch(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal pure {
        // Opposite sides
        if (makerOrder.isBuy == takerOrder.isBuy) {
            revert OrdersDontMatch();
        }

        // Token pairs match
        if (makerOrder.tokenIn != takerOrder.tokenOut) {
            revert OrdersDontMatch();
        }
        if (makerOrder.tokenOut != takerOrder.tokenIn) {
            revert OrdersDontMatch();
        }

        // Amounts compatible
        if (takerOrder.amountIn > makerOrder.amountOut) {
            revert OrdersDontMatch();
        }
        if (takerOrder.amountOut > makerOrder.amountIn) {
            revert OrdersDontMatch();
        }

        // Price logic
        _verifyPriceMatch(makerOrder, takerOrder);
    }

    /**
     * @notice Verify price compatibility between orders
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Maker buy: price >= taker sell price.
     *      Maker sell: price <= taker buy price.
     */
    function _verifyPriceMatch(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal pure {
        if (makerOrder.isBuy) {
            if (makerOrder.price < takerOrder.price) {
                revert OrdersDontMatch();
            }
        } else {
            if (makerOrder.price > takerOrder.price) {
                revert OrdersDontMatch();
            }
        }
    }

    /**
     * @notice Compute bitmap word index and bit index for a
     *         given nonce value (M-01)
     * @param nonce The nonce value
     * @return wordIdx The index of the 256-bit word
     * @return bitIdx The bit position within the word
     */
    function _noncePosition(
        uint256 nonce
    ) internal pure returns (uint256 wordIdx, uint256 bitIdx) {
        wordIdx = nonce / 256;
        bitIdx = nonce % 256;
    }
}
