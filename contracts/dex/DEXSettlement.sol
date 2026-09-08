// SPDX-License-Identifier: MIT
// The DEXSettlement contract intentionally has >20 state variables; see the
// contract-level NatSpec for rationale.
/* solhint-disable-next-line max-states-count */
pragma solidity 0.8.25;
/* solhint-disable max-states-count */

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
import {
    ERC2771Context
} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {
    Context
} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title IFeeOracle
 * @author OmniCoin Development Team
 * @notice External oracle that can grant per-trader fee discounts
 * @dev Implementations MUST be gas-safe (view, bounded). The
 *      DEXSettlement contract calls `getDiscountBps` inside a
 *      try/catch so oracle failures fall back to the base fee.
 */
interface IFeeOracle {
    /**
     * @notice Return the fee discount (in basis points) for a trader on a pair
     * @param trader Address of the taker
     * @param pairHash keccak256(abi.encodePacked(tokenIn, tokenOut))
     * @return discountBps Discount to subtract from the effective taker fee
     */
    function getDiscountBps(
        address trader,
        bytes32 pairHash
    ) external view returns (uint256 discountBps);
}

/**
 * @title DEXSettlement
 * @author OmniCoin Development Team
 * @notice Trustless on-chain trade settlement with commit-reveal
 *         MEV protection and native partial-fill support (V3).
 * @dev Atomic settlement of matched orders with dual EIP-712
 *      signature verification. Each signed Order may be consumed
 *      across multiple settlements until its amountIn is fully
 *      exhausted, enabling the matching engine to split orders
 *      across liquidity levels without re-signing.
 *
 * Architecture (Trustless V3):
 * 1. Users commit order hash (optional, MEV protection)
 * 2. Users reveal and sign orders with EIP-712 (version "3")
 * 3. Validators match orders off-chain and compute fill amounts
 * 4. ANYONE can submit matched orders for settlement, providing
 *    explicit makerFillAmount and takerFillAmount parameters
 * 5. Contract verifies signatures, matching logic, and that the
 *    fill amounts honor both signers' per-unit price constraints
 * 6. Atomic swap executed, fees distributed proportionally to
 *    the fill amounts, filledAmounts mapping updated
 *
 * Partial Fill Semantics (V3):
 * - filledAmounts[orderHash] tracks the cumulative tokenIn
 *   consumed for an order across all settlements.
 * - The nonce bitmap is only set when an order becomes fully
 *   filled (filledAmounts + fill == amountIn) or explicitly
 *   cancelled via invalidateNonce(). Partial fills leave the
 *   nonce unset so the remainder can match later.
 * - Fees are computed on fill amounts, not on the full signed
 *   amountIn: two half fills produce the same total fees as one
 *   equivalent full fill (within 1-wei rounding tolerance).
 *
 * Key Security Features:
 * - No single validator controls settlement
 * - Dual signature verification (both parties sign)
 * - Contract verifies order matching and fill proportionality
 * - Commit-reveal prevents front-running
 * - Fee attribution to matching validator (not submitter)
 * - Emergency circuit breakers
 * - Intent-based settlement with real token escrow
 *
 * Fee Structure (maker-taker with rebate + referral surcharge):
 * - Taker fee: spotTakerFeeBps (default 0.20%) of fill amount
 * - Maker rebate: 0.05% earned by maker (paid from taker fee)
 * - Net fee revenue: 0.15% distributed via push pattern
 * - Referral surcharge: referralFeeBps (default 0.05%) on referred
 *   takers, split 70/20/10 (referrer/referrer2/ODDAO)
 *
 * Fee Distribution (70/30 of net fee):
 * - 70% -> Liquidity Providers (rewards LPs)
 * - 30% -> UnifiedFeeVault (handles 70/20/10 ODDAO/Staking/Protocol split internally)
 *
 * Referral Surcharge Distribution (on referred takers only):
 * - 70% -> Direct referrer (order.referrer)
 * - 20% -> Referrer's referrer (order.referrer2, or ODDAO if zero)
 * - 10% -> ODDAO Treasury
 *
 * Audit Remediations Preserved From V2:
 * - H-01: settleIntent() access control
 * - H-02: Token binding in IntentCollateral
 * - H-03: Real token escrow in lockIntentCollateral()
 * - H-04: Fee deducted from input token
 * - H-05: Force-claim pending fees on recipient change
 * - H-06: invalidateNonce() for order cancellation
 * - M-01: Nonce bitmap for concurrent orders
 * - M-04: Timelock on trading-limits admin functions
 * - M-06: maxSlippageBps enforced in settlement
 * - M-07: Fee-on-transfer token incompatibility guard
 * @dev The contract intentionally has >20 state variables (commit-reveal +
 *      intent settlement + trading limits + partial fills + fee accrual +
 *      referrals); splitting would increase attack surface without reducing
 *      complexity.
 */
contract DEXSettlement is
    EIP712,
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    ERC2771Context
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    /// @dev AUDIT ACCEPTED (Round 6): Fee-on-transfer and rebasing tokens are not
    ///      supported. OmniCoin (XOM) is the primary token and does not have these
    ///      features. Only vetted tokens (XOM, USDC, WBTC, WETH) are whitelisted
    ///      for use in the platform. This is documented in deployment guides.

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
     * @param referrer Direct referrer of the taker (address(0)
     *        if no referral). Signed by taker for trustless
     *        referral attribution.
     * @param referrer2 Referrer's referrer (address(0) if none).
     *        If zero, the referrer2 share goes to ODDAO treasury.
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
        address referrer;
        address referrer2;
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
     * @param liquidityPool LP pool address (70% of net fees)
     * @param feeVault UnifiedFeeVault address (30% of net fees;
     *        vault handles the 70/20/10 ODDAO/Staking/Protocol
     *        split internally)
     * @param oddaoTreasury ODDAO treasury address (receives 10%
     *        of the referral surcharge)
     */
    struct FeeRecipients {
        address liquidityPool;
        address feeVault;
        address oddaoTreasury;
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
     * @param matchingValidator Validator who matched (H-03)
     * @param referrer Direct referrer (address(0) = none)
     * @param referrer2 Referrer's referrer (address(0) = none)
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
        address matchingValidator; // 20 bytes (slot 5)
        address referrer; // 20 bytes (slot 6)
        address referrer2; // 20 bytes (slot 7)
        uint256 traderAmount; // 32 bytes (slot 8)
        uint256 solverAmount; // 32 bytes (slot 9)
        uint256 deadline; // 32 bytes (slot 10)
    }

    // ================================================================
    // CONSTANTS
    // ================================================================

    /* solhint-disable max-line-length,gas-small-strings */
    /// @notice EIP-712 type hash for Order struct
    /// @dev Struct layout unchanged from V2; only settlement semantics
    ///      differ. The domain version bump from "2" to "3" is what
    ///      separates V2 and V3 signatures.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address trader,bool isBuy,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,uint256 price,uint256 deadline,bytes32 salt,address matchingValidator,uint256 nonce,address referrer,address referrer2)"
    );

    /// @notice EIP-712 type hash for IntentAcceptance struct
    /// @dev C-01 Round 8: The designated solver must sign this
    ///      typed-data message to consent to filling the intent.
    ///      Without the signature, a malicious trader could name
    ///      any address as "solver" and drain that address's
    ///      pre-approved allowance via `settleIntent`.
    bytes32 public constant INTENT_ACCEPTANCE_TYPEHASH = keccak256(
        "IntentAcceptance(bytes32 intentId,address trader,address solver,address tokenIn,address tokenOut,uint256 traderAmount,uint256 solverAmount,uint256 deadline)"
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

    /// @notice LP pool fee share (70% of net fees)
    uint256 public constant LP_SHARE = 7000;

    /// @notice UnifiedFeeVault fee share (30% of net fees)
    /// @dev Vault handles 70/20/10 ODDAO/Staking/Protocol split
    uint256 public constant VAULT_SHARE = 3000;

    /// @notice Spot market maker rebate (0.05% earned by maker)
    uint256 public constant SPOT_MAKER_REBATE = 5;

    /// @notice Maximum spot taker fee (1.00%)
    uint256 public constant MAX_SPOT_TAKER_FEE = 100;

    /// @notice Maximum referral surcharge (0.50%)
    uint256 public constant MAX_REFERRAL_FEE = 50;

    /// @notice Referral surcharge split: 70% to referrer
    uint256 public constant REFERRAL_SHARE = 7000;

    /// @notice Referral surcharge split: 20% to referrer2
    uint256 public constant REFERRER2_SHARE = 2000;

    /// @notice Maximum number of tracked fee tokens
    uint256 public constant MAX_FEE_TOKENS = 100;

    /// @notice Timelock delay for critical admin functions (M-04)
    /// @dev Pioneer phase: 0 — deployer-direct admin, no wait.
    uint256 public constant TIMELOCK_DELAY = 0;

    /// @notice Maximum trades in a single batch settlement (V3.1)
    uint256 public constant MAX_BATCH_SIZE = 20;

    /// @notice Maximum allowed per-pair fee override (V3.1)
    uint256 public constant MAX_PAIR_FEE = 100;

    // ================================================================
    // STATE VARIABLES
    // ================================================================

    /// @notice Trader => orderHash => commitment
    mapping(address => mapping(bytes32 => Commitment))
        public commitments;

    /// @notice Cumulative tokenIn consumed per order (V3 partial fills)
    /// @dev Replaces the V2 `filledOrders` boolean map. The invariant
    ///      `filledAmounts[hash] <= order.amountIn` is enforced on every
    ///      settlement via `_verifyFillAmounts`. An order is considered
    ///      fully filled when `filledAmounts[hash] == order.amountIn`, at
    ///      which point the trader's nonce bit is set and no further
    ///      settlements against the hash are permitted.
    mapping(bytes32 => uint256) public filledAmounts;

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

    /// @notice Pending trading limits change (M-04)
    uint256 public pendingMaxTradeSize;

    /// @notice Pending daily volume limit
    uint256 public pendingDailyVolumeLimit;

    /// @notice Pending max slippage in basis points
    uint256 public pendingMaxSlippageBps;

    /// @notice Timestamp when pending trading limits can be applied
    uint256 public tradingLimitsTimelockExpiry;

    /// @notice Pending fee recipients (M-01 Round 6: timelock)
    FeeRecipients public pendingFeeRecipients;

    /// @notice Timestamp when pending fee recipients can be applied
    uint256 public feeRecipientsTimelockExpiry;

    /// @notice Spot taker fee in basis points (configurable, default 20 = 0.20%)
    uint256 public spotTakerFeeBps;

    /// @notice Referral surcharge in basis points (default 5 = 0.05%)
    /// @dev Only applied when taker order has referrer != address(0)
    uint256 public referralFeeBps;

    /// @notice Pending spot taker fee (timelocked)
    uint256 public pendingSpotTakerFeeBps;

    /// @notice Timestamp when pending spot taker fee can be applied
    uint256 public spotTakerFeeTimelockExpiry;

    /// @notice Pending referral fee (timelocked)
    uint256 public pendingReferralFeeBps;

    /// @notice Timestamp when pending referral fee can be applied
    uint256 public referralFeeTimelockExpiry;

    // ================================================================
    // V3.1: PER-PAIR FEES, FEE ORACLE, BATCH SETTLEMENT
    // ================================================================

    /// @notice Per-pair taker fee override (0 = use global spotTakerFeeBps)
    /// @dev Key is keccak256(abi.encodePacked(tokenIn, tokenOut))
    mapping(bytes32 => uint256) public pairFeeOverrides;

    /// @notice Pending per-pair fee change (timelocked)
    mapping(bytes32 => uint256) public pendingPairFee;

    /// @notice Timelock expiry for each pending per-pair fee change
    mapping(bytes32 => uint256) public pairFeeTimelockExpiry;

    /// @notice External fee oracle for volume-based discounts
    /// @dev address(0) = disabled (no discounts applied)
    address public feeOracle;

    /// @notice Pending fee oracle address (timelocked)
    address public pendingFeeOracle;

    /// @notice Timelock expiry for pending fee oracle change
    uint256 public feeOracleTimelockExpiry;

    /// @notice Authorized adapters bypass taker signature verification
    /// @dev Used by CLOBAdapter and similar router-integrated contracts.
    ///      Adapters are contracts that act as taker; since contracts
    ///      cannot produce EIP-712 ECDSA signatures, they are
    ///      whitelisted here and taker sig is skipped.
    mapping(address => bool) public authorizedAdapters;

    /// @notice Pending adapter authorization changes (timelocked)
    mapping(address => bool) public pendingAdapterAuth;

    /// @notice Timelock expiry for each pending adapter auth change
    mapping(address => uint256) public adapterTimelockExpiry;

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
     * @notice Emitted when a trader cancels an order
     * @param trader Trader who cancelled
     * @param nonce Nonce of the cancelled order
     */
    event OrderCancelled(
        address indexed trader,
        uint256 indexed nonce
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
     * @param makerRebate Rebate paid to maker (0.05% of amountIn)
     * @param takerFee Fee paid by taker (0.20%)
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
        uint256 makerRebate,
        uint256 takerFee,
        address matchingValidator,
        address settler
    );

    /**
     * @notice Emitted alongside `TradeSettled` to expose per-order
     *         fill accounting for indexers and off-chain matching
     *         engines.
     * @param tradeId Unique trade identifier (same as TradeSettled)
     * @param maker Maker address
     * @param taker Taker address
     * @param makerOrderHash EIP-712 digest of the maker order
     * @param takerOrderHash EIP-712 digest of the taker order
     * @param makerFillAmount Amount of maker.tokenIn consumed
     * @param takerFillAmount Amount of taker.tokenIn consumed
     * @param makerFilledTotal filledAmounts[makerOrderHash] AFTER fill
     * @param takerFilledTotal filledAmounts[takerOrderHash] AFTER fill
     * @param makerFullyFilled True if the maker order is now fully
     *        consumed (nonce was just set)
     * @param takerFullyFilled True if the taker order is now fully
     *        consumed (nonce was just set)
     */
    event TradePartiallySettled(
        bytes32 indexed tradeId,
        address indexed maker,
        address indexed taker,
        bytes32 makerOrderHash,
        bytes32 takerOrderHash,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        uint256 makerFilledTotal,
        uint256 takerFilledTotal,
        bool makerFullyFilled,
        bool takerFullyFilled
    );

    /**
     * @notice Emitted when fees are distributed
     * @param matchingValidator Validator who matched the trade
     * @param lpAmount Amount to LPs (70% of net fee)
     * @param vaultAmount Amount to UnifiedFeeVault (30% of net fee)
     * @param timestamp Distribution timestamp
     */
    event FeesDistributed(
        address indexed matchingValidator,
        uint256 indexed lpAmount,
        uint256 indexed vaultAmount,
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
     * @param newLiquidityPool New LP pool address
     * @param newFeeVault New UnifiedFeeVault address
     * @param newOddaoTreasury New ODDAO treasury address
     */
    event FeeRecipientsUpdated(
        address indexed newLiquidityPool,
        address indexed newFeeVault,
        address indexed newOddaoTreasury
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

    /* solhint-disable gas-indexed-events */
    /**
     * @notice Emitted when trading limits change is scheduled (M-04)
     * @param newMaxTradeSize Proposed max trade size
     * @param newDailyVolumeLimit Proposed daily volume limit
     * @param newMaxSlippageBps Proposed max slippage in bps (L-07)
     * @param effectiveAt Timestamp when change can be applied
     * @dev Solidity permits at most 3 indexed event parameters; we index
     *      newMaxTradeSize, newDailyVolumeLimit, and effectiveAt since those
     *      are the common filter keys. newMaxSlippageBps is data-only.
     */
    event TradingLimitsChangeScheduled(
        uint256 indexed newMaxTradeSize,
        uint256 indexed newDailyVolumeLimit,
        uint256 newMaxSlippageBps,
        uint256 indexed effectiveAt
    );
    /* solhint-enable gas-indexed-events */

    /**
     * @notice Emitted when a scheduled trading limits change
     *         is cancelled (M-04)
     */
    event TradingLimitsChangeCancelled();

    /**
     * @notice Emitted when a fee recipients change is scheduled
     *         (M-01 Round 6: timelock)
     * @param newLiquidityPool Proposed LP pool address
     * @param newFeeVault Proposed UnifiedFeeVault address
     * @param newOddaoTreasury Proposed ODDAO treasury address
     * @param effectiveAt Timestamp when change can be applied
     */
    event FeeRecipientsChangeScheduled(
        address indexed newLiquidityPool,
        address indexed newFeeVault,
        address indexed newOddaoTreasury,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when a scheduled fee recipients change
     *         is cancelled (M-01 Round 6: timelock)
     */
    event FeeRecipientsChangeCancelled();

    /**
     * @notice Emitted when a fee token is removed from tracking
     * @param token Address of the removed token
     */
    event FeeTokenRemoved(address indexed token);

    /**
     * @notice Emitted when referral surcharge is distributed
     * @param tradeId Unique trade identifier
     * @param referrer Direct referrer address
     * @param referrer2 Referrer's referrer address
     * @param referrerAmount Amount sent to referrer (70%)
     * @param referrer2Amount Amount sent to referrer2 (20%)
     * @param oddaoAmount Amount sent to ODDAO treasury (10%)
     */
    event ReferralFeeDistributed(
        bytes32 indexed tradeId,
        address indexed referrer,
        address indexed referrer2,
        uint256 referrerAmount,
        uint256 referrer2Amount,
        uint256 oddaoAmount
    );

    /**
     * @notice Emitted when a referral fee transfer fails and
     *         the amount is redirected to the ODDAO treasury
     * @param tradeId Trade identifier
     * @param intendedRecipient Address that failed to receive
     * @param amount Amount redirected to ODDAO
     */
    event ReferralFeeRedirected(
        bytes32 indexed tradeId,
        address indexed intendedRecipient,
        uint256 indexed amount
    );

    /**
     * @notice Emitted when spot taker fee change is scheduled
     * @param newFeeBps Proposed fee in basis points
     * @param effectiveAt Timestamp when change can be applied
     */
    event SpotTakerFeeChangeScheduled(
        uint256 indexed newFeeBps,
        uint256 indexed effectiveAt
    );

    /// @notice Emitted when a scheduled spot taker fee change is cancelled
    event SpotTakerFeeChangeCancelled();

    /**
     * @notice Emitted when spot taker fee is updated
     * @param oldFeeBps Previous fee in basis points
     * @param newFeeBps New fee in basis points
     */
    event SpotTakerFeeUpdated(
        uint256 indexed oldFeeBps,
        uint256 indexed newFeeBps
    );

    /**
     * @notice Emitted when referral fee change is scheduled
     * @param newFeeBps Proposed fee in basis points
     * @param effectiveAt Timestamp when change can be applied
     */
    event ReferralFeeChangeScheduled(
        uint256 indexed newFeeBps,
        uint256 indexed effectiveAt
    );

    /// @notice Emitted when a scheduled referral fee change is cancelled
    event ReferralFeeChangeCancelled();

    /**
     * @notice Emitted when referral fee is updated
     * @param oldFeeBps Previous fee in basis points
     * @param newFeeBps New fee in basis points
     */
    event ReferralFeeUpdated(
        uint256 indexed oldFeeBps,
        uint256 indexed newFeeBps
    );

    // V3.1 Events

    /**
     * @notice Emitted when a per-pair fee override is scheduled
     * @param pairHash keccak256(abi.encodePacked(tokenIn, tokenOut))
     * @param newFeeBps Proposed per-pair fee in basis points
     * @param effectiveAt Timestamp when change can be applied
     */
    event PairFeeScheduled(
        bytes32 indexed pairHash,
        uint256 indexed newFeeBps,
        uint256 indexed effectiveAt
    );

    /**
     * @notice Emitted when a per-pair fee override is applied
     * @param pairHash keccak256(abi.encodePacked(tokenIn, tokenOut))
     * @param oldFeeBps Previous per-pair fee in basis points
     * @param newFeeBps New per-pair fee in basis points
     */
    event PairFeeApplied(
        bytes32 indexed pairHash,
        uint256 indexed oldFeeBps,
        uint256 indexed newFeeBps
    );

    /**
     * @notice Emitted when a scheduled per-pair fee change is cancelled
     * @param pairHash keccak256(abi.encodePacked(tokenIn, tokenOut))
     */
    event PairFeeCancelled(bytes32 indexed pairHash);

    /**
     * @notice Emitted when a fee oracle change is scheduled
     * @param oldOracle Current oracle address
     * @param newOracle Proposed oracle address
     * @param effectiveAt Timestamp when change can be applied
     */
    event FeeOracleScheduled(
        address indexed oldOracle,
        address indexed newOracle,
        uint256 indexed effectiveAt
    );

    /**
     * @notice Emitted when a fee oracle change is applied
     * @param oldOracle Previous oracle address
     * @param newOracle New oracle address
     */
    event FeeOracleApplied(
        address indexed oldOracle,
        address indexed newOracle
    );

    /// @notice Emitted when a scheduled fee oracle change is cancelled
    event FeeOracleCancelled();

    /**
     * @notice Emitted when an adapter authorization is scheduled
     * @param adapter Adapter contract address
     * @param authorized Whether the adapter will be authorized
     * @param effectiveAt Timestamp when the change can be applied
     */
    event AdapterScheduled(
        address indexed adapter,
        bool authorized,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when a scheduled adapter authorization is applied
     * @param adapter Adapter contract address
     * @param authorized Whether the adapter is now authorized
     */
    event AdapterApplied(
        address indexed adapter,
        bool authorized
    );

    /// @notice Emitted when a scheduled adapter authorization is cancelled
    event AdapterCancelled(address indexed adapter);

    /**
     * @notice Emitted when a batch settlement completes
     * @param tradesSettled Number of trades successfully settled
     * @param tradesFailed Number of trades that failed
     */
    event BatchSettlementComplete(
        uint256 indexed tradesSettled,
        uint256 indexed tradesFailed
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

    /// @notice Thrown when a pending timelocked change already exists (M-04)
    error PendingChangeExists();

    /// @notice Thrown when function parameters are invalid
    error InvalidParameters();

    /// @notice Thrown when an order has invalid token configuration
    error InvalidOrder();

    /// @notice Thrown when fee token is not found in the array
    error FeeTokenNotFound();

    /// @notice Thrown when spot taker fee exceeds maximum
    error SpotTakerFeeTooHigh();

    /// @notice Thrown when referral fee exceeds maximum
    error ReferralFeeTooHigh();

    /// @notice Thrown when a settlement passes a zero fill amount
    ///         on either side (V3 partial fills)
    error InvalidFillAmount();

    /// @notice Thrown when a fill amount would exceed the remaining
    ///         unfilled portion of an order (V3 partial fills)
    error FillExceedsRemaining();

    /// @notice Thrown when the maker/taker fill amounts do not honor
    ///         one of the signers' per-unit price constraints, i.e.
    ///         the settler attempted to under-pay one party relative
    ///         to the rate they signed for (V3 partial fills)
    error FillProportionalityMismatch();

    /// @notice Thrown when a fill is so small that the computed
    ///         taker fee rounds to zero via integer division
    ///         (H-02 Round 8 — prevents fee-free wash trading)
    error FillTooSmall();

    /// @notice Thrown when a solver signature in
    ///         `lockIntentCollateral` does not match the
    ///         `solver` parameter (C-01 Round 8 — prevents
    ///         unauthenticated solver drain)
    error InvalidSolverSignature();

    // V3.1 Errors

    /// @notice Thrown when batch settlement array is empty
    error BatchEmpty();

    /// @notice Thrown when batch settlement exceeds MAX_BATCH_SIZE
    error BatchTooLarge();

    /// @notice Thrown when per-pair fee override exceeds MAX_PAIR_FEE
    error PairFeeTooHigh();

    /// @notice Thrown when only address(this) may call the function
    error OnlySelf();

    /// @notice Thrown when adapter timelock has not elapsed
    error AdapterTimelockNotExpired();

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    /**
     * @notice Initialize the DEXSettlement contract
     * @param _liquidityPool LP pool address (70% of net fees)
     * @param _feeVault UnifiedFeeVault address (30% of net fees;
     *        vault handles ODDAO/Staking/Protocol split internally)
     * @param _oddaoTreasury ODDAO treasury address (receives 10%
     *        of the referral surcharge, and referrer2 share when
     *        referrer2 == address(0))
     * @param trustedForwarder_ ERC-2771 trusted forwarder for
     *        gasless meta-transactions (e.g. OmniForwarder)
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    constructor(
        address _liquidityPool,
        address _feeVault,
        address _oddaoTreasury,
        address trustedForwarder_
    )
        EIP712("OmniCoin DEX Settlement", "3")
        Ownable(msg.sender)
        ERC2771Context(trustedForwarder_)
    {
        if (
            _liquidityPool == address(0)
                || _feeVault == address(0)
                || _oddaoTreasury == address(0)
        ) {
            revert InvalidAddress();
        }

        feeRecipients = FeeRecipients({
            liquidityPool: _liquidityPool,
            feeVault: _feeVault,
            oddaoTreasury: _oddaoTreasury
        });

        // Initialize configurable fee parameters
        spotTakerFeeBps = 20; // 0.20% default taker fee
        referralFeeBps = 5; // 0.05% referral surcharge

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

        address caller = _msgSender();

        commitments[caller][orderHash] = Commitment({
            orderHash: orderHash,
            commitBlock: block.number,
            revealed: false
        });

        emit OrderCommitted(
            caller,
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
        address caller = _msgSender();

        if (order.trader != caller) {
            revert InvalidSignature();
        }

        bytes32 orderHash =
            _hashTypedDataV4(_hashOrder(order));
        Commitment storage commitment =
            commitments[caller][orderHash];

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

    /* solhint-disable code-complexity, function-max-lines */
    /**
     * @notice Settle a matched trade, potentially as a partial fill (TRUSTLESS V3)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFillAmount Portion of makerOrder.amountIn to consume in this settlement
     * @param takerFillAmount Portion of takerOrder.amountIn to consume in this settlement
     * @param makerSignature Maker's EIP-712 signature (domain v3)
     * @param takerSignature Taker's EIP-712 signature (domain v3)
     * @dev Verifies signatures, matching, fill proportionality, and executes atomic swap
     *      scaled to the fill amounts. Fees are computed on fill amounts, not on the full
     *      signed amountIn. Nonces are marked used only when a side becomes fully filled
     *      so partial fills can be matched incrementally. All state updates (filledAmounts,
     *      nonces, volume) are performed BEFORE external token transfers to comply with
     *      CEI pattern and prevent read-only reentrancy. Note: Commit-reveal is opt-in;
     *      MEV protection is not guaranteed without it (M-03).
     */
    function settleTrade(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) external nonReentrant whenNotPaused {
        _settleTradeCoreLogic(
            makerOrder,
            takerOrder,
            makerFillAmount,
            takerFillAmount,
            makerSignature,
            takerSignature
        );
    }
    /* solhint-enable code-complexity, function-max-lines */

    /**
     * @notice Settle multiple matched trades in a single transaction (V3.1)
     * @param makerOrders Array of maker orders
     * @param takerOrders Array of taker orders
     * @param makerFillAmounts Array of maker fill amounts
     * @param takerFillAmounts Array of taker fill amounts
     * @param makerSignatures Array of maker EIP-712 signatures
     * @param takerSignatures Array of taker EIP-712 signatures
     * @dev Each trade is attempted independently; a single failure does
     *      not revert the entire batch. The `_settleTradeExternal`
     *      wrapper is called via `this.` to enable try/catch (external
     *      call requirement). Failed trades are silently skipped and
     *      counted in the emitted event. Gas: ~4M max for 20 trades.
     */
    function settleTradesBatch(
        Order[] calldata makerOrders,
        Order[] calldata takerOrders,
        uint256[] calldata makerFillAmounts,
        uint256[] calldata takerFillAmounts,
        bytes[] calldata makerSignatures,
        bytes[] calldata takerSignatures
    ) external nonReentrant whenNotPaused {
        uint256 len = makerOrders.length;
        if (len == 0) revert BatchEmpty();
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (
            len != takerOrders.length
                || len != makerFillAmounts.length
                || len != takerFillAmounts.length
                || len != makerSignatures.length
                || len != takerSignatures.length
        ) {
            revert InvalidOrder();
        }

        uint256 settled;
        for (uint256 i; i < len; ++i) {
            // solhint-disable-next-line no-empty-blocks
            try this._settleTradeExternal(
                makerOrders[i],
                takerOrders[i],
                makerFillAmounts[i],
                takerFillAmounts[i],
                makerSignatures[i],
                takerSignatures[i]
            ) {
                ++settled;
            } catch {
                // Skip failed trades — counted in event
            }
        }

        emit BatchSettlementComplete(settled, len - settled);
    }

    /**
     * @notice External wrapper around core settlement logic for
     *         try/catch in batch settlement
     * @dev MUST only be called by address(this). The external
     *      visibility is required for Solidity try/catch.
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFillAmount Maker fill amount
     * @param takerFillAmount Taker fill amount
     * @param makerSignature Maker's EIP-712 signature
     * @param takerSignature Taker's EIP-712 signature
     */
    function _settleTradeExternal(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _settleTradeCoreLogic(
            makerOrder,
            takerOrder,
            makerFillAmount,
            takerFillAmount,
            makerSignature,
            takerSignature
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
        address caller = _msgSender();

        (uint256 wordIdx, uint256 bitIdx) =
            _noncePosition(nonce);
        uint256 bit = 1 << bitIdx;
        nonceBitmap[caller][wordIdx] |= bit;
        emit NonceUsed(caller, wordIdx, bitIdx);
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
        address caller = _msgSender();

        nonceBitmap[caller][wordIndex] = type(uint256).max;
        emit NonceUsed(caller, wordIndex, 256);
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - ADMIN
    // ================================================================

    /**
     * @notice Schedule fee recipient address change (M-01 Round 6)
     * @param _liquidityPool New LP pool address (70% of net)
     * @param _feeVault New UnifiedFeeVault address (30% of net;
     *        vault handles ODDAO/Staking/Protocol split internally)
     * @param _oddaoTreasury New ODDAO treasury address (referral
     *        surcharge 10% share)
     * @dev Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     *      Call `applyFeeRecipients()` to apply.
     *      Reverts if a pending change already exists.
     */
    function scheduleFeeRecipients(
        address _liquidityPool,
        address _feeVault,
        address _oddaoTreasury
    ) external onlyOwner {
        if (feeRecipientsTimelockExpiry != 0) {
            revert PendingChangeExists();
        }
        if (
            _liquidityPool == address(0)
                || _feeVault == address(0)
                || _oddaoTreasury == address(0)
        ) {
            revert InvalidAddress();
        }

        pendingFeeRecipients = FeeRecipients({
            liquidityPool: _liquidityPool,
            feeVault: _feeVault,
            oddaoTreasury: _oddaoTreasury
        });
        feeRecipientsTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        emit FeeRecipientsChangeScheduled(
            _liquidityPool,
            _feeVault,
            _oddaoTreasury,
            feeRecipientsTimelockExpiry
        );
    }

    /**
     * @notice Apply pending fee recipients after timelock
     *         has elapsed (M-01 Round 6)
     * @dev Force-claims all pending fees to old recipients
     *      before updating addresses (H-05 audit fix preserved).
     */
    function applyFeeRecipients()
        external
        nonReentrant
        onlyOwner
    {
        if (feeRecipientsTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        if (block.timestamp < feeRecipientsTimelockExpiry) { // solhint-disable-line not-rely-on-time
            revert TimelockNotElapsed();
        }

        // H-05: Force-claim pending fees to old recipients
        _claimAllPendingFees(feeRecipients.liquidityPool);
        _claimAllPendingFees(feeRecipients.feeVault);

        feeRecipients = pendingFeeRecipients;
        feeRecipientsTimelockExpiry = 0;

        emit FeeRecipientsUpdated(
            feeRecipients.liquidityPool,
            feeRecipients.feeVault,
            feeRecipients.oddaoTreasury
        );
    }

    /**
     * @notice Cancel a pending fee recipients change (M-01 Round 6)
     * @dev Only callable by owner. Resets the pending state.
     */
    function cancelScheduledFeeRecipients()
        external
        onlyOwner
    {
        if (feeRecipientsTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        feeRecipientsTimelockExpiry = 0;
        delete pendingFeeRecipients;
        emit FeeRecipientsChangeCancelled();
    }

    /**
     * @notice Schedule trading limits change (M-04)
     * @param _maxTradeSize Maximum trade size
     * @param _dailyVolumeLimit Daily volume limit
     * @param _maxSlippageBps Maximum slippage in bps
     * @dev Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     *      Call `applyTradingLimits()` to apply.
     *      Reverts if a pending change already exists.
     */
    function scheduleTradingLimits(
        uint256 _maxTradeSize,
        uint256 _dailyVolumeLimit,
        uint256 _maxSlippageBps
    ) external onlyOwner {
        if (tradingLimitsTimelockExpiry != 0) {
            revert PendingChangeExists();
        }
        // L-01: Reject zero values
        if (_maxTradeSize == 0 || _dailyVolumeLimit == 0) {
            revert InvalidParameters();
        }
        if (_maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert SlippageExceedsMaximum();
        }

        pendingMaxTradeSize = _maxTradeSize;
        pendingDailyVolumeLimit = _dailyVolumeLimit;
        pendingMaxSlippageBps = _maxSlippageBps;
        tradingLimitsTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        // L-07: Include slippage parameter in event
        emit TradingLimitsChangeScheduled(
            _maxTradeSize,
            _dailyVolumeLimit,
            _maxSlippageBps,
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
     * @notice Cancel a pending trading limits change (M-04)
     * @dev Only callable by owner. Resets the pending state.
     */
    function cancelScheduledTradingLimits()
        external
        onlyOwner
    {
        if (tradingLimitsTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        tradingLimitsTimelockExpiry = 0;
        pendingMaxTradeSize = 0;
        pendingDailyVolumeLimit = 0;
        pendingMaxSlippageBps = 0;
        emit TradingLimitsChangeCancelled();
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - FEE PARAMETER ADMIN (timelocked)
    // ================================================================

    /**
     * @notice Schedule spot taker fee change
     * @param _newFeeBps New fee in basis points (max 100 = 1.00%)
     * @dev Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     *      Call `applySpotTakerFee()` to apply.
     */
    function scheduleSpotTakerFee(
        uint256 _newFeeBps
    ) external onlyOwner {
        if (spotTakerFeeTimelockExpiry != 0) {
            revert PendingChangeExists();
        }
        if (_newFeeBps > MAX_SPOT_TAKER_FEE) {
            revert SpotTakerFeeTooHigh();
        }

        pendingSpotTakerFeeBps = _newFeeBps;
        spotTakerFeeTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        emit SpotTakerFeeChangeScheduled(
            _newFeeBps,
            spotTakerFeeTimelockExpiry
        );
    }

    /**
     * @notice Apply pending spot taker fee after timelock
     * @dev Applies the fee change queued by `scheduleSpotTakerFee`.
     */
    function applySpotTakerFee() external onlyOwner {
        if (spotTakerFeeTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        if (block.timestamp < spotTakerFeeTimelockExpiry) { // solhint-disable-line not-rely-on-time
            revert TimelockNotElapsed();
        }

        uint256 oldFee = spotTakerFeeBps;
        spotTakerFeeBps = pendingSpotTakerFeeBps;
        spotTakerFeeTimelockExpiry = 0;
        pendingSpotTakerFeeBps = 0;

        emit SpotTakerFeeUpdated(oldFee, spotTakerFeeBps);
    }

    /**
     * @notice Cancel a pending spot taker fee change
     */
    function cancelScheduledSpotTakerFee()
        external
        onlyOwner
    {
        if (spotTakerFeeTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        spotTakerFeeTimelockExpiry = 0;
        pendingSpotTakerFeeBps = 0;
        emit SpotTakerFeeChangeCancelled();
    }

    /**
     * @notice Schedule referral fee change
     * @param _newFeeBps New fee in basis points (max 50 = 0.50%)
     * @dev Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     *      Call `applyReferralFee()` to apply.
     */
    function scheduleReferralFee(
        uint256 _newFeeBps
    ) external onlyOwner {
        if (referralFeeTimelockExpiry != 0) {
            revert PendingChangeExists();
        }
        if (_newFeeBps > MAX_REFERRAL_FEE) {
            revert ReferralFeeTooHigh();
        }

        pendingReferralFeeBps = _newFeeBps;
        referralFeeTimelockExpiry = block.timestamp + TIMELOCK_DELAY; // solhint-disable-line not-rely-on-time

        emit ReferralFeeChangeScheduled(
            _newFeeBps,
            referralFeeTimelockExpiry
        );
    }

    /**
     * @notice Apply pending referral fee after timelock
     * @dev Applies the fee change queued by `scheduleReferralFee`.
     */
    function applyReferralFee() external onlyOwner {
        if (referralFeeTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        if (block.timestamp < referralFeeTimelockExpiry) { // solhint-disable-line not-rely-on-time
            revert TimelockNotElapsed();
        }

        uint256 oldFee = referralFeeBps;
        referralFeeBps = pendingReferralFeeBps;
        referralFeeTimelockExpiry = 0;
        pendingReferralFeeBps = 0;

        emit ReferralFeeUpdated(oldFee, referralFeeBps);
    }

    /**
     * @notice Cancel a pending referral fee change
     */
    function cancelScheduledReferralFee()
        external
        onlyOwner
    {
        if (referralFeeTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        referralFeeTimelockExpiry = 0;
        pendingReferralFeeBps = 0;
        emit ReferralFeeChangeCancelled();
    }

    // ================================================================
    // V3.1: PER-PAIR FEE ADMIN (timelocked)
    // ================================================================

    /**
     * @notice Schedule a per-pair taker fee override
     * @param tokenIn Token sold by taker
     * @param tokenOut Token bought by taker
     * @param feeBps New per-pair taker fee in basis points
     * @dev Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     *      Set feeBps=0 to clear the override
     *      (reverts to global spotTakerFeeBps).
     */
    function schedulePairFee(
        address tokenIn,
        address tokenOut,
        uint256 feeBps
    ) external onlyOwner {
        if (feeBps > MAX_PAIR_FEE) revert PairFeeTooHigh();
        bytes32 ph = keccak256(
            abi.encodePacked(tokenIn, tokenOut)
        );
        if (pairFeeTimelockExpiry[ph] != 0) {
            revert PendingChangeExists();
        }
        pendingPairFee[ph] = feeBps;
        // solhint-disable-next-line not-rely-on-time
        pairFeeTimelockExpiry[ph] =
            block.timestamp + TIMELOCK_DELAY;

        emit PairFeeScheduled(
            ph, feeBps, pairFeeTimelockExpiry[ph]
        );
    }

    /**
     * @notice Apply a scheduled per-pair taker fee override
     * @param tokenIn Token sold by taker
     * @param tokenOut Token bought by taker
     */
    function applyPairFee(
        address tokenIn,
        address tokenOut
    ) external onlyOwner {
        bytes32 ph = keccak256(
            abi.encodePacked(tokenIn, tokenOut)
        );
        if (pairFeeTimelockExpiry[ph] == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < pairFeeTimelockExpiry[ph]) {
            revert TimelockNotElapsed();
        }

        uint256 oldFee = pairFeeOverrides[ph];
        pairFeeOverrides[ph] = pendingPairFee[ph];
        pairFeeTimelockExpiry[ph] = 0;
        pendingPairFee[ph] = 0;

        emit PairFeeApplied(ph, oldFee, pairFeeOverrides[ph]);
    }

    /**
     * @notice Cancel a scheduled per-pair fee change
     * @param tokenIn Token sold by taker
     * @param tokenOut Token bought by taker
     */
    function cancelScheduledPairFee(
        address tokenIn,
        address tokenOut
    ) external onlyOwner {
        bytes32 ph = keccak256(
            abi.encodePacked(tokenIn, tokenOut)
        );
        if (pairFeeTimelockExpiry[ph] == 0) {
            revert NoPendingChange();
        }
        pairFeeTimelockExpiry[ph] = 0;
        pendingPairFee[ph] = 0;
        emit PairFeeCancelled(ph);
    }

    // ================================================================
    // V3.1: FEE ORACLE ADMIN (timelocked)
    // ================================================================

    /**
     * @notice Schedule a fee oracle change
     * @param newOracle New oracle address (address(0) to disable)
     * @dev Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     *      The oracle implements IFeeOracle.
     */
    function scheduleFeeOracle(
        address newOracle
    ) external onlyOwner {
        if (feeOracleTimelockExpiry != 0) {
            revert PendingChangeExists();
        }
        pendingFeeOracle = newOracle;
        // solhint-disable-next-line not-rely-on-time
        feeOracleTimelockExpiry =
            block.timestamp + TIMELOCK_DELAY;

        emit FeeOracleScheduled(
            feeOracle, newOracle, feeOracleTimelockExpiry
        );
    }

    /**
     * @notice Apply a scheduled fee oracle change
     */
    function applyFeeOracle() external onlyOwner {
        if (feeOracleTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < feeOracleTimelockExpiry) {
            revert TimelockNotElapsed();
        }

        address oldOracle = feeOracle;
        feeOracle = pendingFeeOracle;
        feeOracleTimelockExpiry = 0;
        pendingFeeOracle = address(0);

        emit FeeOracleApplied(oldOracle, feeOracle);
    }

    /**
     * @notice Cancel a scheduled fee oracle change
     */
    function cancelScheduledFeeOracle()
        external
        onlyOwner
    {
        if (feeOracleTimelockExpiry == 0) {
            revert NoPendingChange();
        }
        feeOracleTimelockExpiry = 0;
        pendingFeeOracle = address(0);
        emit FeeOracleCancelled();
    }

    // ================================================================
    // ADMIN — AUTHORIZED ADAPTERS (V3.1)
    // ================================================================

    /**
     * @notice Schedule an adapter authorization change
     * @param adapter Address of the adapter contract
     * @param authorized Whether to authorize or deauthorize
     * @dev Authorized adapters can act as taker without providing
     *      an ECDSA signature (contracts cannot sign EIP-712).
     *      Pioneer phase: applies immediately (TIMELOCK_DELAY == 0).
     */
    function scheduleAdapterAuth(
        address adapter,
        bool authorized
    ) external onlyOwner {
        if (adapter == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time
        uint256 expiry = block.timestamp + TIMELOCK_DELAY;
        pendingAdapterAuth[adapter] = authorized;
        adapterTimelockExpiry[adapter] = expiry;
        emit AdapterScheduled(adapter, authorized, expiry);
    }

    /**
     * @notice Apply a scheduled adapter authorization after timelock
     * @param adapter Address of the adapter contract
     */
    function applyAdapterAuth(
        address adapter
    ) external onlyOwner {
        uint256 expiry = adapterTimelockExpiry[adapter];
        if (expiry == 0) revert NoPendingChange();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < expiry) {
            revert AdapterTimelockNotExpired();
        }
        bool auth = pendingAdapterAuth[adapter];
        authorizedAdapters[adapter] = auth;
        adapterTimelockExpiry[adapter] = 0;
        delete pendingAdapterAuth[adapter];
        emit AdapterApplied(adapter, auth);
    }

    /**
     * @notice Cancel a scheduled adapter authorization change
     * @param adapter Address of the adapter contract
     */
    function cancelScheduledAdapter(
        address adapter
    ) external onlyOwner {
        if (adapterTimelockExpiry[adapter] == 0) {
            revert NoPendingChange();
        }
        adapterTimelockExpiry[adapter] = 0;
        delete pendingAdapterAuth[adapter];
        emit AdapterCancelled(adapter);
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
        emit EmergencyStop(_msgSender(), reason);
    }

    /**
     * @notice Resume trading after emergency stop
     * @dev Can only be called by owner
     */
    function resumeTrading() external onlyOwner {
        emergencyStop = false;
        emit TradingResumed(_msgSender());
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

    /**
     * @notice Remove a fee token from the feeTokens array
     *         using swap-and-pop (H-02 remediation)
     * @param token Address of the token to remove
     * @dev Only callable by owner. Allows recovery when a
     *      reverting token permanently blocks fee operations.
     */
    function removeFeeToken(
        address token
    ) external onlyOwner {
        if (!isFeeToken[token]) revert FeeTokenNotFound();

        uint256 len = feeTokens.length;
        for (uint256 i; i < len; ++i) {
            if (feeTokens[i] == token) {
                feeTokens[i] = feeTokens[len - 1];
                feeTokens.pop();
                isFeeToken[token] = false;
                emit FeeTokenRemoved(token);
                return;
            }
        }
        // Should not reach here due to isFeeToken guard
        revert FeeTokenNotFound();
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - FEE CLAIMS
    // ================================================================

    /**
     * @notice Claim any residual accrued fees for a token
     * @dev Retained for draining pre-migration accrued
     *      balances. Normal fee flow uses push (direct
     *      transfer) as of the push-pattern migration.
     * @param token ERC20 token to withdraw fees in
     */
    function claimFees(
        address token
    ) external nonReentrant {
        address caller = _msgSender();

        uint256 amount = accruedFees[caller][token];
        if (amount == 0) revert ZeroAmount();

        accruedFees[caller][token] = 0;
        IERC20(token).safeTransfer(caller, amount);

        emit FeesClaimed(caller, token, amount);
    }

    // ================================================================
    // EXTERNAL FUNCTIONS - INTENT SETTLEMENT (Phase 3)
    //   H-01: Access control on settleIntent
    //   H-02: Token binding in IntentCollateral
    //   H-03: Real token escrow
    // ================================================================

    /* solhint-disable code-complexity, function-max-lines */
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
     * @param matchingValidator Validator who matched (H-03)
     * @param referrer Direct referrer (address(0) = none)
     * @param referrer2 Referrer's referrer (address(0) = none)
     * @param solverSignature EIP-712 `IntentAcceptance`
     *        signature produced by the `solver` (C-01 Round 8)
     * @dev Trader's tokens are actually escrowed into this
     *      contract via safeTransferFrom. Trader must have
     *      approved this contract for tokenIn beforehand.
     *      Rebasing tokens (stETH, AMPL) are not supported
     *      for intent settlement (M-06).
     *      C-01 (Round 8): The `solver` MUST have signed an
     *      `IntentAcceptance` typed-data message covering all
     *      the economic fields of the intent. Without this
     *      signature, a malicious trader could name any
     *      address as "solver" and drain that address's
     *      pre-approved allowance via `settleIntent`.
     */
    function lockIntentCollateral(
        bytes32 intentId,
        address solver,
        address tokenIn,
        address tokenOut,
        uint256 traderAmount,
        uint256 solverAmount,
        uint256 deadline,
        address matchingValidator,
        address referrer,
        address referrer2,
        bytes calldata solverSignature
    ) external nonReentrant whenNotPaused {
        // L-03/L-05: Enforce emergencyStop
        if (emergencyStop) revert EmergencyStopActive();

        address caller = _msgSender();

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
        if (matchingValidator == address(0)) {
            revert InvalidMatchingValidator();
        }

        // C-01 (Round 8): Verify solver's EIP-712 consent.
        // The solver must have signed an IntentAcceptance
        // message covering exactly these economic fields.
        bytes32 acceptanceHash = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    INTENT_ACCEPTANCE_TYPEHASH,
                    intentId,
                    caller,
                    solver,
                    tokenIn,
                    tokenOut,
                    traderAmount,
                    solverAmount,
                    deadline
                )
            )
        );
        address recovered = ECDSA.recover(
            acceptanceHash,
            solverSignature
        );
        if (recovered != solver) {
            revert InvalidSolverSignature();
        }

        intentCollateral[intentId] = IntentCollateral({
            trader: caller,
            locked: true,
            settled: false,
            solver: solver,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            matchingValidator: matchingValidator,
            referrer: referrer,
            referrer2: referrer2,
            traderAmount: traderAmount,
            solverAmount: solverAmount,
            deadline: deadline
        });

        // H-03: Actually escrow trader's tokens
        // M-07: Balance check guards against fee-on-transfer tokens
        uint256 balBefore = IERC20(tokenIn).balanceOf(
            address(this)
        );
        IERC20(tokenIn).safeTransferFrom(
            caller,
            address(this),
            traderAmount
        );
        uint256 balAfter = IERC20(tokenIn).balanceOf(
            address(this)
        );
        if (balAfter - balBefore != traderAmount) {
            revert FeeOnTransferNotSupported();
        }

        emit IntentCollateralLocked(
            intentId,
            caller,
            solver,
            traderAmount,
            solverAmount
        );
    }
    /* solhint-enable code-complexity, function-max-lines */

    /* solhint-disable code-complexity, function-max-lines */
    /**
     * @notice Settle intent with bilateral swap (H-01, C-01)
     * @param intentId Intent identifier
     * @dev Only the trader or designated solver may call.
     *      Token addresses are validated against the locked
     *      intent record (H-02). Trader's escrowed tokens
     *      go to solver; solver's tokens go to trader.
     *      C-01: Fees are calculated and distributed via
     *      the standard fee split mechanism.
     *      M-05: CEI pattern - state updated before transfers.
     *
     *      M-02 WARNING (Two-Approval Requirement): The solver
     *      MUST approve this contract for BOTH the net amount
     *      (solverAmount - solverFee) transferred to the trader
     *      AND the solverFee transferred to this contract. These
     *      are two separate `safeTransferFrom` calls, so the total
     *      approval needed is `solverAmount`. A single approval of
     *      `solverAmount` covers both transfers. Solvers should
     *      approve at least `coll.solverAmount` before settlement.
     */
    function settleIntent(
        bytes32 intentId
    ) external nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();

        address caller = _msgSender();

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
            caller != coll.trader
                && caller != coll.solver
        ) {
            revert UnauthorizedSettler();
        }

        // M-05: CEI - mark settled before external calls
        coll.settled = true;

        // Enforce volume limits on intent settlement
        _checkVolumeLimits(coll.traderAmount, coll.solverAmount);

        // C-01: Trader (maker equivalent) earns rebate,
        // solver (taker equivalent) pays fee.
        // H-02 (Round 6): Both rebate and fee are calculated
        // on solverAmount (tokenOut) so they share the same
        // denomination, preventing cross-token accounting
        // errors when tokenIn and tokenOut have different
        // decimals or valuations.
        uint256 traderRebate = (coll.solverAmount
            * SPOT_MAKER_REBATE) / BASIS_POINTS_DIVISOR;
        // V3.1: Per-pair fee override + oracle discount.
        // Solver is the taker-equivalent: solver provides
        // coll.tokenOut and receives coll.tokenIn. So from
        // the solver's perspective, tokenIn = coll.tokenOut
        // and tokenOut = coll.tokenIn.
        uint256 intentEffectiveFee = _getEffectiveTakerFee(
            coll.tokenOut,
            coll.tokenIn,
            coll.solver
        );
        uint256 solverFee = (coll.solverAmount
            * intentEffectiveFee) / BASIS_POINTS_DIVISOR;
        // V3.1: Prevent dust intents from paying zero fee
        if (solverFee == 0) revert FillTooSmall();

        // Calculate referral surcharge (only if referred)
        uint256 intentReferralSurcharge;
        if (coll.referrer != address(0)) {
            intentReferralSurcharge = (coll.solverAmount
                * referralFeeBps) / BASIS_POINTS_DIVISOR;
        }

        // Total deducted from solver
        uint256 totalSolverDeduction =
            solverFee + intentReferralSurcharge;

        // Trader sends full amount (no fee deduction)
        uint256 solverNet =
            coll.solverAmount - totalSolverDeduction;

        // Transfer escrowed trader tokens: full amount to
        // solver (trader pays no fee, earns rebate)
        IERC20(coll.tokenIn).safeTransfer(
            coll.solver,
            coll.traderAmount
        );

        // Transfer solver tokens to trader (minus fee)
        // M-07: Balance check for fee-on-transfer tokens
        uint256 traderBalBefore =
            IERC20(coll.tokenOut).balanceOf(coll.trader);
        IERC20(coll.tokenOut).safeTransferFrom(
            coll.solver,
            coll.trader,
            solverNet
        );
        uint256 traderBalAfter =
            IERC20(coll.tokenOut).balanceOf(coll.trader);
        if (
            traderBalAfter - traderBalBefore != solverNet
        ) {
            revert FeeOnTransferNotSupported();
        }

        // Solver fee + referral surcharge: transfer from
        // solver to contract
        // M-01: Balance check for fee-on-transfer tokens
        if (totalSolverDeduction > 0) {
            uint256 feeBalBefore =
                IERC20(coll.tokenOut).balanceOf(
                    address(this)
                );
            IERC20(coll.tokenOut).safeTransferFrom(
                coll.solver,
                address(this),
                totalSolverDeduction
            );
            uint256 feeBalAfter =
                IERC20(coll.tokenOut).balanceOf(
                    address(this)
                );
            if (
                feeBalAfter - feeBalBefore
                    != totalSolverDeduction
            ) {
                revert FeeOnTransferNotSupported();
            }
        }

        // Distribute base solver fee with trader rebate
        if (solverFee > 0) {
            uint256 rebate = traderRebate > solverFee
                ? solverFee : traderRebate;
            uint256 netFee = solverFee - rebate;

            // Pay rebate to trader from solver fee
            if (rebate > 0) {
                IERC20(coll.tokenOut).safeTransfer(
                    coll.trader, rebate
                );
            }

            // Distribute remaining net fee
            if (netFee > 0) {
                _accrueFeeSplit(netFee, coll.tokenOut);
                _trackFeeToken(coll.tokenOut);
                totalFeesCollected += netFee;
            }
        }

        // Distribute referral surcharge (if applicable)
        if (intentReferralSurcharge > 0) {
            bytes32 intentTradeId = keccak256(
                abi.encodePacked(intentId, coll.trader)
            );
            _distributeReferralFee(
                intentReferralSurcharge,
                coll.tokenOut,
                coll.referrer,
                coll.referrer2,
                intentTradeId
            );
        }

        emit IntentSettled(
            intentId,
            coll.trader,
            coll.solver,
            coll.traderAmount,
            coll.solverAmount
        );
    }
    /* solhint-enable code-complexity, function-max-lines */

    /**
     * @notice Cancel intent and return escrowed collateral
     * @param intentId Intent identifier
     * @dev Can only be called by trader after deadline has
     *      passed (M-03 fix). Returns escrowed tokens.
     */
    function cancelIntent(
        bytes32 intentId
    ) external nonReentrant {
        address caller = _msgSender();

        IntentCollateral storage coll =
            intentCollateral[intentId];

        if (!coll.locked) revert CollateralNotLocked();
        if (coll.settled) revert AlreadySettled();
        if (caller != coll.trader) {
            revert InvalidSignature();
        }
        // M-03: Enforce deadline before allowing cancel
        // solhint-disable-next-line not-rely-on-time,gas-strict-inequalities
        if (block.timestamp <= coll.deadline) {
            revert IntentDeadlineNotPassed();
        }

        coll.locked = false;
        coll.settled = true;

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
    // PUBLIC FUNCTIONS
    // ================================================================

    /**
     * @notice Disabled to prevent accidental loss of contract
     *         admin control
     * @dev Always reverts. Ownership can only be transferred via
     *      two-step {transferOwnership} + {acceptOwnership} flow.
     */
    function renounceOwnership() public pure override {
        revert InvalidAddress();
    }

    // ================================================================
    // VIEW FUNCTIONS
    // ================================================================

    /* solhint-disable ordering */
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
    /* solhint-enable ordering */

    /**
     * @notice Check if an order has been fully consumed
     * @param orderHash Order EIP-712 hash
     * @param orderAmountIn Original `amountIn` of the signed order
     * @return True if `filledAmounts[orderHash] == orderAmountIn`
     * @dev Callers must supply the original signed amount because
     *      the contract stores only cumulative fill, not the full
     *      order.
     */
    function isOrderFilled(
        bytes32 orderHash,
        uint256 orderAmountIn
    ) external view returns (bool) {
        return filledAmounts[orderHash] == orderAmountIn;
    }

    /**
     * @notice Get the unfilled remainder of an order
     * @param orderHash Order EIP-712 hash
     * @param orderAmountIn Original `amountIn` of the signed order
     * @return remaining The amount of tokenIn still available to
     *         consume from this order; zero if fully filled or if
     *         the cumulative fill already matches/exceeds amountIn
     */
    function getOrderRemaining(
        bytes32 orderHash,
        uint256 orderAmountIn
    ) external view returns (uint256 remaining) {
        uint256 filled = filledAmounts[orderHash];
        if (orderAmountIn > filled) {
            return orderAmountIn - filled;
        }
        return 0;
    }

    /**
     * @notice Verify an order's EIP-712 signature (public, for
     *         WebApp pre-submission verification)
     * @dev Allows frontends to confirm that an order is properly
     *      signed before sending it to the validator's order book.
     * @param order Order to verify
     * @param signature EIP-712 signature
     * @return valid True if signature matches order.trader
     */
    function verifyOrderSignature(
        Order calldata order,
        bytes calldata signature
    ) external view returns (bool valid) {
        bytes32 orderHash =
            _hashTypedDataV4(_hashOrder(order));
        address recovered = orderHash.recover(signature);
        return recovered == order.trader;
    }

    /**
     * @notice Get the EIP-712 hash of an order (for signing)
     * @dev Frontend uses this to compute the digest for signing
     * @param order Order to hash
     * @return digest EIP-712 typed data hash
     */
    function getOrderHash(
        Order calldata order
    ) external view returns (bytes32 digest) {
        return _hashTypedDataV4(_hashOrder(order));
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

    /* solhint-disable code-complexity, function-max-lines */
    /**
     * @notice Core settlement logic shared by `settleTrade` and
     *         `settleTradesBatch` (via `_settleTradeExternal`)
     * @dev Extracted from the original settleTrade in V3.1 to
     *      avoid duplicating the full body. Uses `_getEffectiveTakerFee`
     *      for per-pair + oracle fee lookups.
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFillAmount Maker fill amount
     * @param takerFillAmount Taker fill amount
     * @param makerSignature Maker's EIP-712 signature
     * @param takerSignature Taker's EIP-712 signature
     */
    function _settleTradeCoreLogic(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) internal {
        if (emergencyStop) revert EmergencyStopActive();

        // === CHECKS ===

        _validateOrders(makerOrder, takerOrder);

        // Compute hashes once (used in multiple sub-checks)
        bytes32 makerHash =
            _hashTypedDataV4(_hashOrder(makerOrder));
        bytes32 takerHash =
            _hashTypedDataV4(_hashOrder(takerOrder));

        _verifySignatures(
            makerOrder,
            takerOrder,
            makerHash,
            takerHash,
            makerSignature,
            takerSignature
        );

        _verifyOrdersMatch(makerOrder, takerOrder);

        _verifyFillAmounts(
            makerOrder,
            takerOrder,
            makerFillAmount,
            takerFillAmount,
            makerHash,
            takerHash
        );

        _checkVolumeLimits(
            makerFillAmount,
            takerFillAmount
        );

        _checkFillBalancesAndAllowances(
            makerOrder,
            takerOrder,
            makerFillAmount,
            takerFillAmount
        );

        // M-06: Enforce maxSlippageBps on the fill
        _checkSlippageOnFill(
            makerOrder,
            makerFillAmount,
            takerFillAmount
        );

        // H-V3-01 (Round 8): Both rebate and fee are
        // calculated on takerFillAmount (taker.tokenIn) so
        // they share the same denomination.
        uint256 makerRebate = (takerFillAmount
            * SPOT_MAKER_REBATE) / BASIS_POINTS_DIVISOR;

        // V3.1: Per-pair fee override + oracle discount
        uint256 effectiveFee = _getEffectiveTakerFee(
            takerOrder.tokenIn,
            takerOrder.tokenOut,
            takerOrder.trader
        );
        uint256 takerFee = (takerFillAmount
            * effectiveFee) / BASIS_POINTS_DIVISOR;

        // H-02 (Round 8): Reject fills so small that the
        // taker fee rounds to zero via integer division.
        if (takerFee == 0) {
            revert FillTooSmall();
        }

        // Calculate referral surcharge (only if referred)
        uint256 referralSurcharge;
        if (takerOrder.referrer != address(0)) {
            referralSurcharge = (takerFillAmount
                * referralFeeBps) / BASIS_POINTS_DIVISOR;
        }

        // Total amount deducted from taker on this fill
        uint256 totalTakerDeduction =
            takerFee + referralSurcharge;

        // === EFFECTS (before external calls) ===

        // Advance per-order fill accumulators
        uint256 makerFilledTotal =
            filledAmounts[makerHash] + makerFillAmount;
        uint256 takerFilledTotal =
            filledAmounts[takerHash] + takerFillAmount;
        filledAmounts[makerHash] = makerFilledTotal;
        filledAmounts[takerHash] = takerFilledTotal;

        // Only consume the nonce once a side becomes fully
        // filled
        bool makerFullyFilled =
            makerFilledTotal == makerOrder.amountIn;
        bool takerFullyFilled =
            takerFilledTotal == takerOrder.amountIn;
        if (makerFullyFilled) {
            _useNonce(makerOrder.trader, makerOrder.nonce);
        }
        if (takerFullyFilled) {
            _useNonce(takerOrder.trader, takerOrder.nonce);
        }

        // M-01: Track both sides of the fill
        totalTradingVolume +=
            makerFillAmount + takerFillAmount;
        dailyVolumeUsed +=
            makerFillAmount + takerFillAmount;

        // === INTERACTIONS (after all state updates) ===

        _executeAtomicSettlement(
            makerOrder,
            takerOrder,
            makerFillAmount,
            takerFillAmount,
            totalTakerDeduction
        );

        // Distribute net fee (takerFee - makerRebate) with
        // rebate paid to maker
        _distributeFeesWithRebate(
            takerFee,
            makerRebate,
            takerOrder.tokenIn,
            makerOrder.trader,
            makerOrder.matchingValidator
        );

        bytes32 tradeId = keccak256(
            abi.encodePacked(makerHash, takerHash)
        );

        // Distribute referral surcharge (if applicable)
        if (referralSurcharge > 0) {
            _distributeReferralFee(
                referralSurcharge,
                takerOrder.tokenIn,
                takerOrder.referrer,
                takerOrder.referrer2,
                tradeId
            );
        }

        emit TradeSettled(
            tradeId,
            makerOrder.trader,
            takerOrder.trader,
            makerOrder.tokenIn,
            makerOrder.tokenOut,
            makerFillAmount,
            takerFillAmount,
            makerRebate,
            takerFee + referralSurcharge,
            makerOrder.matchingValidator,
            _msgSender()
        );

        emit TradePartiallySettled(
            tradeId,
            makerOrder.trader,
            takerOrder.trader,
            makerHash,
            takerHash,
            makerFillAmount,
            takerFillAmount,
            makerFilledTotal,
            takerFilledTotal,
            makerFullyFilled,
            takerFullyFilled
        );
    }
    /* solhint-enable code-complexity, function-max-lines */

    /**
     * @notice Compute the effective taker fee for a token pair,
     *         factoring in per-pair overrides and oracle discounts
     * @param tokenIn Address of the input token (taker side)
     * @param tokenOut Address of the output token (taker side)
     * @param trader Address of the taker
     * @return feeBps Effective taker fee in basis points
     * @dev Lookup order: pairFeeOverrides[pairHash] → spotTakerFeeBps.
     *      If a fee oracle is set, its discount is subtracted (fail-open
     *      on revert: base fee is used if oracle reverts).
     */
    function _getEffectiveTakerFee(
        address tokenIn,
        address tokenOut,
        address trader
    ) internal view returns (uint256 feeBps) {
        bytes32 pairHash = keccak256(
            abi.encodePacked(tokenIn, tokenOut)
        );
        feeBps = pairFeeOverrides[pairHash];
        if (feeBps == 0) {
            feeBps = spotTakerFeeBps; // Global fallback
        }

        if (feeOracle != address(0)) {
            // Fail-open: oracle error falls back to base fee
            // solhint-disable-next-line no-empty-blocks
            try IFeeOracle(feeOracle).getDiscountBps(
                trader, pairHash
            ) returns (uint256 discount) {
                if (discount < feeBps) {
                    feeBps -= discount;
                }
            } catch {
                // Oracle failure: use base fee (fail-open)
            }
        }
    }

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
     * @notice Execute atomic settlement on the given fill amounts
     *         with maker rebate and taker fee accounting
     * @param makerOrder Maker's order (for addresses only)
     * @param takerOrder Taker's order (for addresses only)
     * @param makerFillAmount Portion of maker.tokenIn to move
     * @param takerFillAmount Portion of taker.tokenIn to move
     * @param takerFeeOnFill Total amount (takerFee + referral
     *        surcharge) withheld from takerFillAmount on its way
     *        to the maker
     * @dev Maker sends `makerFillAmount` of maker.tokenIn to taker
     *      (no fee). Taker sends `takerFillAmount` of taker.tokenIn
     *      to this contract in a single safeTransferFrom, then the
     *      contract forwards (takerFillAmount - takerFeeOnFill) to
     *      maker. The withheld fee remains in the contract for
     *      distribution.
     *      M-03 Round 6: Consolidated taker transfer to a single
     *      pull, preventing griefing via allowance manipulation
     *      and reducing external calls.
     *      M-07: Uses balance-before/after to detect and
     *      reject fee-on-transfer tokens.
     */
    function _executeAtomicSettlement(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        uint256 takerFeeOnFill
    ) internal {
        // Maker sends makerFillAmount to taker (no fee)
        // M-07: Check maker's transfer for fee-on-transfer
        uint256 balBefore = IERC20(makerOrder.tokenIn)
            .balanceOf(takerOrder.trader);
        IERC20(makerOrder.tokenIn).safeTransferFrom(
            makerOrder.trader,
            takerOrder.trader,
            makerFillAmount
        );
        uint256 balAfter = IERC20(makerOrder.tokenIn)
            .balanceOf(takerOrder.trader);
        if (balAfter - balBefore != makerFillAmount) {
            revert FeeOnTransferNotSupported();
        }

        // M-03 Round 6: Single pull from taker to contract,
        // then distribute internally. Prevents griefing via
        // allowance manipulation between two separate pulls.
        // M-07: Check taker's transfer for fee-on-transfer
        balBefore = IERC20(takerOrder.tokenIn)
            .balanceOf(address(this));
        IERC20(takerOrder.tokenIn).safeTransferFrom(
            takerOrder.trader,
            address(this),
            takerFillAmount
        );
        balAfter = IERC20(takerOrder.tokenIn)
            .balanceOf(address(this));
        if (balAfter - balBefore != takerFillAmount) {
            revert FeeOnTransferNotSupported();
        }

        // Distribute net amount to maker from contract
        uint256 takerNet = takerFillAmount - takerFeeOnFill;
        if (takerNet > 0) {
            IERC20(takerOrder.tokenIn).safeTransfer(
                makerOrder.trader,
                takerNet
            );
        }
        // takerFeeOnFill remains in contract for distribution
    }

    /**
     * @notice Distribute fees with maker rebate
     * @param takerFee Total taker fee collected
     * @param makerRebate Rebate to pay to maker
     * @param feeToken Token in which fees are denominated
     * @param makerTrader Maker address receiving rebate
     * @param matchingValidator Validator who matched (event)
     * @dev Pays makerRebate from takerFee to maker, then
     *      distributes remaining net fee via 70/30 split
     *      (LP/Vault). Push pattern — immediate.
     */
    function _distributeFeesWithRebate(
        uint256 takerFee,
        uint256 makerRebate,
        address feeToken,
        address makerTrader,
        address matchingValidator
    ) internal {
        if (takerFee == 0) return;

        // Safety: rebate must not exceed taker fee
        if (makerRebate > takerFee) {
            makerRebate = takerFee;
        }

        uint256 netFee = takerFee - makerRebate;
        totalFeesCollected += netFee;

        // Pay rebate to maker
        if (makerRebate > 0) {
            IERC20(feeToken).safeTransfer(
                makerTrader,
                makerRebate
            );
        }

        // Distribute net fee via 70/30 (LP/Vault)
        if (netFee > 0) {
            _accrueFeeSplit(netFee, feeToken);
            _trackFeeToken(feeToken);
        }

        // Event amounts based on net fee
        uint256 lpAmt = (netFee * LP_SHARE)
            / BASIS_POINTS_DIVISOR;
        uint256 vaultAmt = netFee - lpAmt;

        emit FeesDistributed(
            matchingValidator,
            lpAmt,
            vaultAmt,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
        );
    }

    /**
     * @notice Distribute referral surcharge among referrer,
     *         referrer2, and ODDAO treasury
     * @param surcharge Total referral surcharge amount
     * @param token Token in which surcharge is denominated
     * @param referrer Direct referrer address (must be non-zero)
     * @param referrer2 Referrer's referrer (address(0) = share
     *        goes to ODDAO treasury)
     * @param tradeId Trade identifier for event emission
     * @dev Split: 70% referrer, 20% referrer2 (or ODDAO),
     *      10% ODDAO treasury. Push pattern — immediate.
     *      M-01 Audit 2026-03-25: Uses defensive low-level
     *      calls with gas stipend for user-provided referrer
     *      addresses. On transfer failure, the amount is
     *      redirected to ODDAO treasury (same pattern as
     *      _claimAllPendingFees). ODDAO treasury transfer
     *      uses safeTransfer since it is admin-controlled.
     */
    // solhint-disable-next-line code-complexity
    function _distributeReferralFee(
        uint256 surcharge,
        address token,
        address referrer,
        address referrer2,
        bytes32 tradeId
    ) internal {
        if (surcharge == 0) return;

        uint256 referrerAmt = (surcharge * REFERRAL_SHARE)
            / BASIS_POINTS_DIVISOR;
        uint256 referrer2Amt = (surcharge * REFERRER2_SHARE)
            / BASIS_POINTS_DIVISOR;
        // ODDAO gets remainder (avoids rounding dust)
        uint256 oddaoAmt = surcharge - referrerAmt
            - referrer2Amt;

        address oddaoAddr = feeRecipients.oddaoTreasury;

        // Pay referrer (70%) — defensive low-level call
        // (M-01: prevents DoS from reverting recipients)
        if (referrerAmt > 0) {
            if (!_safeTransferToken(token, referrer,
                referrerAmt)) {
                // Redirect to ODDAO on failure
                emit ReferralFeeRedirected(
                    tradeId, referrer, referrerAmt
                );
                oddaoAmt += referrerAmt;
                referrerAmt = 0;
            }
        }

        // Pay referrer2 (20%) or redirect to ODDAO
        if (referrer2 != address(0)) {
            if (referrer2Amt > 0) {
                if (!_safeTransferToken(token, referrer2,
                    referrer2Amt)) {
                    // Redirect to ODDAO on failure
                    oddaoAmt += referrer2Amt;
                    emit ReferralFeeRedirected(
                        tradeId,
                        referrer2,
                        referrer2Amt
                    );
                    referrer2Amt = 0;
                }
            }
        } else {
            // No referrer2 → ODDAO gets their share too
            oddaoAmt += referrer2Amt;
            referrer2Amt = 0;
        }

        // Pay ODDAO treasury (10% + any redirected share)
        // safeTransfer is safe here — ODDAO is admin-set
        if (oddaoAmt > 0) {
            IERC20(token).safeTransfer(
                oddaoAddr, oddaoAmt
            );
        }

        emit ReferralFeeDistributed(
            tradeId,
            referrer,
            referrer2,
            referrerAmt,
            referrer2Amt,
            oddaoAmt
        );
    }

    /**
     * @notice Attempt a defensive ERC20 transfer with gas
     *         stipend to prevent DoS from reverting recipients
     * @param token ERC20 token address
     * @param to Recipient address
     * @param amount Amount to transfer
     * @return success True if transfer succeeded
     * @dev Uses low-level call with 100k gas stipend.
     *      Returns false if the call reverts or the token
     *      returns false. Same pattern as _claimAllPendingFees.
     */
    function _safeTransferToken(
        address token,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // M-01 fix: gas-limited call prevents griefing
        /* solhint-disable avoid-low-level-calls */
        (bool ok, bytes memory ret) =
            token.call{gas: 100_000}(
                abi.encodeWithSelector(
                    IERC20.transfer.selector,
                    to,
                    amount
                )
            );
        /* solhint-enable avoid-low-level-calls */
        success = ok
            && (ret.length == 0
                || abi.decode(ret, (bool)));
    }

    /**
     * @notice Transfer a single fee amount directly to the LP
     *         pool and UnifiedFeeVault
     * @param fee Total fee amount
     * @param token Fee token address
     * @dev Push pattern: fees are transferred immediately
     *      during settlement, not accrued for later claim.
     *      70% LP Pool, 30% UnifiedFeeVault.
     *      LP share is computed first; vault receives the
     *      remainder to prevent dust accumulation (M-02).
     *      The vault handles the internal 70/20/10
     *      ODDAO/Staking/Protocol split.
     */
    function _accrueFeeSplit(
        uint256 fee,
        address token
    ) internal {
        uint256 lpShare = (fee * LP_SHARE)
            / BASIS_POINTS_DIVISOR;
        // Vault gets remainder (avoids rounding dust)
        uint256 vaultShare = fee - lpShare;

        if (lpShare > 0) {
            IERC20(token).safeTransfer(
                feeRecipients.liquidityPool, lpShare
            );
        }
        if (vaultShare > 0) {
            IERC20(token).safeTransfer(
                feeRecipients.feeVault, vaultShare
            );
        }
    }

    /**
     * @notice Track a new fee token for H-05 force-claims
     * @param token Token address to track
     * @dev Adds token to feeTokens array if not already
     *      tracked. Bounded by MAX_FEE_TOKENS.
     *      M-01 (Round 8): Silently skips when full instead
     *      of reverting. This prevents an attacker from
     *      bricking trade settlement by flooding the fee
     *      token list with 100 self-matched clones. Untracked
     *      fee tokens can still be claimed manually via
     *      `claimAccruedFees(recipient, token)`; only the
     *      force-claim-all iteration path will miss them.
     */
    function _trackFeeToken(address token) internal {
        if (!isFeeToken[token]) {
            // solhint-disable-next-line gas-strict-inequalities
            if (feeTokens.length >= MAX_FEE_TOKENS) {
                return;
            }
            isFeeToken[token] = true;
            feeTokens.push(token);
        }
    }

    /**
     * @notice Force-claim all accrued fees for a recipient
     *         across all tracked tokens (H-05, H-02)
     * @param recipient Address to claim fees for
     * @dev Called internally before updating fee recipients
     *      to prevent orphaned fee balances. Silently skips
     *      tokens with zero balance. Uses try/catch so a
     *      reverting token does not block fee recipient
     *      changes (H-02). Re-credits the amount on failure.
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
                // Low-level call handles both reverting
                // tokens (H-02) and tokens that return
                // false without reverting (VP-26).
                // M-04 Round 6: Gas stipend prevents a
                // malicious token from consuming all gas
                // and DOSing fee recipient changes.
                /* solhint-disable avoid-low-level-calls, reentrancy */
                (bool ok, bytes memory ret) = token.call{gas: 100_000}(
                    abi.encodeWithSelector(
                        IERC20.transfer.selector,
                        recipient,
                        amount
                    )
                );
                bool transferred = ok
                    && (ret.length == 0
                        || abi.decode(ret, (bool)));
                if (transferred) {
                    emit FeesClaimed(
                        recipient,
                        token,
                        amount
                    );
                } else {
                    // Re-credit on failure (H-02)
                    accruedFees[recipient][token] = amount;
                }
                /* solhint-enable avoid-low-level-calls, reentrancy */
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
     * @notice Enforce maxSlippageBps on a partial fill (M-06)
     * @param makerOrder Maker's order (supplies price ratio)
     * @param makerFillAmount Portion of maker.tokenIn consumed
     * @param takerFillAmount Portion of taker.tokenIn consumed
     * @dev Compares the taker's effective contribution against
     *      the proportional amount the maker would have expected
     *      at the maker's stated price, rejecting fills that fall
     *      below the configured slippage tolerance.
     */
    function _checkSlippageOnFill(
        Order calldata makerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount
    ) internal view {
        if (maxSlippageBps == 0) return;

        // At maker's signed price, the proportional amount of
        // maker.tokenOut (== taker.tokenIn) that maker expects
        // for consuming makerFillAmount of maker.tokenIn is:
        //   proportionalOut = makerFillAmount * amountOut / amountIn
        // The taker must provide at least (1 - slippage) of that
        // proportional amount.
        uint256 proportionalOut =
            (makerFillAmount * makerOrder.amountOut)
                / makerOrder.amountIn;
        uint256 minAcceptable = (proportionalOut
            * (BASIS_POINTS_DIVISOR - maxSlippageBps))
            / BASIS_POINTS_DIVISOR;
        if (takerFillAmount < minAcceptable) {
            revert SlippageTooHigh();
        }
    }

    /**
     * @notice Verify per-order fill invariants and fill-rate
     *         consistency (V3 partial fills)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFillAmount Portion of maker.tokenIn consumed
     * @param takerFillAmount Portion of taker.tokenIn consumed
     * @param makerHash EIP-712 digest of the maker order
     * @param takerHash EIP-712 digest of the taker order
     * @dev Three classes of checks:
     *      1. Non-zero fills. Zero-amount fills are rejected to
     *         prevent no-op settlements burning gas.
     *      2. Remainder bounds. Cumulative fill after this call
     *         must not exceed the signed amountIn on either side.
     *      3. Fill-rate consistency. The ratio of makerFill to
     *         takerFill must honor BOTH parties' signed prices:
     *         - Maker happy:
     *           `takerFill * maker.amountIn >= makerFill * maker.amountOut`
     *         - Taker happy:
     *           `makerFill * taker.amountIn >= takerFill * taker.amountOut`
     *         At an exact price match these become equalities; at
     *         a crossed market the maker's inequality is strict on
     *         the maker's favor and vice versa. Failing either one
     *         means the settler attempted to under-pay one side
     *         below the rate they signed for.
     */
    function _verifyFillAmounts(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount,
        bytes32 makerHash,
        bytes32 takerHash
    ) internal view {
        if (makerFillAmount == 0 || takerFillAmount == 0) {
            revert InvalidFillAmount();
        }

        // VT-04 (2026-08-23): a zero signed output turns the taker
        // proportionality bound below into `x * amountIn ≥ y * 0` —
        // always true — handing the matcher the entire fill ("I give
        // everything for nothing"). Zero `amountIn` is already
        // unreachable here (any fill trips FillExceedsRemaining against
        // a zero remaining cap); the zero-output case was not.
        if (makerOrder.amountOut == 0 || takerOrder.amountOut == 0) {
            revert InvalidFillAmount();
        }

        uint256 makerFilledAfter =
            filledAmounts[makerHash] + makerFillAmount;
        if (makerFilledAfter > makerOrder.amountIn) {
            revert FillExceedsRemaining();
        }
        uint256 takerFilledAfter =
            filledAmounts[takerHash] + takerFillAmount;
        if (takerFilledAfter > takerOrder.amountIn) {
            revert FillExceedsRemaining();
        }

        // Maker's rate must be honored: for every unit of
        // maker.tokenIn consumed, maker must receive at least
        // maker.amountOut / maker.amountIn units of maker.tokenOut.
        if (
            takerFillAmount * makerOrder.amountIn
                < makerFillAmount * makerOrder.amountOut
        ) {
            revert FillProportionalityMismatch();
        }

        // Taker's rate must be honored: for every unit of
        // taker.tokenIn consumed, taker must receive at least
        // taker.amountOut / taker.amountIn units of taker.tokenOut.
        if (
            makerFillAmount * takerOrder.amountIn
                < takerFillAmount * takerOrder.amountOut
        ) {
            revert FillProportionalityMismatch();
        }
    }

    // ================================================================
    // INTERNAL VIEW FUNCTIONS
    // ================================================================

    /**
     * @notice Verify EIP-712 signatures, fill state, and nonces
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerHash Precomputed EIP-712 digest of the maker order
     * @param takerHash Precomputed EIP-712 digest of the taker order
     * @param makerSignature Maker's signature
     * @param takerSignature Taker's signature
     * @dev Also checks that neither order is fully filled and that
     *      neither nonce has been consumed or cancelled.
     */
    function _verifySignatures(
        Order calldata makerOrder,
        Order calldata takerOrder,
        bytes32 makerHash,
        bytes32 takerHash,
        bytes calldata makerSignature,
        bytes calldata takerSignature
    ) internal view {
        if (
            makerHash.recover(makerSignature)
                != makerOrder.trader
        ) {
            revert InvalidSignature();
        }
        // V3.1: Authorized adapters (e.g. CLOBAdapter) are
        // contracts that act as taker. Contracts cannot produce
        // EIP-712 ECDSA signatures, so if the taker is an
        // authorized adapter we skip signature verification.
        // The adapter is security-gated by: (a) 48-hour timelock
        // on authorization, and (b) onlyRouter enforcement in the
        // adapter itself.
        if (!authorizedAdapters[takerOrder.trader]) {
            if (
                takerHash.recover(takerSignature)
                    != takerOrder.trader
            ) {
                revert InvalidSignature();
            }
        }

        // V3: orders are "fully filled" when cumulative fill
        // equals the signed amountIn. Any further fill on a
        // fully-consumed order is rejected here. The invariant
        // `filledAmounts[hash] <= order.amountIn` is enforced in
        // _verifyFillAmounts, so equality here is the terminal
        // state.
        if (filledAmounts[makerHash] == makerOrder.amountIn) {
            revert OrderAlreadyFilled();
        }
        if (filledAmounts[takerHash] == takerOrder.amountIn) {
            revert OrderAlreadyFilled();
        }

        // M-01: Check nonce bitmap (not sequential). The nonce
        // is set only when an order becomes fully filled or is
        // explicitly cancelled via invalidateNonce().
        if (_isNonceUsed(makerOrder.trader, makerOrder.nonce)) {
            revert NonceAlreadyUsed();
        }
        if (_isNonceUsed(takerOrder.trader, takerOrder.nonce)) {
            revert NonceAlreadyUsed();
        }
    }

    /**
     * @notice Check volume limits for a fill (M-01, V3 partial)
     * @param makerFillAmount Portion of maker.tokenIn consumed
     * @param takerFillAmount Portion of taker.tokenIn consumed
     * @dev Reverts if the individual fill exceeds `maxTradeSize`
     *      or if the daily volume limit is exceeded. Accumulation
     *      across partial fills naturally enforces the daily cap.
     */
    function _checkVolumeLimits(
        uint256 makerFillAmount,
        uint256 takerFillAmount
    ) internal view {
        if (
            makerFillAmount > maxTradeSize
                || takerFillAmount > maxTradeSize
        ) {
            revert TradeSizeExceedsLimit();
        }
        if (
            dailyVolumeUsed
                + makerFillAmount
                + takerFillAmount
                > dailyVolumeLimit
        ) {
            revert DailyVolumeLimitExceeded();
        }
    }

    /**
     * @notice Check token balances and allowances against fill
     *         amounts (V3 partial)
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @param makerFillAmount Portion of maker.tokenIn required
     * @param takerFillAmount Portion of taker.tokenIn required
     * @dev Reverts if either trader lacks sufficient balance or
     *      allowance for the fill amount they owe.
     */
    function _checkFillBalancesAndAllowances(
        Order calldata makerOrder,
        Order calldata takerOrder,
        uint256 makerFillAmount,
        uint256 takerFillAmount
    ) internal view {
        _checkSingleBalance(
            makerOrder.tokenIn,
            makerOrder.trader,
            makerFillAmount
        );
        _checkSingleBalance(
            takerOrder.tokenIn,
            takerOrder.trader,
            takerFillAmount
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
                order.nonce,
                order.referrer,
                order.referrer2
            )
        );
    }

    /**
     * @notice Verify that two orders are structurally compatible
     * @param makerOrder Maker's order
     * @param takerOrder Taker's order
     * @dev Checks opposite sides, matching token pairs, non-zero
     *      amounts, price-direction compatibility, and L-06
     *      (tokenIn != tokenOut). V3 partial fills remove the
     *      full-fill `amountIn <= amountOut` cross-checks; those
     *      are replaced by `_verifyFillAmounts`, which enforces
     *      fill-rate consistency on the actual fill amounts.
     */
    function _verifyOrdersMatch(
        Order calldata makerOrder,
        Order calldata takerOrder
    ) internal pure {
        // L-06: tokenIn must differ from tokenOut
        if (makerOrder.tokenIn == makerOrder.tokenOut) {
            revert InvalidOrder();
        }

        // Opposite sides
        if (makerOrder.isBuy == takerOrder.isBuy) {
            revert OrdersDontMatch();
        }

        // Token pairs must cross
        if (makerOrder.tokenIn != takerOrder.tokenOut) {
            revert OrdersDontMatch();
        }
        if (makerOrder.tokenOut != takerOrder.tokenIn) {
            revert OrdersDontMatch();
        }

        // Signed amounts must be non-zero (division guards)
        if (
            makerOrder.amountIn == 0
                || makerOrder.amountOut == 0
                || takerOrder.amountIn == 0
                || takerOrder.amountOut == 0
        ) {
            revert InvalidOrder();
        }

        // Price direction compatibility (unchanged from V2)
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

    // ================================================================
    // ERC2771Context OVERRIDES
    // (resolve Context vs ERC2771Context diamond)
    // ================================================================

    /**
     * @notice Resolve _msgSender between Context (via
     *         Ownable/Pausable) and ERC2771Context
     * @dev ERC2771Context overrides _msgSender() to extract
     *      the original signer from trusted-forwarder calldata.
     * @return sender The original transaction signer
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address sender)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve _msgData between Context (via
     *         Ownable/Pausable) and ERC2771Context
     * @return The original calldata (stripped of appended
     *         sender when forwarded)
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
     * @return Length of the context suffix (20 bytes when
     *         called via trusted forwarder, 0 otherwise)
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
