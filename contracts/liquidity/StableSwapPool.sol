// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from
    "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from
    "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title StableSwapPool
 * @author OmniCoin Development Team
 * @notice Curve-style StableSwap (hybrid CFMM) pool for two stable-correlated
 *         assets, e.g. XOM/USDC or RWA-stable/stable pairs. The pool's LP
 *         shares are themselves a standard ERC-20 token (this contract), so
 *         positions are freely composable across the OmniBazaar stack.
 * @dev Implements the Curve StableSwap invariant for n = 2 coins:
 *
 *          A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
 *
 *      where:
 *        - x_i are the coin balances, normalized to a common 18-decimal
 *          precision via per-coin rate multipliers;
 *        - D is the invariant (total pool value when balanced);
 *        - A is the amplification coefficient (higher A => flatter curve =>
 *          lower slippage near the peg, approaching a constant-sum AMM;
 *          lower A => behaves more like a constant-product AMM far from peg).
 *
 *      Both D (given balances) and the post-trade balance y (given the other
 *      balance) are solved with Newton's method. Every Newton loop is bounded
 *      to 255 iterations and reverts via {DidNotConverge} if it fails to
 *      reach a fixed point — there are no unbounded-gas paths.
 *
 *      Decimal handling: balances are stored in each token's native units but
 *      converted to a normalized 18-decimal space ("xp") for all invariant
 *      math. This lets the pool pair a 6-decimal token (USDC) with an
 *      18-decimal token (XOM) while treating one unit of each as equal value
 *      near the peg, exactly as Curve does with its `rates` array.
 *
 *      Fee model (70% LP-retained / 30% vault, applied consistently):
 *        - A configurable {tradingFeeBps} is charged on the swap output.
 *        - The SAME fee is charged as a Curve imbalance fee on imbalanced
 *          {addLiquidity} deposits and on {removeLiquidityOneCoin} single-coin
 *          withdrawals (per-coin rate `tradingFeeBps * N_COINS /
 *          (4 * (N_COINS - 1))`), so add + single-coin withdraw can never
 *          undercut a direct {exchange}. Balanced adds and balanced
 *          {removeLiquidity} are fee-free.
 *        - 70% of every fee (LP share) stays in the pool, accruing to LPs by
 *          increasing reserves (and therefore D) — realized when LPs burn.
 *        - 30% of every fee (staking + protocol share) is transferred to the
 *          {FEE_VAULT} (UnifiedFeeVault) for batched distribution.
 *
 *      Admin model (Pioneer Phase): the deployer holds DEFAULT_ADMIN_ROLE and
 *      ADMIN_ROLE directly and can change the fee, ramp A, or pause the pool
 *      with no built-in delay. Role holders are swappable addresses so a
 *      future, deliberate migration to governance needs only a role transfer.
 *
 *      Fee-on-transfer / rebasing tokens are NOT supported and are rejected
 *      fail-closed: every input pull measures the contract's balance delta and
 *      reverts {FeeOnTransferNotSupported} if fewer than the stated amount
 *      arrive, so internal reserve accounting can never overstate the real
 *      balance.
 *
 *      Security: ReentrancyGuard on every state-changing entry point, custom
 *      errors throughout, SafeERC20 for all token movements, and a deployer-
 *      controlled pause switch.
 *
 * @custom:audit 2026-05-30 — AUDITED → REMEDIATED → RE-AUDITED, deploy-ready.
 *      (0 C/H/M after
 *      remediation; Curve imbalance-fee alignment for add + single-coin
 *      withdraw, fail-closed FoT guard, dust-underflow guard). The audit /
 *      remediation / re-audit cycle is COMPLETE — do NOT repeat it before a
 *      future deploy. Operational pre-broadcast steps only: final
 *      Slither/Mythril once the tree compiles without the privacy WIP, set
 *      trading fee >= 2 bp (re-audit INFO-1), founder broadcast. Deployment
 *      DEFERRED until a real Situation requires the pool.
 */
contract StableSwapPool is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role permitted to change fees, ramp A, and pause the pool
    /// @dev Held by the deployer during Pioneer Phase (deployer-direct admin)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Number of coins in this pool (fixed at 2)
    uint256 public constant N_COINS = 2;

    /// @notice Basis-points denominator (100% = 10000)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice LP share of the trading fee in basis points (70%)
    uint256 public constant FEE_LP_BPS = 7000;

    /// @notice Minimum configurable trading fee in basis points (0.02%)
    /// @dev Prevents deploy-time footgun where fee=0 enables fee-free swaps.
    uint256 public constant MIN_FEE_BPS = 2;

    /// @notice Maximum configurable trading fee in basis points (1%)
    /// @dev Caps admin power; stable pools should never need more than 1%.
    uint256 public constant MAX_FEE_BPS = 100;

    /// @notice Precision A is stored with (A * A_PRECISION)
    /// @dev Matches Curve's later pools, enabling fractional A ramps.
    uint256 public constant A_PRECISION = 100;

    /// @notice Minimum amplification coefficient (A, un-precision-scaled)
    uint256 public constant MIN_A = 1;

    /// @notice Maximum amplification coefficient (A, un-precision-scaled)
    /// @dev 1e6 matches Curve's upper bound for A.
    uint256 public constant MAX_A = 1_000_000;

    /// @notice Maximum factor A may change by per ramp (10x), as in Curve
    uint256 public constant MAX_A_CHANGE = 10;

    /// @notice Minimum duration of an A ramp, preventing instant manipulation
    uint256 public constant MIN_RAMP_TIME = 1 days;

    /// @notice Maximum Newton's-method iterations before reverting
    uint256 public constant MAX_ITERATIONS = 255;

    /// @notice LP tokens permanently locked on the first deposit
    /// @dev Burned to the dead address to resist share-inflation attacks.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Dead address that receives the locked minimum liquidity
    address private constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ========================================================================
    // IMMUTABLE STATE
    // ========================================================================

    /// @notice First coin in the pool
    IERC20 public immutable COIN0;

    /// @notice Second coin in the pool
    IERC20 public immutable COIN1;

    /// @notice Fee vault (UnifiedFeeVault) receiving the non-LP fee share
    address public immutable FEE_VAULT;

    /// @notice Multiplier converting COIN0 native units to 18-decimal space
    /// @dev rate_i = 10 ** (18 - decimals_i); equals 1 for an 18-decimal coin.
    uint256 public immutable RATE0;

    /// @notice Multiplier converting COIN1 native units to 18-decimal space
    uint256 public immutable RATE1;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Stored reserve of COIN0 in native token units
    uint256 public reserve0;

    /// @notice Stored reserve of COIN1 in native token units
    uint256 public reserve1;

    /// @notice Trading fee charged on swap output, in basis points
    uint256 public tradingFeeBps;

    /// @notice Initial A value of an in-progress ramp (A * A_PRECISION)
    uint256 public initialA;

    /// @notice Target A value of an in-progress ramp (A * A_PRECISION)
    uint256 public futureA;

    /// @notice Timestamp the current A ramp started
    uint256 public initialATime;

    /// @notice Timestamp the current A ramp completes
    uint256 public futureATime;

    /// @notice Whether the pool is paused (blocks swaps and deposits)
    bool public paused;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a token swap is executed
    /// @param buyer Address that initiated and received the swap
    /// @param soldId Index of the coin sold (0 or 1)
    /// @param tokensSold Amount of the sold coin taken from the buyer
    /// @param boughtId Index of the coin bought (0 or 1)
    /// @param tokensBought Amount of the bought coin sent to the buyer
    /// @param fee Total fee charged in bought-coin units
    event TokenExchange(
        address indexed buyer,
        uint256 indexed soldId,
        uint256 tokensSold,
        uint256 indexed boughtId,
        uint256 tokensBought,
        uint256 fee
    );

    /* solhint-disable gas-indexed-events */
    /// @notice Emitted when liquidity is added
    /// @param provider Address that supplied the liquidity
    /// @param amount0 Amount of COIN0 deposited
    /// @param amount1 Amount of COIN1 deposited
    /// @param mintedLp LP tokens minted to the provider
    event AddLiquidity(
        address indexed provider,
        uint256 indexed amount0,
        uint256 indexed amount1,
        uint256 mintedLp
    );

    /// @notice Emitted when liquidity is removed (balanced or single-coin)
    /// @param provider Address that burned LP tokens
    /// @param amount0 Amount of COIN0 returned
    /// @param amount1 Amount of COIN1 returned
    /// @param burnedLp LP tokens burned
    event RemoveLiquidity(
        address indexed provider,
        uint256 indexed amount0,
        uint256 indexed amount1,
        uint256 burnedLp
    );

    /// @notice Emitted when the trading fee is changed
    /// @param oldFeeBps Previous fee in basis points
    /// @param newFeeBps New fee in basis points
    event TradingFeeUpdated(
        uint256 indexed oldFeeBps,
        uint256 indexed newFeeBps
    );

    /// @notice Emitted when an A ramp is scheduled
    /// @param initialA Starting A (A * A_PRECISION)
    /// @param futureA Target A (A * A_PRECISION)
    /// @param initialTime Ramp start timestamp
    /// @param futureTime Ramp completion timestamp
    event RampA(
        uint256 indexed initialA,
        uint256 indexed futureA,
        uint256 indexed initialTime,
        uint256 futureTime
    );

    /// @notice Emitted when an in-progress A ramp is stopped
    /// @param currentA A value frozen in place (A * A_PRECISION)
    /// @param time Timestamp the ramp was stopped
    event StopRampA(uint256 indexed currentA, uint256 indexed time);
    /* solhint-enable gas-indexed-events */

    /// @notice Emitted when the pool pause state changes
    /// @param paused True if now paused, false if unpaused
    event PauseStateChanged(bool indexed paused);

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when a supplied address is the zero address
    error ZeroAddress();

    /// @notice Thrown when the two coins are identical
    error IdenticalCoins();

    /// @notice Thrown when an amount argument is zero
    error ZeroAmount();

    /// @notice Thrown when a coin index is out of range or equals its pair
    /// @param i Index of the input coin
    /// @param j Index of the output coin
    error InvalidCoinIndex(uint256 i, uint256 j);

    /// @notice Thrown when a token's decimals exceed 18 (unsupported)
    /// @param decimals Reported decimals of the offending token
    error UnsupportedDecimals(uint8 decimals);

    /// @notice Thrown when Newton's method fails to converge in the bound
    error DidNotConverge();

    /// @notice Thrown when output is below the caller's minimum (slippage)
    /// @param requested Minimum the caller required
    /// @param actual Amount actually produced
    error SlippageExceeded(uint256 requested, uint256 actual);

    /// @notice Thrown when the first deposit is too small to seed the pool
    /// @param minted LP that would be minted before the minimum lock
    error InitialDepositTooSmall(uint256 minted);

    /// @notice Thrown when the first deposit omits one of the two coins
    /// @dev The seeding deposit must supply both coins to define the peg.
    error FirstDepositNeedsBothCoins();

    /// @notice Thrown when a fee above {MAX_FEE_BPS} is requested
    /// @param requested Requested fee in basis points
    error FeeTooHigh(uint256 requested);

    /// @notice Thrown when a fee below {MIN_FEE_BPS} is requested
    /// @param requested Requested fee in basis points
    error FeeTooLow(uint256 requested);

    /// @notice Thrown when the pool is paused
    error PoolPaused();

    /// @notice Thrown when an A value is outside [MIN_A, MAX_A]
    /// @param requested Requested A (un-precision-scaled)
    error InvalidA(uint256 requested);

    /// @notice Thrown when an A ramp changes A by more than {MAX_A_CHANGE}
    error ARampTooLarge();

    /// @notice Thrown when an A ramp ends sooner than {MIN_RAMP_TIME}
    error ARampTooFast();

    /// @notice Thrown when burning more LP than the caller holds
    /// @param requested LP requested to burn
    /// @param available LP held by the caller
    error InsufficientLPBalance(uint256 requested, uint256 available);

    /// @notice Thrown when an input token delivers fewer tokens than stated
    /// @dev Fail-closed guard against fee-on-transfer / rebasing tokens, which
    ///      would otherwise corrupt the pool's internal reserve accounting.
    error FeeOnTransferNotSupported();

    /// @notice Thrown when a swap or withdrawal output rounds down to zero
    /// @dev Prevents an opaque arithmetic panic on dust-sized inputs; the
    ///      conservative `-1` rounding is guarded so dust reverts cleanly.
    error InsufficientOutput();

    /// @notice Thrown when the post-state invariant falls below the target
    /// @dev Replaces a prior `assert()` so failure burns only the remaining
    ///      gas for this call rather than all gas (L-2).
    error InvariantViolation();

    /// @notice Thrown when the computed output exceeds the available reserve
    /// @dev Defense-in-depth guard against opaque arithmetic panics (L-3).
    error InsufficientLiquidity();

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Reverts if the pool is paused
     */
    modifier whenNotPaused() {
        if (paused) revert PoolPaused();
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploy a 2-coin StableSwap pool
     * @dev The deployer is granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE directly
     *      (Pioneer-Phase deployer-direct control; no timelock). Per-coin rate
     *      multipliers are derived from each token's decimals so the invariant
     *      math runs in a common 18-decimal space.
     * @param coin0_ First coin address
     * @param coin1_ Second coin address
     * @param feeVault_ UnifiedFeeVault address for the non-LP fee share
     * @param amp_ Initial amplification coefficient A (un-precision-scaled)
     * @param tradingFeeBps_ Initial trading fee in basis points (<= MAX_FEE_BPS)
     * @param admin_ Address granted admin roles (the deployer EOA)
     * @param lpName ERC-20 name for the LP share token
     * @param lpSymbol ERC-20 symbol for the LP share token
     */
    constructor(
        address coin0_,
        address coin1_,
        address feeVault_,
        uint256 amp_,
        uint256 tradingFeeBps_,
        address admin_,
        string memory lpName,
        string memory lpSymbol
    ) ERC20(lpName, lpSymbol) {
        if (
            coin0_ == address(0)
            || coin1_ == address(0)
            || feeVault_ == address(0)
            || admin_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (coin0_ == coin1_) revert IdenticalCoins();
        if (amp_ < MIN_A || amp_ > MAX_A) revert InvalidA(amp_);
        if (tradingFeeBps_ > MAX_FEE_BPS) revert FeeTooHigh(tradingFeeBps_);
        if (tradingFeeBps_ < MIN_FEE_BPS) revert FeeTooLow(tradingFeeBps_);

        COIN0 = IERC20(coin0_);
        COIN1 = IERC20(coin1_);
        FEE_VAULT = feeVault_;

        RATE0 = _rateFor(coin0_);
        RATE1 = _rateFor(coin1_);

        uint256 scaledA = amp_ * A_PRECISION;
        initialA = scaledA;
        futureA = scaledA;
        // solhint-disable-next-line not-rely-on-time
        initialATime = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        futureATime = block.timestamp;

        tradingFeeBps = tradingFeeBps_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ========================================================================
    // EXTERNAL STATE-CHANGING FUNCTIONS
    // ========================================================================

    /**
     * @notice Add liquidity to the pool
     * @dev On the first deposit, LP minted equals the invariant D (in
     *      normalized units) minus {MINIMUM_LIQUIDITY}, which is locked to the
     *      dead address; the first deposit is fee-FREE and must supply BOTH
     *      coins (a peg cannot be defined from a single coin).
     *
     *      On later deposits an imbalance fee is charged exactly as in
     *      canonical Curve `add_liquidity`: the deposit's deviation from a
     *      perfectly balanced add is fee'd so that a one-sided add followed by
     *      a single-coin withdrawal cannot undercut a direct {exchange}. The
     *      per-coin fee rate is `tradingFeeBps * N_COINS / (4 * (N_COINS - 1))`
     *      (Curve's formula; equals `tradingFeeBps / 2` for N_COINS = 2), split
     *      70/30 like the swap fee: the 70% LP portion stays in the pool
     *      (reducing the credited balance used to compute minted LP and raising
     *      the per-share value for existing LPs) and the 30% protocol portion
     *      is transferred to {FEE_VAULT} in the affected coin. A balanced
     *      deposit (matching the pool ratio) incurs no fee. LP minted is then
     *      proportional to the fee-adjusted invariant increase:
     *      `mintedLp = totalSupply * (D2 - D0) / D0`. Deposits may be one-sided
     *      (one amount zero) after seeding, but never both zero.
     * @param amount0 Amount of COIN0 to deposit (native units)
     * @param amount1 Amount of COIN1 to deposit (native units)
     * @param minMintAmount Minimum acceptable LP minted (slippage protection)
     * @return minted LP tokens minted to the caller
     */
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minMintAmount
    ) external nonReentrant whenNotPaused returns (uint256 minted) {
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        uint256 oldReserve0 = reserve0;
        uint256 oldReserve1 = reserve1;

        // The first deposit defines the peg, so both coins are required.
        // Without this guard the invariant solve below would divide by a
        // zero balance and revert with an opaque arithmetic panic.
        if (totalSupply() == 0 && (amount0 == 0 || amount1 == 0)) {
            revert FirstDepositNeedsBothCoins();
        }

        // Interactions first (guarded by nonReentrant): pull the deposits and
        // fail-closed on fee-on-transfer tokens so internal reserve accounting
        // never overstates the real on-chain balance (M-3).
        _pullDeposits(amount0, amount1);

        // Compute minted LP, the fee-adjusted reserves, and the vault fees.
        uint256[N_COINS] memory vaultFees;
        (minted, vaultFees) = _computeAddLiquidity(
            oldReserve0, oldReserve1, amount0, amount1
        );

        if (minted < minMintAmount) {
            revert SlippageExceeded(minMintAmount, minted);
        }

        // Effects: credit reserves by the deposit net of the 30% protocol fee
        // (the 70% LP fee stays in reserves as accrued yield), then mint LP.
        reserve0 = oldReserve0 + amount0 - vaultFees[0];
        reserve1 = oldReserve1 + amount1 - vaultFees[1];

        _mint(_msgSender(), minted);

        // Forward the 30% protocol fee share to the vault in each coin.
        _settleVaultFees(vaultFees);

        emit AddLiquidity(_msgSender(), amount0, amount1, minted);
    }

    /**
     * @notice Remove liquidity in a balanced split of both coins
     * @dev Returns each coin pro-rata to the burned LP share. This path has
     *      no slippage and is always available even while paused is false; it
     *      intentionally performs no invariant solve. Withdrawals are never
     *      blocked by pause so users can always exit.
     * @param lpAmount LP tokens to burn
     * @param minAmount0 Minimum COIN0 to receive (slippage protection)
     * @param minAmount1 Minimum COIN1 to receive (slippage protection)
     * @return amount0 COIN0 returned to the caller
     * @return amount1 COIN1 returned to the caller
     */
    function removeLiquidity(
        uint256 lpAmount,
        uint256 minAmount0,
        uint256 minAmount1
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (lpAmount == 0) revert ZeroAmount();
        uint256 balance = balanceOf(_msgSender());
        if (lpAmount > balance) {
            revert InsufficientLPBalance(lpAmount, balance);
        }

        uint256 supply = totalSupply();
        uint256 oldReserve0 = reserve0;
        uint256 oldReserve1 = reserve1;

        amount0 = (oldReserve0 * lpAmount) / supply;
        amount1 = (oldReserve1 * lpAmount) / supply;

        if (amount0 < minAmount0) revert SlippageExceeded(minAmount0, amount0);
        if (amount1 < minAmount1) revert SlippageExceeded(minAmount1, amount1);

        // Effects before interactions.
        reserve0 = oldReserve0 - amount0;
        reserve1 = oldReserve1 - amount1;
        _burn(_msgSender(), lpAmount);

        if (amount0 > 0) COIN0.safeTransfer(_msgSender(), amount0);
        if (amount1 > 0) COIN1.safeTransfer(_msgSender(), amount1);

        emit RemoveLiquidity(_msgSender(), amount0, amount1, lpAmount);
    }

    /**
     * @notice Remove liquidity entirely in a single coin
     * @dev Solves the invariant for the post-withdrawal balance of the chosen
     *      coin. A Curve imbalance fee (charged only on each coin's deviation
     *      from a balanced withdrawal, not on the whole output) is applied so
     *      single-coin exits do not let LPs dodge the swap fee that a balanced
     *      exit + swap would have incurred. The LP share (70%) of that fee is
     *      retained by leaving it in the reserves: reserve i is reduced only by
     *      `dy + vaultFee`, so the LP portion stays in the pool and raises the
     *      per-share value for the remaining LPs (it is NOT retained inside the
     *      invariant solve). The remaining 30% (`vaultFee`) is sent to the
     *      vault. After the burn the post-state invariant is asserted to be at
     *      least the reduced target D1 (defense-in-depth, L-2). Like
     *      {removeLiquidity}, this is allowed while unpaused.
     * @param lpAmount LP tokens to burn
     * @param i Index of the coin to receive (0 or 1)
     * @param minAmount Minimum amount of coin i to receive
     * @return amount Amount of coin i returned to the caller
     */
    function removeLiquidityOneCoin(
        uint256 lpAmount,
        uint256 i,
        uint256 minAmount
    ) external nonReentrant returns (uint256 amount) {
        if (lpAmount == 0) revert ZeroAmount();
        // solhint-disable-next-line gas-strict-inequalities
        if (i >= N_COINS) revert InvalidCoinIndex(i, i);
        uint256 balance = balanceOf(_msgSender());
        if (lpAmount > balance) {
            revert InsufficientLPBalance(lpAmount, balance);
        }

        uint256 amp = _getA();
        uint256 d0 = _invariant(_xp(reserve0, reserve1), amp);
        uint256 d1 = d0 - (lpAmount * d0) / totalSupply();

        (uint256 dy, uint256 vaultFee) = _calcWithdrawOneCoin(lpAmount, i);
        if (dy < minAmount) revert SlippageExceeded(minAmount, dy);

        // Effects before interactions: reduce reserves by (dy + vaultFee). The
        // LP-share of the fee is retained by leaving it in reserves (reserves
        // drop by less than the fee-free output); only the vault share leaves.
        _decreaseReserve(i, dy + vaultFee);
        // Defense-in-depth (L-2): the post-withdrawal invariant must not fall
        // below the reduced target D1 the burn priced the exit against.
        // solhint-disable-next-line gas-strict-inequalities
        if (_invariant(_xp(reserve0, reserve1), amp) < d1) {
            revert InvariantViolation();
        }
        _burn(_msgSender(), lpAmount);

        IERC20 coin = i == 0 ? COIN0 : COIN1;
        coin.safeTransfer(_msgSender(), dy);
        if (vaultFee > 0) {
            coin.safeTransfer(FEE_VAULT, vaultFee);
        }

        emit RemoveLiquidity(
            _msgSender(),
            i == 0 ? dy : 0,
            i == 0 ? 0 : dy,
            lpAmount
        );

        amount = dy;
    }

    /**
     * @notice Swap `dx` of coin `i` for coin `j`
     * @dev Output is computed from the StableSwap invariant, then the
     *      {tradingFeeBps} fee is deducted from the output. 70% of the fee is
     *      retained in the pool (LP yield); 30% is transferred to the vault.
     *      Fee-on-transfer input tokens are unsupported.
     * @param i Index of the coin being sold (0 or 1)
     * @param j Index of the coin being bought (0 or 1)
     * @param dx Amount of coin i sold (native units)
     * @param minDy Minimum amount of coin j to receive (slippage protection)
     * @return dy Amount of coin j sent to the caller
     */
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy
    ) external nonReentrant whenNotPaused returns (uint256 dy) {
        if (dx == 0) revert ZeroAmount();
        // solhint-disable-next-line gas-strict-inequalities
        if (i >= N_COINS || j >= N_COINS || i == j) {
            revert InvalidCoinIndex(i, j);
        }

        IERC20 coinIn = i == 0 ? COIN0 : COIN1;
        IERC20 coinOut = j == 0 ? COIN0 : COIN1;

        // Interactions first for the input pull (guarded by nonReentrant):
        // fail-closed on fee-on-transfer tokens so reserves credited with the
        // stated `dx` stay consistent with the real on-chain balance (M-3).
        _pullExact(coinIn, dx);

        uint256 totalFee;
        uint256 vaultFee;
        (dy, totalFee, vaultFee) = _computeExchange(i, j, dx);

        if (dy < minDy) revert SlippageExceeded(minDy, dy);

        // Defense-in-depth (L-3): dy + vaultFee must not exceed the output
        // reserve, preventing an opaque arithmetic panic on underflow.
        uint256 reserveOut = j == 0 ? reserve0 : reserve1;
        if (dy + vaultFee > reserveOut) revert InsufficientLiquidity();

        // Effects: the input is fully added to reserves; the output plus the
        // vault-bound fee leave the reserves. The LP fee share remains inside
        // reserves as accrued yield.
        if (i == 0) {
            reserve0 += dx;
            reserve1 -= (dy + vaultFee);
        } else {
            reserve1 += dx;
            reserve0 -= (dy + vaultFee);
        }

        coinOut.safeTransfer(_msgSender(), dy);
        if (vaultFee > 0) {
            coinOut.safeTransfer(FEE_VAULT, vaultFee);
        }

        emit TokenExchange(_msgSender(), i, dx, j, dy, totalFee);
    }

    // ========================================================================
    // ADMIN FUNCTIONS (DEPLOYER-DIRECT, NO DELAY)
    // ========================================================================

    /**
     * @notice Set the trading fee
     * @dev Deployer-direct: applies immediately, no timelock (Pioneer Phase).
     * @param newFeeBps New fee in basis points (<= MAX_FEE_BPS)
     */
    function setTradingFee(
        uint256 newFeeBps
    ) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        if (newFeeBps < MIN_FEE_BPS) revert FeeTooLow(newFeeBps);
        uint256 oldFee = tradingFeeBps;
        tradingFeeBps = newFeeBps;
        emit TradingFeeUpdated(oldFee, newFeeBps);
    }

    /**
     * @notice Schedule a gradual ramp of the amplification coefficient A
     * @dev Ramps are linear in time between the current A and `futureAValue`,
     *      bounded to a 10x change and a minimum 1-day duration to resist
     *      manipulation. This is the only time-extended mechanism in the
     *      contract and is a standard Curve safety feature, not a Pioneer
     *      admin delay: the admin may also {stopRampA} at any moment.
     * @param futureAValue Target A (un-precision-scaled)
     * @param futureTime Timestamp the ramp should complete
     */
    function rampA(
        uint256 futureAValue,
        uint256 futureTime
    ) external onlyRole(ADMIN_ROLE) {
        if (futureAValue < MIN_A || futureAValue > MAX_A) {
            revert InvalidA(futureAValue);
        }
        // solhint-disable-next-line not-rely-on-time
        if (futureTime < block.timestamp + MIN_RAMP_TIME) {
            revert ARampTooFast();
        }

        uint256 currentA = _getA();
        uint256 scaledFutureA = futureAValue * A_PRECISION;

        // Bound the change to MAX_A_CHANGE in either direction.
        if (scaledFutureA > currentA) {
            if (scaledFutureA > currentA * MAX_A_CHANGE) {
                revert ARampTooLarge();
            }
        } else {
            if (scaledFutureA * MAX_A_CHANGE < currentA) {
                revert ARampTooLarge();
            }
        }

        initialA = currentA;
        futureA = scaledFutureA;
        // solhint-disable-next-line not-rely-on-time
        initialATime = block.timestamp;
        futureATime = futureTime;

        emit RampA(currentA, scaledFutureA, initialATime, futureTime);
    }

    /**
     * @notice Stop an in-progress A ramp, freezing A at its current value
     * @dev Deployer-direct, immediate.
     */
    function stopRampA() external onlyRole(ADMIN_ROLE) {
        uint256 currentA = _getA();
        initialA = currentA;
        futureA = currentA;
        // solhint-disable-next-line not-rely-on-time
        initialATime = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        futureATime = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        emit StopRampA(currentA, block.timestamp);
    }

    /**
     * @notice Pause or unpause the pool
     * @dev Pausing blocks swaps and deposits; withdrawals always remain open.
     *      Deployer-direct, immediate.
     * @param paused_ True to pause, false to unpause
     */
    function setPaused(bool paused_) external onlyRole(ADMIN_ROLE) {
        paused = paused_;
        emit PauseStateChanged(paused_);
    }

    // ========================================================================
    // EXTERNAL VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Quote the output of a swap including the trading fee
     * @dev Pure read; matches {exchange} output exactly for the same state.
     * @param i Index of the coin being sold (0 or 1)
     * @param j Index of the coin being bought (0 or 1)
     * @param dx Amount of coin i sold (native units)
     * @return dy Amount of coin j the caller would receive
     */
    function getDy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256 dy) {
        // solhint-disable-next-line gas-strict-inequalities
        if (i >= N_COINS || j >= N_COINS || i == j) {
            revert InvalidCoinIndex(i, j);
        }
        if (dx == 0) revert ZeroAmount();
        (dy, , ) = _computeExchange(i, j, dx);
    }

    /**
     * @notice Current effective amplification coefficient A (precision-scaled)
     * @dev Returns A * A_PRECISION, interpolated if a ramp is in progress.
     * @return a The current A scaled by {A_PRECISION}
     */
    function getA() external view returns (uint256 a) {
        a = _getA();
    }

    /**
     * @notice Current pool invariant D (normalized 18-decimal units)
     * @return d The invariant for the current reserves and A
     */
    function getInvariant() external view returns (uint256 d) {
        d = _invariant(_xp(reserve0, reserve1), _getA());
    }

    /**
     * @notice Preview a single-coin withdrawal
     * @param lpAmount LP tokens to burn
     * @param i Index of the coin to receive (0 or 1)
     * @return amount Amount of coin i the caller would receive (net of fee)
     */
    function calcWithdrawOneCoin(
        uint256 lpAmount,
        uint256 i
    ) external view returns (uint256 amount) {
        // solhint-disable-next-line gas-strict-inequalities
        if (i >= N_COINS) revert InvalidCoinIndex(i, i);
        (amount, ) = _calcWithdrawOneCoin(lpAmount, i);
    }

    // ========================================================================
    // INTERNAL VIEW: SWAP / FEE COMPUTATION
    // ========================================================================

    /**
     * @notice Compute the gross output, total fee, and vault fee for a swap
     * @dev Gross output is `xp_out_before - xp_out_after`, de-normalized to
     *      native units of coin j. The fee is taken on the gross output.
     * @param i Index of the coin being sold (0 or 1)
     * @param j Index of the coin being bought (0 or 1)
     * @param dx Amount of coin i sold (native units)
     * @return dy Net output (gross minus total fee), native units of coin j
     * @return totalFee Total fee charged, native units of coin j
     * @return vaultFee Portion of the fee sent to the vault (30%)
     */
    function _computeExchange(
        uint256 i,
        uint256 j,
        uint256 dx
    )
        internal
        view
        returns (uint256 dy, uint256 totalFee, uint256 vaultFee)
    {
        uint256 amp = _getA();
        uint256 rateIn = i == 0 ? RATE0 : RATE1;
        uint256 rateOut = j == 0 ? RATE0 : RATE1;

        uint256[N_COINS] memory xp = _xp(reserve0, reserve1);

        // New normalized balance of the input coin after adding dx.
        uint256 xAfter = xp[i] + dx * rateIn;

        // Solve invariant for the new normalized balance of the output coin.
        uint256 yAfter = _getY(i, j, xAfter, xp, amp);

        // Gross output in normalized units (subtract 1 to round in the
        // pool's favor, matching Curve's conservative rounding). Guard the
        // subtraction so dust inputs that round to zero revert cleanly with
        // {InsufficientOutput} instead of an opaque arithmetic panic (L-1).
        uint256 rawDiff = xp[j] - yAfter;
        uint256 dyNormalized = rawDiff > 1 ? rawDiff - 1 : 0;

        // De-normalize to native output-coin units.
        uint256 grossDy = dyNormalized / rateOut;
        if (grossDy == 0) revert InsufficientOutput();

        totalFee = (grossDy * tradingFeeBps) / BPS_DENOMINATOR;
        dy = grossDy - totalFee;
        vaultFee = totalFee - (totalFee * FEE_LP_BPS) / BPS_DENOMINATOR;
    }

    /**
     * @notice Compute a single-coin withdrawal output and its vault fee
     * @dev Implements canonical Curve `_calc_withdraw_one_coin`. Burning
     *      `lpAmount` conceptually reduces the invariant from D0 to
     *      `D1 = D0 - lpAmount * D0 / totalSupply`. The fee-FREE balance of
     *      coin i at D1 is `newY = getYD(D1, i)`. Curve then charges an
     *      imbalance fee only on each coin's deviation from a balanced
     *      withdrawal, using the dynamic per-coin rate
     *      `tradingFeeBps * N_COINS / (4 * (N_COINS - 1))`:
     *        - withdrawn coin i: `dxExpected = reserve_i * D1 / D0 - newY`
     *        - other coin j:     `dxExpected = reserve_j - reserve_j * D1 / D0`
     *      and each `xpReduced[k] = xp[k] - feeBps * dxExpected_k`. The net
     *      output is `dy = xpReduced[i] - getYD(D1, i, xpReduced) - 1` (the -1
     *      rounds in the pool's favor and is guarded against underflow per
     *      L-1). The actual fee charged is the fee-free amount minus `dy`,
     *      split 70% retained in reserves (raising per-share value for the
     *      remaining LPs) / 30% to the vault. A near-balanced single-coin
     *      withdrawal therefore costs only the small imbalance fee, not a fee
     *      on the entire output.
     * @param lpAmount LP tokens to burn
     * @param i Index of the coin to receive (0 or 1)
     * @return dy Net amount of coin i to send the caller (native units)
     * @return vaultFee Portion of the fee bound for the vault (native units)
     */
    function _calcWithdrawOneCoin(
        uint256 lpAmount,
        uint256 i
    ) internal view returns (uint256 dy, uint256 vaultFee) {
        uint256 amp = _getA();
        uint256 rateI = i == 0 ? RATE0 : RATE1;

        uint256[N_COINS] memory xp = _xp(reserve0, reserve1);
        uint256 d0 = _invariant(xp, amp);

        uint256 supply = totalSupply();
        uint256 d1 = d0 - (lpAmount * d0) / supply;

        // Fee-free balance of coin i at the reduced invariant D1.
        uint256 newY = _getYD(amp, i, xp, d1);

        // Per-coin dynamic imbalance fee rate (same formula as add_liquidity).
        uint256 feeBps =
            (tradingFeeBps * N_COINS) / (4 * (N_COINS - 1));

        // Reduce each coin's normalized balance by the fee on its deviation
        // from a balanced withdrawal, then re-solve coin i at D1.
        uint256[N_COINS] memory xpReduced = _reducedXp(
            xp, i, newY, d0, d1, feeBps
        );
        uint256 yReduced = _getYD(amp, i, xpReduced, d1);

        // Net (post-fee) withdrawal in normalized units; guard the -1 (L-1).
        uint256 rawNet = xpReduced[i] - yReduced;
        uint256 dyNormalized = rawNet > 1 ? rawNet - 1 : 0;
        dy = dyNormalized / rateI;
        if (dy == 0) revert InsufficientOutput();

        // Fee-free output (also -1 rounded) and the actual fee charged.
        uint256 grossNormalized = (xp[i] - newY) > 1 ? (xp[i] - newY) - 1 : 0;
        uint256 grossDy = grossNormalized / rateI;
        uint256 totalFee = grossDy > dy ? grossDy - dy : 0;
        vaultFee = totalFee - (totalFee * FEE_LP_BPS) / BPS_DENOMINATOR;
    }

    // ========================================================================
    // INTERNAL VIEW HELPERS (AMPLIFICATION, NORMALIZATION, DECIMALS)
    // ========================================================================

    /**
     * @notice Current A scaled by {A_PRECISION}, interpolated during a ramp
     * @dev Linear interpolation between {initialA} and {futureA} over the
     *      ramp window. Outside the window, returns the endpoint value.
     * @return a Current A * {A_PRECISION}
     */
    function _getA() internal view returns (uint256 a) {
        uint256 t1 = futureATime;
        uint256 a1 = futureA;

        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= t1) {
            return a1;
        }

        uint256 a0 = initialA;
        uint256 t0 = initialATime;
        // solhint-disable-next-line not-rely-on-time
        uint256 elapsed = block.timestamp - t0;
        uint256 span = t1 - t0;

        if (a1 > a0) {
            a = a0 + ((a1 - a0) * elapsed) / span;
        } else {
            a = a0 - ((a0 - a1) * elapsed) / span;
        }
    }

    /**
     * @notice Normalize native reserves into 18-decimal "xp" balances
     * @param r0 COIN0 reserve in native units
     * @param r1 COIN1 reserve in native units
     * @return xp Normalized balances [coin0, coin1]
     */
    function _xp(
        uint256 r0,
        uint256 r1
    ) internal view returns (uint256[N_COINS] memory xp) {
        xp[0] = r0 * RATE0;
        xp[1] = r1 * RATE1;
    }

    /**
     * @notice Derive the 18-decimal rate multiplier for a token
     * @dev rate = 10 ** (18 - decimals). Reverts for tokens with > 18
     *      decimals, which the normalized math does not support.
     * @param token Token address to inspect
     * @return rate The native-to-18-decimal multiplier
     */
    function _rateFor(address token) internal view returns (uint256 rate) {
        uint8 dec = IERC20Metadata(token).decimals();
        if (dec > 18) revert UnsupportedDecimals(dec);
        rate = 10 ** (18 - uint256(dec));
    }

    // ========================================================================
    // INTERNAL PURE: STABLESWAP MATH
    // ========================================================================

    /**
     * @notice Solve the StableSwap invariant D via Newton's method
     * @dev For n = 2 the iteration is:
     *
     *        D_{k+1} = (Ann * S + n * D_P) * D_k
     *                  / ((Ann - 1) * D_k + (n + 1) * D_P)
     *
     *      where S = sum(xp), Ann = A * n^n (precision-adjusted), and
     *      D_P = D^(n+1) / (n^n * prod(xp)). Converges when |D_{k+1} - D_k|
     *      <= 1. Bounded to {MAX_ITERATIONS}; reverts on non-convergence.
     * @param xp Normalized balances
     * @param amp Amplification coefficient A * {A_PRECISION}
     * @return d The invariant D, or 0 if the pool is empty
     */
    function _invariant(
        uint256[N_COINS] memory xp,
        uint256 amp
    ) internal pure returns (uint256 d) {
        uint256 s = xp[0] + xp[1];
        if (s == 0) {
            return 0;
        }

        d = s;
        // Ann = A * n^n, with A already scaled by A_PRECISION.
        uint256 ann = amp * N_COINS;

        for (uint256 k = 0; k < MAX_ITERATIONS; ++k) {
            // D_P = D^(n+1) / (n^n * prod(xp)); unrolled for n = 2.
            uint256 dP = d;
            dP = (dP * d) / (xp[0] * N_COINS);
            dP = (dP * d) / (xp[1] * N_COINS);

            uint256 dPrev = d;
            uint256 numerator =
                ((ann * s) / A_PRECISION + dP * N_COINS) * d;
            uint256 denominator =
                ((ann - A_PRECISION) * d) / A_PRECISION
                + (N_COINS + 1) * dP;
            d = numerator / denominator;

            if (_within1(d, dPrev)) {
                return d;
            }
        }

        revert DidNotConverge();
    }

    /**
     * @notice Solve for the new balance of coin `j` given a new balance of `i`
     * @dev Newton's method on the single-variable reduction of the invariant:
     *
     *        y_{k+1} = (y_k^2 + c) / (2 * y_k + b - D)
     *
     *      with b = S' + D * A_PRECISION / Ann, c = D^(n+1) /
     *      (n^n * Ann/A_PRECISION * prod_{m != j} x_m), and S' = sum of all
     *      balances except j (here just x_i). Bounded to {MAX_ITERATIONS}.
     * @param i Index of the changed (input) coin
     * @param j Index of the coin to solve for (output)
     * @param x New normalized balance of coin i
     * @param xp Pre-trade normalized balances
     * @param amp Amplification coefficient A * {A_PRECISION}
     * @return y New normalized balance of coin j
     */
    function _getY(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[N_COINS] memory xp,
        uint256 amp
    ) internal pure returns (uint256 y) {
        // i and j validated by callers; for n = 2 they are simply {0,1}.
        uint256 d = _invariant(xp, amp);
        uint256 ann = amp * N_COINS;

        // For n = 2, the only "other" coin balance is x (coin i's new value).
        uint256 c = d;
        c = (c * d) / (x * N_COINS);
        // c = D^(n+1) / (n^n * prod_other * Ann / A_PRECISION)
        c = (c * d * A_PRECISION) / (ann * N_COINS);

        uint256 b = x + (d * A_PRECISION) / ann;

        y = d;
        for (uint256 k = 0; k < MAX_ITERATIONS; ++k) {
            uint256 yPrev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (_within1(y, yPrev)) {
                return y;
            }
        }

        // Silence unused-variable warnings without affecting math: i and j
        // are part of the public contract and validated upstream.
        i;
        j;
        revert DidNotConverge();
    }

    /**
     * @notice Solve for the balance of coin `i` that yields invariant `d`
     * @dev Used by single-coin withdrawal. Same Newton iteration as {_getY}
     *      but the target D is supplied directly (the reduced invariant after
     *      a partial burn), and we solve for coin i holding the other coin's
     *      balance fixed. Bounded to {MAX_ITERATIONS}.
     * @param amp Amplification coefficient A * {A_PRECISION}
     * @param i Index of the coin to solve for
     * @param xp Current normalized balances
     * @param d Target invariant D
     * @return y New normalized balance of coin i
     */
    function _getYD(
        uint256 amp,
        uint256 i,
        uint256[N_COINS] memory xp,
        uint256 d
    ) internal pure returns (uint256 y) {
        uint256 ann = amp * N_COINS;

        // The fixed (other) coin is the one that is NOT i.
        uint256 other = i == 0 ? xp[1] : xp[0];

        uint256 c = d;
        c = (c * d) / (other * N_COINS);
        c = (c * d * A_PRECISION) / (ann * N_COINS);

        uint256 b = other + (d * A_PRECISION) / ann;

        y = d;
        for (uint256 k = 0; k < MAX_ITERATIONS; ++k) {
            uint256 yPrev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (_within1(y, yPrev)) {
                return y;
            }
        }

        revert DidNotConverge();
    }

    /**
     * @notice True if two values differ by at most 1 (Newton convergence)
     * @param a First value
     * @param b Second value
     * @return True if |a - b| <= 1
     */
    function _within1(uint256 a, uint256 b) internal pure returns (bool) {
        // solhint-disable-next-line gas-strict-inequalities
        return a > b ? (a - b <= 1) : (b - a <= 1);
    }

    /**
     * @notice Build the fee-reduced normalized balances for a single-coin exit
     * @dev Subtracts the Curve imbalance fee from each coin's normalized
     *      balance: the withdrawn coin i is fee'd on `reserve_i*D1/D0 - newY`,
     *      the other coin on `reserve_j - reserve_j*D1/D0`. Extracted to keep
     *      {_calcWithdrawOneCoin} below the cyclomatic-complexity limit.
     * @param xp Pre-withdrawal normalized balances
     * @param i Index of the withdrawn coin
     * @param newY Fee-free normalized balance of coin i at D1
     * @param d0 Invariant before the burn
     * @param d1 Invariant after the burn
     * @param feeBps Dynamic per-coin fee rate in basis points
     * @return xpReduced Fee-reduced normalized balances [coin0, coin1]
     */
    function _reducedXp(
        uint256[N_COINS] memory xp,
        uint256 i,
        uint256 newY,
        uint256 d0,
        uint256 d1,
        uint256 feeBps
    ) internal pure returns (uint256[N_COINS] memory xpReduced) {
        for (uint256 k = 0; k < N_COINS; ++k) {
            uint256 idealK = (xp[k] * d1) / d0;
            uint256 dxExpected;
            if (k == i) {
                // Withdrawn coin: deviation of the ideal balance above newY.
                dxExpected = idealK > newY ? idealK - newY : 0;
            } else {
                // Untouched coin: deviation of its balance below its ideal.
                dxExpected = xp[k] > idealK ? xp[k] - idealK : 0;
            }
            xpReduced[k] = xp[k] - (feeBps * dxExpected) / BPS_DENOMINATOR;
        }
    }

    // ========================================================================
    // PRIVATE STATE-CHANGING HELPERS
    // ========================================================================

    /**
     * @notice Decrease the stored reserve of one coin
     * @dev Extracted to keep {removeLiquidityOneCoin} below the cyclomatic
     *      complexity limit. Reverts on underflow via checked arithmetic.
     * @param i Index of the coin whose reserve to decrease (0 or 1)
     * @param delta Amount to subtract (native units)
     */
    function _decreaseReserve(uint256 i, uint256 delta) private {
        if (i == 0) {
            reserve0 -= delta;
        } else {
            reserve1 -= delta;
        }
    }

    /**
     * @notice Pull `amount` of `token` from the caller, rejecting FoT tokens
     * @dev Measures the contract's balance before and after the transfer and
     *      reverts {FeeOnTransferNotSupported} if fewer than `amount` tokens
     *      were actually received. This fail-closed guard keeps the pool's
     *      internal reserve accounting (which credits the stated `amount`)
     *      consistent with the real on-chain balance (audit M-3).
     * @param token Token to pull from the caller
     * @param amount Exact amount that must arrive (native units)
     */
    function _pullExact(IERC20 token, uint256 amount) private {
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(_msgSender(), address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balBefore;
        if (received != amount) revert FeeOnTransferNotSupported();
    }

    /**
     * @notice Pull both deposit legs from the caller (FoT-guarded)
     * @dev Extracted from {addLiquidity} to keep it under the cyclomatic
     *      complexity limit. Skips a leg whose amount is zero.
     * @param amount0 COIN0 to pull (native units)
     * @param amount1 COIN1 to pull (native units)
     */
    function _pullDeposits(uint256 amount0, uint256 amount1) private {
        if (amount0 > 0) _pullExact(COIN0, amount0);
        if (amount1 > 0) _pullExact(COIN1, amount1);
    }

    /**
     * @notice Forward the per-coin 30% protocol fee to the vault
     * @dev Extracted from {addLiquidity} to keep it under the cyclomatic
     *      complexity limit. Skips a coin whose vault fee is zero.
     * @param vaultFees Per-coin vault fee in native units [coin0, coin1]
     */
    function _settleVaultFees(uint256[N_COINS] memory vaultFees) private {
        if (vaultFees[0] > 0) COIN0.safeTransfer(FEE_VAULT, vaultFees[0]);
        if (vaultFees[1] > 0) COIN1.safeTransfer(FEE_VAULT, vaultFees[1]);
    }

    /**
     * @notice Compute minted LP and per-coin vault fees for a deposit
     * @dev Implements canonical Curve `add_liquidity`. On the first deposit
     *      (supply == 0) the deposit is fee-free, LP equals D minus the locked
     *      {MINIMUM_LIQUIDITY} (minted to the dead address), and both vault
     *      fees are zero. On later deposits the per-coin imbalance fee uses the
     *      dynamic rate `tradingFeeBps * N_COINS / (4 * (N_COINS - 1))`; 70% of
     *      each coin's fee stays in the pool (so the post-fee credited balances
     *      feed D2 and minting, raising per-share value) and 30% is returned as
     *      `vaultFees` for transfer to {FEE_VAULT}. A perfectly balanced add
     *      yields zero fee on both coins.
     * @param oldReserve0 COIN0 reserve before the deposit (native units)
     * @param oldReserve1 COIN1 reserve before the deposit (native units)
     * @param amount0 COIN0 deposited (native units)
     * @param amount1 COIN1 deposited (native units)
     * @return minted LP tokens to mint to the depositor
     * @return vaultFees Per-coin 30% protocol fee in native units [coin0, coin1]
     */
    function _computeAddLiquidity(
        uint256 oldReserve0,
        uint256 oldReserve1,
        uint256 amount0,
        uint256 amount1
    )
        private
        returns (uint256 minted, uint256[N_COINS] memory vaultFees)
    {
        uint256 amp = _getA();
        uint256 supply = totalSupply();

        uint256 d0 = _invariant(_xp(oldReserve0, oldReserve1), amp);
        uint256 d1 = _invariant(
            _xp(oldReserve0 + amount0, oldReserve1 + amount1), amp
        );

        if (supply == 0) {
            // First deposit: fee-free; LP equals D1 minus the locked minimum.
            // solhint-disable-next-line gas-strict-inequalities
            if (d1 <= MINIMUM_LIQUIDITY) revert InitialDepositTooSmall(d1);
            minted = d1 - MINIMUM_LIQUIDITY;
            _mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
            return (minted, vaultFees);
        }

        // Per-coin dynamic imbalance fee rate (Curve's formula).
        uint256 feeBps =
            (tradingFeeBps * N_COINS) / (4 * (N_COINS - 1));

        // Credited (fee-adjusted) reserves used for D2 and minting: subtract
        // the FULL per-coin fee from each balance, exactly as Curve does. The
        // 30% vault portion is also reported back for the on-chain transfer.
        uint256 credited0 =
            _applyAddFee(oldReserve0, amount0, d0, d1, feeBps);
        uint256 credited1 =
            _applyAddFee(oldReserve1, amount1, d0, d1, feeBps);

        // Vault fee = 30% of the full per-coin fee, in native units. The full
        // fee is `(old + amount) - credited`; the vault share is its 30%.
        vaultFees[0] = (((oldReserve0 + amount0) - credited0)
            * (BPS_DENOMINATOR - FEE_LP_BPS)) / BPS_DENOMINATOR;
        vaultFees[1] = (((oldReserve1 + amount1) - credited1)
            * (BPS_DENOMINATOR - FEE_LP_BPS)) / BPS_DENOMINATOR;

        // D2 from the fully-fee-adjusted balances; minted LP is proportional
        // to the post-fee invariant increase.
        uint256 d2 = _invariant(_xp(credited0, credited1), amp);
        minted = (supply * (d2 - d0)) / d0;
    }

    /**
     * @notice Apply the Curve per-coin imbalance fee to one coin's balance
     * @dev Returns the fee-adjusted (credited) native balance for a coin:
     *      `new_balance - feeBps * |new_balance - ideal| / BPS_DENOMINATOR`,
     *      where `ideal = D1 * old_balance / D0` is the balanced-deposit
     *      target. The subtraction is done in native units; the invariant
     *      consumes it via {_xp}. A balanced deposit makes the difference zero.
     * @param oldBalance Coin reserve before the deposit (native units)
     * @param amount Coin deposited (native units)
     * @param d0 Invariant before the deposit
     * @param d1 Invariant after the (pre-fee) deposit
     * @param feeBps Dynamic per-coin fee rate in basis points
     * @return credited Fee-adjusted native balance for this coin
     */
    function _applyAddFee(
        uint256 oldBalance,
        uint256 amount,
        uint256 d0,
        uint256 d1,
        uint256 feeBps
    ) private pure returns (uint256 credited) {
        uint256 newBalance = oldBalance + amount;
        uint256 ideal = (d1 * oldBalance) / d0;
        uint256 diff =
            newBalance > ideal ? newBalance - ideal : ideal - newBalance;
        uint256 fee = (feeBps * diff) / BPS_DENOMINATOR;
        credited = newBalance - fee;
    }
}
