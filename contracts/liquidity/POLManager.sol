// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOmniSwapRouter} from "../interfaces/IOmniSwapRouter.sol";
import {IRWAAMM} from "../rwa/interfaces/IRWAAMM.sol";
import {IRWAPool} from "../rwa/interfaces/IRWAPool.sol";

// ════════════════════════════════════════════════════════════════════════
//                       External Interfaces (local)
// ════════════════════════════════════════════════════════════════════════

/**
 * @title IOmniTreasuryV2POL
 * @author OmniCoin Development Team
 * @notice Minimal interface to the POL-scoped surface of `OmniTreasuryV2`.
 * @dev `POLManager` holds `POL_DEPLOYER_ROLE` on the treasury and uses
 *      ONLY these two functions to pull treasury funds. It deliberately
 *      does not reference `transferToken`, `execute`, or any other broad
 *      `GOVERNANCE_ROLE` capability — keeping the least-privilege boundary
 *      visible in the type system.
 */
interface IOmniTreasuryV2POL {
    /**
     * @notice Transfer ERC-20 tokens from the treasury into a
     *         whitelisted POL pool target.
     * @param token  The ERC-20 token to transfer.
     * @param target The whitelisted POL pool to receive the tokens.
     * @param amount The amount to transfer.
     */
    function transferTokenToPOL(
        address token,
        address target,
        uint256 amount
    ) external;

    /**
     * @notice Approve a whitelisted POL pool target to spend an ERC-20
     *         token held by the treasury.
     * @param token  The ERC-20 token to approve.
     * @param target The whitelisted POL pool granted the allowance.
     * @param amount The allowance amount.
     */
    function approveTokenForPOL(
        address token,
        address target,
        uint256 amount
    ) external;

    /**
     * @notice Check whether an address is a whitelisted POL target.
     * @dev Used by `POLManager` to assert — at the start of every
     *      fund-moving keeper action — that its own address is a
     *      treasury `polTargets` entry, so `transferTokenToPOL` to it
     *      will not revert (audit M-01).
     * @param target The address to query.
     * @return allowed True if `target` is in the `polTargets` allowlist.
     */
    function isPOLTarget(
        address target
    ) external view returns (bool allowed);
}

// ════════════════════════════════════════════════════════════════════════
//                                POLManager
// ════════════════════════════════════════════════════════════════════════

/**
 * @title POLManager
 * @author OmniCoin Development Team
 * @notice On-chain policy and automation layer for OmniBazaar's
 *         Protocol-Owned Liquidity (POL).
 * @dev Closes Gap 1 and Gap 3 of `the internal POL plan`.
 *
 *      WHAT THIS CONTRACT IS:
 *      A keeper-driven orchestrator that deploys idle `OmniTreasuryV2`
 *      balances into RWAAMM liquidity positions according to an on-chain,
 *      governance-set policy, harvests the LP fees those positions earn,
 *      and reports per-pool accounting that anyone can verify trustlessly.
 *
 *      LEAST-PRIVILEGE TREASURY ACCESS:
 *      `POLManager` holds `POL_DEPLOYER_ROLE` on `OmniTreasuryV2`. That
 *      role can ONLY call `transferTokenToPOL` / `approveTokenForPOL`
 *      against treasury-whitelisted targets. It cannot make arbitrary
 *      transfers or `execute` calls. POLManager therefore cannot drain
 *      the treasury even if a keeper function is exploited — the worst an
 *      attacker can do is move funds into a treasury-whitelisted POL pool,
 *      from which the LP tokens flow straight back to the treasury.
 *
 *      PERMISSION MODEL:
 *
 *      - Keeper triggers — {deploy}, {harvest}, {compound}, {rebalance}.
 *        `KEEPER_ROLE`-gated (audit C-01), NOT permissionless. FIX_POL
 *        originally specified "permissionless triggers", and an earlier
 *        revision implemented them that way; the C-01 remediation
 *        restricted them to `KEEPER_ROLE` because a public-mempool
 *        trigger that swaps treasury funds is an MEV/sandwich surface.
 *        The TWAP-anchored slippage floor is the primary defence; the
 *        `KEEPER_ROLE` allowlist is defence-in-depth that keeps the
 *        triggering transaction off the open mempool. `KEEPER_ROLE` is
 *        granted/revoked by `GOVERNANCE_ROLE` via {setKeeper}. The
 *        on-chain policy (per-pool config, idle thresholds, cadence)
 *        still constrains the outcome regardless of who triggers.
 *        Guarded by `nonReentrant` + `whenNotPaused`.
 *        ({pokeObservation} — the TWAP-observation refresh — IS
 *        permissionless; it moves no funds and is grief-proof.)
 *
 *      - Governance-only policy setters — {setPolicy}, {whitelistToken},
 *        {whitelistPool}, {setTargetWeights}. Restricted to
 *        `GOVERNANCE_ROLE`, which is held by `OmniTimelockController`.
 *        Every policy change therefore inherits the timelock delay.
 *
 *      - Guardian pause — {pause} is `GUARDIAN_ROLE`, held by
 *        `EmergencyGuardian`; {unpause} is `DEFAULT_ADMIN_ROLE`
 *        (the timelock), matching the OmniTreasuryV2 pause/unpause split.
 *
 *      GASLESS KEEPERS:
 *      Inherits `ERC2771Context` so keeper calls can be relayed gaslessly
 *      through the protocol's trusted forwarder, matching OmniBonding and
 *      LiquidityMining. `_msgSender()` is used everywhere a caller
 *      identity matters.
 *
 *      ON-CHAIN ACCOUNTING (FIX_POL Gap 3):
 *      Every managed pool carries a {PoolAccounting} record — deployed
 *      principal per side, LP tokens held, cumulative fees harvested per
 *      side, and last-action timestamps — readable by any dashboard
 *      without trusting an off-chain analytics page.
 *
 *      NON-CUSTODIAL INVARIANT:
 *      POLManager only ever handles protocol-owned funds in transit
 *      (treasury -> AMM -> treasury). It never holds user funds and never
 *      retains a balance between transactions: {deploy} ends with LP
 *      tokens forwarded to the treasury, {harvest} ends with all harvested
 *      assets forwarded to the treasury. Any dust is swept to the treasury
 *      in the same call.
 *
 *      EMERGENCY-UNWIND / PAUSE COUPLING (audit M-07 — accepted behavior):
 *      Every keeper LP withdraw pulls LP tokens from the treasury via
 *      `OmniTreasuryV2.transferTokenToPOL`, which carries `whenNotPaused`.
 *      Therefore, while the treasury is paused, POLManager cannot pull
 *      LP tokens and so cannot unwind a POL position. This coupling is
 *      INTENTIONALLY retained — `transferTokenToPOL` is a treasury
 *      fund-movement function and adding a paused-bypass would weaken an
 *      audited treasury guard for every caller, not just an emergency
 *      unwind. The accepted operational procedure is:
 *        1. POLManager has its OWN independent {pause}; pausing
 *           POLManager does NOT require pausing the treasury. For a
 *           POLManager-side incident, pause POLManager and leave the
 *           treasury live — keeper unwinds still work.
 *        2. If an emergency requires unwinding POL out of a compromised
 *           AMM pool, the unwind ({harvest}/{rebalance}) MUST be run
 *           BEFORE the treasury is paused. If the treasury is already
 *           paused, governance must first `unpause()` the treasury (a
 *           `DEFAULT_ADMIN_ROLE` / timelock action) before the unwind.
 *        3. The RWAAMM has its own independent multi-sig
 *           `emergencyPause` for pool-level incidents; pausing a pool
 *           does not pause the treasury.
 *      No on-chain change is made for M-07; the behavior is documented
 *      and the runbook ordering is the mitigation.
 */
contract POLManager is
    AccessControl,
    ReentrancyGuard,
    Pausable,
    ERC2771Context
{
    using SafeERC20 for IERC20;

    // ─────────────────────── Type Declarations ─────────────────────

    /**
     * @notice Governance-set policy parameters for a single managed
     *         POL pool.
     * @dev Struct packing: `token0` + `targetWeightBps` share slot 0,
     *      `token1` + `enabled` share slot 1, `minIdleToDeploy`,
     *      `rebalanceDriftBps` and `minHarvestInterval` are full slots.
     *      `targetWeightBps` is the pool's intended share of total POL
     *      (in basis points of 10,000); the sum across enabled pools
     *      SHOULD be <= 10,000 but is not enforced on-chain —
     *      {setTargetWeights} validates the batch it is given.
     *
     *      `token0` / `token1` are stored in the EXACT order the
     *      RWAPool itself reports them (`RWAPool.token0()` /
     *      `RWAPool.token1()`), read at {whitelistPool} time — NOT
     *      locally sorted (audit H-03). By the contract's POL
     *      convention `token1` is the paired-stable side that
     *      {deploy} draws idle treasury balance from and that
     *      {_realizedWeightBps} uses as the common numeraire.
     * @param token0 First token of the AMM pair, in the RWAPool's own
     *        ordering.
     * @param targetWeightBps Intended share of total POL in basis
     *        points; used by {rebalance}.
     * @param token1 Second token of the AMM pair, in the RWAPool's own
     *        ordering. The paired-stable side for POL purposes.
     * @param enabled Whether keeper triggers may act on this pool.
     * @param minIdleToDeploy Minimum treasury-idle `token1` balance
     *        required before {deploy} will act, in `token1` base units.
     *        Prevents dust deploys that waste keeper gas.
     * @param rebalanceDriftBps Drift threshold in basis points; if the
     *        pool's realized weight deviates from `targetWeightBps` by
     *        more than this, {rebalance} is permitted to act.
     * @param minHarvestInterval Minimum seconds that must elapse between
     *        consecutive {harvest}/{compound} actions on this pool
     *        (audit C-02 cadence guard). Zero disables the cadence
     *        floor.
     */
    struct PoolPolicy {
        address token0;
        uint96 targetWeightBps;
        address token1;
        bool enabled;
        uint256 minIdleToDeploy;
        uint256 rebalanceDriftBps;
        uint256 minHarvestInterval;
    }

    /**
     * @notice On-chain accounting record for a single managed POL pool
     *         (FIX_POL Gap 3).
     * @dev Struct packing: `deployedPrincipalToken0/1` and `lpTokensHeld`
     *      remain `uint128` and pack into two slots (slot 0:
     *      principal0+principal1, slot 1: lpTokensHeld + the two
     *      `uint64` timestamps — `uint128 + uint64 + uint64 = 256`).
     *      The two lifetime-cumulative fee counters are widened to
     *      `uint256` (audit M-04) so they can never overflow-revert and
     *      brick {harvest}/{compound}; each takes its own slot. Total: 4
     *      slots. The principal/LP counters are bounded by realistic
     *      treasury sizes (far below 2^128) and decrement on withdraw,
     *      so `uint128` is safe for them; only the monotonic cumulative
     *      counters carry unbounded-lifetime overflow risk.
     * @param deployedPrincipalToken0 `token0` currently deployed from the
     *        treasury into this pool's LP position.
     * @param deployedPrincipalToken1 `token1` currently deployed from the
     *        treasury into this pool's LP position.
     * @param lpTokensHeld LP tokens currently held by the treasury for
     *        this pool, as tracked by POLManager's own deploy/withdraw
     *        bookkeeping.
     * @param lastDeployTimestamp Block timestamp of the most recent
     *        {deploy}/{compound} action on this pool.
     * @param lastHarvestTimestamp Block timestamp of the most recent
     *        {harvest}/{compound} action on this pool; enforced as a
     *        cadence floor by the `minHarvestInterval` guard.
     * @param cumulativeFeesHarvestedToken0 Cumulative `token0` fee
     *        surplus returned to the treasury by {harvest}/{compound}.
     * @param cumulativeFeesHarvestedToken1 Cumulative `token1` fee
     *        surplus returned to the treasury by {harvest}/{compound}.
     */
    struct PoolAccounting {
        uint128 deployedPrincipalToken0;
        uint128 deployedPrincipalToken1;
        uint128 lpTokensHeld;
        uint64 lastDeployTimestamp;
        uint64 lastHarvestTimestamp;
        uint256 cumulativeFeesHarvestedToken0;
        uint256 cumulativeFeesHarvestedToken1;
    }

    /**
     * @notice A pool's stored TWAP state, following the canonical
     *         Uniswap-V2 `ExampleOracleSimple` pattern (audit B2).
     * @dev WHY THIS SHAPE (audit B2 — griefing-DoS fix):
     *      The earlier design stored a single mutable cumulative-price
     *      snapshot and computed the TWAP live as
     *      `(currentCumulative - snapshot) / (now - snapshotTime)`. A
     *      griefer could re-{pokeObservation} every block, perpetually
     *      resetting `snapshotTime` so `timeElapsed` never reached
     *      `minTwapWindow` — every TWAP-consuming keeper action then
     *      reverted forever. This struct removes that surface:
     *
     *      - `price{0,1}AverageUQ` hold the UQ112x112 time-weighted
     *        average of the LAST COMPLETED window. Consumers read these
     *        STORED values directly — they never compute a live
     *        `[snapshot, now]` window — so a griefer cannot make a
     *        consult revert by manipulating the in-progress window.
     *      - `price{0,1}CumulativeLast` + `timestampLast` are the anchor
     *        of the CURRENTLY-MATURING window. {_pokeObservation} only
     *        advances the anchor (and recomputes the averages) once at
     *        least `minTwapWindow` seconds have elapsed; an early poke is
     *        a silent no-op, so a griefer's spam changes nothing and
     *        wastes only their own gas.
     *      - `averageTimestamp` is when `price{0,1}AverageUQ` were last
     *        refreshed. {_twapPriceUQ} reverts {TwapStale} if it is
     *        older than `minTwapWindow` (audit C3), forcing a refresh —
     *        but anyone (keeper included) can poke, and once
     *        `minTwapWindow` has elapsed the next poke ALWAYS succeeds
     *        regardless of griefing, so staleness can never be made
     *        permanent.
     *
     *      Struct packing: the two cumulative accumulators and the two
     *      average prices are each full 256-bit slots (UQ112x112 values
     *      grow without bound and wrap, exactly as Uniswap V2 intends).
     *      `timestampLast` and `averageTimestamp` are `uint32` (matching
     *      the RWAPool's `blockTimestampLast` width and the modulo-2^32
     *      accumulator arithmetic) and share one slot. Total: 5 slots.
     *      A `timestampLast` of zero is the sentinel for "no anchor set
     *      yet"; an `averageTimestamp` of zero means "no completed
     *      window exists yet".
     * @param price0CumulativeLast The token0 cumulative-price
     *        accumulator captured when the current window's anchor was
     *        last advanced.
     * @param price1CumulativeLast The token1 cumulative-price
     *        accumulator captured when the current window's anchor was
     *        last advanced.
     * @param price0AverageUQ The UQ112x112 token0->token1 time-weighted
     *        average price of the last completed window.
     * @param price1AverageUQ The UQ112x112 token1->token0 time-weighted
     *        average price of the last completed window.
     * @param timestampLast Block timestamp (mod 2^32) the current
     *        window's anchor was set; zero means no anchor exists yet.
     * @param averageTimestamp Block timestamp (mod 2^32) the stored
     *        averages were last refreshed; zero means no completed
     *        window exists yet.
     */
    struct Observation {
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint256 price0AverageUQ;
        uint256 price1AverageUQ;
        uint32 timestampLast;
        uint32 averageTimestamp;
    }

    // ─────────────────────────── Constants ───────────────────────────

    /// @notice Role that may mutate POL policy (token/pool whitelists,
    ///         per-pool policy, target weights).
    /// @dev Held by `OmniTimelockController`; every policy change
    ///      inherits the timelock delay.
    bytes32 public constant GOVERNANCE_ROLE =
        keccak256("GOVERNANCE_ROLE");

    /// @notice Role that may pause the contract in an emergency.
    /// @dev Held by `EmergencyGuardian` (1-of-N pause threshold).
    bytes32 public constant GUARDIAN_ROLE =
        keccak256("GUARDIAN_ROLE");

    /// @notice Role allowed to call the keeper triggers ({deploy},
    ///         {harvest}, {compound}, {rebalance}).
    /// @dev Audit C-01: keeper triggers are NOT permissionless. The
    ///      allowlist is managed by `GOVERNANCE_ROLE` via {setKeeper}.
    ///      Combined with the on-chain slippage bound and per-call
    ///      deploy cap, restricting the trigger removes the
    ///      atomic-drain / sandwich-on-demand attack surface.
    bytes32 public constant KEEPER_ROLE =
        keccak256("KEEPER_ROLE");

    /// @notice Basis-points denominator (100% = 10,000).
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Hard cap on a single pool's target weight (100%).
    uint256 public constant MAX_WEIGHT_BPS = 10000;

    /// @notice Hard ceiling on the governance-set `maxSlippageBps`.
    /// @dev Audit C-01: {setMaxSlippageBps} cannot raise the slippage
    ///      tolerance above 5% — even a compromised or coerced
    ///      governance proposal cannot re-open the zero-slippage drain.
    uint256 public constant MAX_SLIPPAGE_BPS_CAP = 500;

    /// @notice Default slippage tolerance applied to keeper swaps and
    ///         liquidity adds/removes (1%).
    uint256 public constant DEFAULT_MAX_SLIPPAGE_BPS = 100;

    /// @notice Maximum number of pools that can be configured, bounding
    ///         the gas cost of {rebalance}'s total-weight reads and any
    ///         enumeration over `poolIds`.
    uint256 public constant MAX_POOLS = 64;

    /// @notice Swap deadline buffer applied to OmniSwapRouter and
    ///         RWAAMM calls.
    /// @dev Added to `block.timestamp` at call time. A short, fixed
    ///      buffer is sufficient: keeper transactions either land in the
    ///      next few blocks or should revert and be retried.
    uint256 public constant SWAP_DEADLINE_BUFFER = 30 minutes;

    /// @notice Default minimum TWAP observation window (30 minutes).
    /// @dev Audit A1. A keeper swap derives its `minAmountOut` floor
    ///      from the time-weighted average price over at least this
    ///      window. A 30-minute mean cannot be moved by a same-block
    ///      flash-loan reserve skew, which is the manipulation A1
    ///      describes.
    uint256 public constant DEFAULT_MIN_TWAP_WINDOW = 30 minutes;

    /// @notice Hard floor on the governance-set `minTwapWindow`
    ///         (10 minutes).
    /// @dev Audit A1. {setMinTwapWindow} rejects any value below this
    ///      floor so a coerced or compromised governance proposal
    ///      cannot shrink the window toward a spot price and re-open
    ///      the sandwich surface.
    uint256 public constant MIN_TWAP_WINDOW_FLOOR = 10 minutes;

    /// @notice UQ112x112 fixed-point fractional-bit count.
    /// @dev Audit A1. The RWAPool accumulates `(reserveB << 112)
    ///      / reserveA` per second; a price read out of the
    ///      accumulators is divided back down by `2**112`.
    uint256 private constant UQ112X112_RESOLUTION = 112;

    // ──────────────────────── Immutable State ────────────────────────

    /// @notice The `OmniTreasuryV2` POL wallet this contract manages.
    /// @dev POLManager must hold `POL_DEPLOYER_ROLE` on this address.
    IOmniTreasuryV2POL public immutable TREASURY;

    /// @notice Raw treasury address, used as the funds destination for
    ///         LP tokens and harvested fees.
    address public immutable TREASURY_ADDRESS;

    /// @notice The RWAAMM contract POL liquidity is deployed into.
    IRWAAMM public immutable RWA_AMM;

    /// @notice The OmniSwapRouter used to split a single-asset treasury
    ///         balance into both sides of an AMM pair before deploying.
    IOmniSwapRouter public immutable SWAP_ROUTER;

    // ──────────────────────── State Variables ────────────────────────

    /// @notice Per-pool governance policy, keyed by RWAAMM pool ID.
    mapping(bytes32 => PoolPolicy) public poolPolicy;

    /// @notice Per-pool on-chain accounting, keyed by RWAAMM pool ID.
    mapping(bytes32 => PoolAccounting) public poolAccounting;

    /// @notice Whether a token is approved for use as POL principal.
    /// @dev Both sides of every whitelisted pool must be whitelisted
    ///      tokens; enforced in {whitelistPool}.
    mapping(address => bool) public whitelistedToken;

    /// @notice Whether a pool ID is under POLManager management.
    mapping(bytes32 => bool) public whitelistedPool;

    /// @notice Enumerable list of every whitelisted pool ID.
    /// @dev Bounded by `MAX_POOLS`. Used by {rebalance} and external
    ///      dashboards to walk the managed set. Pools are appended by
    ///      {whitelistPool} and swap-popped by {deWhitelistPool}.
    bytes32[] public poolIds;

    /// @notice Slippage tolerance in basis points applied to every
    ///         keeper swap and liquidity add/remove.
    /// @dev Audit C-01. Governance-set via {setMaxSlippageBps}, hard-
    ///      capped at `MAX_SLIPPAGE_BPS_CAP`. `minOut` / `amountMin`
    ///      arguments are derived from the pool's current on-chain
    ///      reserves scaled by `(BPS_DENOMINATOR - maxSlippageBps)` —
    ///      never zero.
    uint256 public maxSlippageBps;

    /// @notice Maximum `token1` notional a single {deploy} / {compound}
    ///         redeploy may move from the treasury into a pool.
    /// @dev Audit C-01 / M-05. Governance-set via {setMaxDeployPerCall}.
    ///      Caps the amount one keeper call can commit, so the deploy
    ///      size is no longer the full, deterministic, mempool-visible
    ///      idle balance. Zero is rejected by the setter.
    uint256 public maxDeployPerCall;

    /// @notice OmniSwapRouter liquidity-source identifier used for the
    ///         single-hop `token1 -> token0` split swap.
    /// @dev Audit H-01. Governance-set via {setRwaammSourceId}. Must be
    ///      a non-zero, router-registered source id; {_swapExactIn}
    ///      reverts {SwapSourceNotConfigured} if it is `bytes32(0)`.
    bytes32 public rwaammSourceId;

    /// @notice Per-pool stored TWAP state, keyed by RWAAMM pool ID.
    /// @dev Audit A1 / A2 / B2. Written by the permissionless
    ///      {pokeObservation} and consumed by {_consultTwap} /
    ///      {_twapPriceUQ}. Follows the Uniswap-V2 `ExampleOracleSimple`
    ///      pattern: consumers read the STORED last-completed-window
    ///      average (`price{0,1}AverageUQ`), never a live
    ///      `[snapshot, now]` window. {pokeObservation} advances the
    ///      window anchor only once `minTwapWindow` has elapsed — an
    ///      early poke is a silent no-op — so a griefer cannot brick
    ///      keeper actions by spamming pokes (audit B2).
    mapping(bytes32 => Observation) public poolObservation;

    /// @notice Minimum length (seconds) of a completed TWAP window.
    /// @dev Audit A1 / B2. Governance-set via {setMinTwapWindow},
    ///      floored at `MIN_TWAP_WINDOW_FLOOR`. Defaults to
    ///      `DEFAULT_MIN_TWAP_WINDOW` (30 minutes). {pokeObservation}
    ///      refreshes a pool's stored average only after the current
    ///      window has run at least this long; {_twapPriceUQ} rejects a
    ///      stored average older than `minTwapWindow` as stale (audit
    ///      C3). A window averaged over less than this floor is not
    ///      manipulation-resistant — a same-block flash-skew cannot move
    ///      a 30-minute mean.
    uint256 public minTwapWindow;

    /// @notice Per-pool minimum seconds between consecutive {deploy}
    ///         actions, keyed by RWAAMM pool ID.
    /// @dev Audit A3. Governance-set via {setCadence}. Enforced against
    ///      `PoolAccounting.lastDeployTimestamp` so a keeper cannot loop
    ///      the per-call cap into a drain. Zero disables the floor.
    mapping(bytes32 => uint256) public minDeployInterval;

    /// @notice Per-pool minimum seconds between consecutive {rebalance}
    ///         actions, keyed by RWAAMM pool ID.
    /// @dev Audit A3. Governance-set via {setCadence}. Enforced against
    ///      `lastRebalanceTimestamp`. Zero disables the floor.
    mapping(bytes32 => uint256) public minRebalanceInterval;

    /// @notice Block timestamp of the most recent {rebalance} action on
    ///         a pool, keyed by RWAAMM pool ID.
    /// @dev Audit A3. Paired with `minRebalanceInterval` to gate
    ///      consecutive {rebalance} calls.
    mapping(bytes32 => uint256) public lastRebalanceTimestamp;

    // ──────────────────────────── Events ─────────────────────────────

    /// @notice Emitted when a token is added to or removed from the
    ///         principal whitelist.
    /// @param token The token address.
    /// @param allowed True if whitelisted, false if removed.
    event TokenWhitelisted(address indexed token, bool indexed allowed);

    /// @notice Emitted when a pool is added to POLManager management.
    /// @param poolId The RWAAMM pool ID.
    /// @param token0 First token of the pair, in the RWAPool's order.
    /// @param token1 Second token of the pair, in the RWAPool's order.
    event PoolWhitelisted(
        bytes32 indexed poolId,
        address indexed token0,
        address indexed token1
    );

    /// @notice Emitted when a pool is removed from POLManager
    ///         management.
    /// @param poolId The RWAAMM pool ID that was de-whitelisted.
    event PoolDeWhitelisted(bytes32 indexed poolId);

    /// @notice Emitted when an address is added to or removed from the
    ///         keeper allowlist.
    /// @param keeper The keeper address.
    /// @param allowed True if the address may now call keeper triggers.
    event KeeperSet(address indexed keeper, bool indexed allowed);

    /// @notice Emitted when the global slippage tolerance is updated.
    /// @param oldBps Previous `maxSlippageBps`.
    /// @param newBps New `maxSlippageBps`.
    event MaxSlippageBpsSet(
        uint256 indexed oldBps,
        uint256 indexed newBps
    );

    /// @notice Emitted when the per-call deploy cap is updated.
    /// @param oldCap Previous `maxDeployPerCall`.
    /// @param newCap New `maxDeployPerCall`.
    event MaxDeployPerCallSet(
        uint256 indexed oldCap,
        uint256 indexed newCap
    );

    /// @notice Emitted when the OmniSwapRouter source id is updated.
    /// @param oldSourceId Previous `rwaammSourceId`.
    /// @param newSourceId New `rwaammSourceId`.
    event RwaammSourceIdSet(
        bytes32 indexed oldSourceId,
        bytes32 indexed newSourceId
    );

    /// @notice Emitted when the minimum TWAP window is updated.
    /// @param oldWindow Previous `minTwapWindow` in seconds.
    /// @param newWindow New `minTwapWindow` in seconds.
    event MinTwapWindowSet(
        uint256 indexed oldWindow,
        uint256 indexed newWindow
    );

    /// @notice Emitted when a pool's deploy/rebalance cadence floors are
    ///         updated.
    /// @param poolId The RWAAMM pool ID.
    /// @param minDeployInterval New minimum seconds between {deploy}s.
    /// @param minRebalanceInterval New minimum seconds between
    ///        {rebalance}s.
    event CadenceSet(
        bytes32 indexed poolId,
        uint256 indexed minDeployInterval,
        uint256 indexed minRebalanceInterval
    );

    /* solhint-disable gas-indexed-events */
    // The cumulative-price and timestamp fields below are deliberately
    // NOT indexed: they are free-form numeric values with no useful
    // filtering semantics. The poolId and caller — the fields a
    // dashboard filters on — are indexed.

    /// @notice Emitted when a pool's TWAP window completes and its
    ///         stored average is refreshed (audit B2).
    /// @dev Emitted ONLY when a poke actually advances the window — an
    ///      early, no-op poke (window still maturing) emits nothing.
    ///      The `refreshed` flag therefore signals a real refresh; off-
    ///      chain watchers can detect a no-op poke by its absence.
    /// @param poolId The RWAAMM pool ID.
    /// @param caller The address that poked the observation.
    /// @param price0AverageUQ The newly stored token0->token1 UQ112x112
    ///        average for the completed window.
    /// @param price1AverageUQ The newly stored token1->token0 UQ112x112
    ///        average for the completed window.
    /// @param timestamp The block timestamp (mod 2^32) the window
    ///        completed and the average was stored.
    event ObservationPoked(
        bytes32 indexed poolId,
        address indexed caller,
        uint256 price0AverageUQ,
        uint256 price1AverageUQ,
        uint32 timestamp
    );
    /* solhint-enable gas-indexed-events */

    /* solhint-disable gas-indexed-events */
    // The amount/fee/LP fields below are deliberately NOT indexed:
    // indexing free-form numeric values yields little filtering value
    // and pollutes the bloom filter (small magnitudes collide). The
    // poolId and caller — the fields dashboards actually filter on —
    // are indexed.

    /// @notice Emitted when a pool's policy is created or updated.
    /// @param poolId The RWAAMM pool ID.
    /// @param enabled Whether keeper triggers may act on the pool.
    /// @param minIdleToDeploy Minimum idle `token1` to trigger {deploy}.
    /// @param rebalanceDriftBps Drift threshold permitting {rebalance}.
    event PolicyUpdated(
        bytes32 indexed poolId,
        bool indexed enabled,
        uint256 minIdleToDeploy,
        uint256 rebalanceDriftBps
    );

    /// @notice Emitted when target weights are (re)assigned in a batch.
    /// @param poolCount Number of pools whose weight was set.
    /// @param totalWeightBps Sum of the assigned weights, in bps.
    event TargetWeightsSet(
        uint256 indexed poolCount,
        uint256 indexed totalWeightBps
    );

    /// @notice Emitted when liquidity is deployed into a pool.
    /// @param poolId The RWAAMM pool ID.
    /// @param caller The keeper that triggered the deploy.
    /// @param amount0 `token0` deposited.
    /// @param amount1 `token1` deposited.
    /// @param lpMinted LP tokens minted and forwarded to the treasury.
    event LiquidityDeployed(
        bytes32 indexed poolId,
        address indexed caller,
        uint256 amount0,
        uint256 amount1,
        uint256 lpMinted
    );

    /// @notice Emitted when LP fees are harvested back to the treasury.
    /// @param poolId The RWAAMM pool ID.
    /// @param caller The keeper that triggered the harvest.
    /// @param feeToken0 `token0` fees returned to the treasury.
    /// @param feeToken1 `token1` fees returned to the treasury.
    event FeesHarvested(
        bytes32 indexed poolId,
        address indexed caller,
        uint256 feeToken0,
        uint256 feeToken1
    );

    /// @notice Emitted when a pool position is rebalanced toward its
    ///         target weight.
    /// @param poolId The RWAAMM pool ID.
    /// @param caller The keeper that triggered the rebalance.
    /// @param lpWithdrawn LP tokens withdrawn from the position.
    event PositionRebalanced(
        bytes32 indexed poolId,
        address indexed caller,
        uint256 lpWithdrawn
    );
    /* solhint-enable gas-indexed-events */

    /// @notice Emitted when residual token dust is swept to the
    ///         treasury at the end of a keeper action.
    /// @param token The token swept.
    /// @param amount The amount swept.
    event DustSwept(address indexed token, uint256 indexed amount);

    // ──────────────────────────── Errors ─────────────────────────────

    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a numeric argument is zero where non-zero is
    ///         required.
    error ZeroAmount();

    /// @notice Thrown when a pool ID is not under POLManager management.
    /// @param poolId The unmanaged pool ID.
    error PoolNotWhitelisted(bytes32 poolId);

    /// @notice Thrown when a pool is already whitelisted.
    /// @param poolId The duplicate pool ID.
    error PoolAlreadyWhitelisted(bytes32 poolId);

    /// @notice Thrown when a pool's policy disables keeper triggers.
    /// @param poolId The disabled pool ID.
    error PoolDisabled(bytes32 poolId);

    /// @notice Thrown when a token is not on the principal whitelist.
    /// @param token The non-whitelisted token.
    error TokenNotWhitelisted(address token);

    /// @notice Thrown when adding a pool would exceed `MAX_POOLS`.
    error TooManyPools();

    /// @notice Thrown when a target weight exceeds `MAX_WEIGHT_BPS` or
    ///         a batch's weights sum above `MAX_WEIGHT_BPS`.
    /// @param providedBps The offending weight or weight sum.
    error InvalidWeight(uint256 providedBps);

    /// @notice Thrown when array arguments have mismatched lengths.
    error ArrayLengthMismatch();

    /// @notice Thrown when idle treasury balance is below the pool's
    ///         `minIdleToDeploy` threshold, so {deploy} must no-op.
    /// @param available Idle balance available.
    /// @param required The pool's `minIdleToDeploy`.
    error IdleBelowThreshold(uint256 available, uint256 required);

    /// @notice Thrown when {rebalance} is called but the position's
    ///         drift is within the configured tolerance.
    /// @param driftBps Observed drift in basis points.
    /// @param toleranceBps Configured `rebalanceDriftBps`.
    error DriftWithinTolerance(uint256 driftBps, uint256 toleranceBps);

    /// @notice Thrown when there is nothing for a keeper trigger to act
    ///         on (no idle funds, no LP position, no accrued fees).
    error NothingToDo();

    /// @notice Thrown when a governance-set value exceeds its hard cap.
    /// @param provided The offending value.
    /// @param maximum The hard cap.
    error ValueAboveCap(uint256 provided, uint256 maximum);

    /// @notice Thrown when the OmniSwapRouter source id has not been
    ///         configured (still `bytes32(0)`) and a swap is attempted.
    error SwapSourceNotConfigured();

    /// @notice Thrown when the RWAAMM has no live pool for a pair being
    ///         whitelisted.
    /// @param poolId The pool id that does not exist on the RWAAMM.
    error PoolDoesNotExist(bytes32 poolId);

    /// @notice Thrown when a keeper swap or liquidity action returns
    ///         less than the slippage-bounded minimum.
    /// @param received The actual amount obtained.
    /// @param minRequired The slippage-bounded minimum.
    error SlippageExceeded(uint256 received, uint256 minRequired);

    /// @notice Thrown when {harvest}/{compound} is called again before
    ///         the pool's `minHarvestInterval` cadence floor elapses.
    /// @param nextAllowedAt Earliest timestamp the action may run.
    error HarvestCadenceNotElapsed(uint256 nextAllowedAt);

    /// @notice Thrown when {deWhitelistPool} is called on a pool that
    ///         still holds an LP position.
    /// @param lpHeld The non-zero LP balance still deployed.
    error PoolStillHasLiquidity(uint256 lpHeld);

    /// @notice Thrown when this contract is not registered as a
    ///         treasury POL target, so `transferTokenToPOL` to it would
    ///         revert (audit M-01).
    error POLManagerNotTreasuryTarget();

    /// @notice Thrown when a numeric argument is zero where non-zero is
    ///         required for a governance parameter.
    error ZeroValue();

    /// @notice Thrown when a `uint256` accounting value exceeds the
    ///         `uint128` storage width of a counter.
    /// @param value The offending value.
    error ValueTooLarge(uint256 value);

    /// @notice Thrown when a TWAP consult is attempted on a pool that
    ///         has no completed window yet — its stored average has
    ///         never been populated (audit A1 / B2).
    /// @dev First-use procedure: the keeper runbook calls
    ///      {pokeObservation} once to set the window anchor, waits at
    ///      least `minTwapWindow` seconds, calls {pokeObservation} again
    ///      to store the first completed-window average, then the keeper
    ///      action may run.
    /// @param poolId The pool with no completed TWAP window.
    error NoCompletedWindow(bytes32 poolId);

    /// @notice Thrown when a pool's stored TWAP average is older than
    ///         `minTwapWindow`, so it is too stale to anchor a keeper
    ///         action's slippage floor (audit B2 / C3).
    /// @dev Anyone — including the keeper itself — may {pokeObservation}
    ///      to refresh it; once `minTwapWindow` has elapsed the next
    ///      poke always succeeds, so staleness can never be made
    ///      permanent by a griefer.
    /// @param averageAge Seconds since the stored average was refreshed.
    /// @param maxAge The staleness ceiling (`minTwapWindow`).
    error TwapStale(uint256 averageAge, uint256 maxAge);

    /// @notice Thrown when a governance-set `minTwapWindow` is below the
    ///         `MIN_TWAP_WINDOW_FLOOR` hard floor (audit A1).
    /// @param provided The offending window.
    /// @param minimum The hard floor.
    error ValueBelowFloor(uint256 provided, uint256 minimum);

    /// @notice Thrown when {deploy} is called again before the pool's
    ///         `minDeployInterval` cadence floor elapses (audit A3).
    /// @param nextAllowedAt Earliest timestamp {deploy} may run.
    error DeployCadenceNotElapsed(uint256 nextAllowedAt);

    /// @notice Thrown when {rebalance} is called again before the pool's
    ///         `minRebalanceInterval` cadence floor elapses (audit A3).
    /// @param nextAllowedAt Earliest timestamp {rebalance} may run.
    error RebalanceCadenceNotElapsed(uint256 nextAllowedAt);

    /// @notice Thrown when {setPolicy} would enable a pool whose
    ///         `minHarvestInterval` is zero (audit A6).
    /// @param poolId The pool with a zero harvest cadence.
    error HarvestCadenceRequired(bytes32 poolId);

    /// @notice Thrown when {setCadence} is given a zero
    ///         `minDeployInterval` or `minRebalanceInterval` (audit B5).
    /// @dev Mirrors the A6 harvest-cadence guard: a zero interval would
    ///      disable the {deploy} / {rebalance} spam floor, re-opening the
    ///      keeper loop a governance misconfiguration could otherwise
    ///      create.
    /// @param poolId The pool whose cadence was misconfigured.
    error DeployCadenceRequired(bytes32 poolId);

    /// @notice Thrown when a {compound} call's end-to-end TWAP-valued
    ///         output falls below the slippage-bounded floor of its
    ///         pre-compound TWAP-valued worth (audit A4).
    /// @param postValue TWAP-valued worth of the redeployed position.
    /// @param minRequired Slippage-bounded floor of the pre-compound
    ///        TWAP-valued worth.
    error CompoundValueLoss(uint256 postValue, uint256 minRequired);

    /// @notice Thrown when a {harvest} call's end-to-end TWAP-valued
    ///         output falls below the slippage-bounded floor of its
    ///         pre-harvest TWAP-valued worth (audit D1).
    /// @dev {harvest} is a withdraw-then-redeploy: value-conserving
    ///      minus execution slippage, exactly like {compound}. The same
    ///      single end-to-end bound applies — the per-leg swap and add
    ///      bands can no longer silently stack to ~2x `maxSlippageBps`.
    /// @param postValue TWAP-valued worth of the redeployed position.
    /// @param minRequired Slippage-bounded floor of the pre-harvest
    ///        TWAP-valued worth.
    error HarvestValueLoss(uint256 postValue, uint256 minRequired);

    /// @notice Thrown when a {deploy} call's TWAP-valued position GAIN
    ///         falls below the slippage-bounded floor of the capital it
    ///         committed (audit D1).
    /// @dev {deploy} ADDS new capital, so the pool position's value must
    ///      RISE by at least the deployed `token1` notional minus the
    ///      single `maxSlippageBps` band. A sandwiched split swap yields
    ///      less `token0`, so the realized principal — and thus
    ///      `postValue - preValue` — falls below the band and the call
    ///      reverts. This replaces the previously stacked per-leg bands
    ///      with one end-to-end bound.
    /// @param valueGained `postValue - preValue` — the TWAP-valued
    ///        position worth POLManager gained from this deploy.
    /// @param minRequired Slippage-bounded floor of the deployed
    ///        `token1` capital.
    error DeployValueLoss(uint256 valueGained, uint256 minRequired);

    // ─────────────────────────── Constructor ─────────────────────────

    /**
     * @notice Deploy the POLManager.
     * @dev All external contract addresses are supplied as constructor
     *      arguments — none are hardcoded. The caller is responsible for
     *      sourcing them from `Coin/deployments/mainnet.json` /
     *      `omnicoin-integration.ts`.
     *
     *      REQUIRED POST-DEPLOY TREASURY WIRING (audit M-01):
     *      After deployment the treasury `DEFAULT_ADMIN_ROLE` MUST:
     *        1. grant this contract `POL_DEPLOYER_ROLE` on the treasury;
     *        2. call `setPOLTarget(<this POLManager>, true)` — every
     *           keeper action routes treasury funds *to POLManager* via
     *           `transferTokenToPOL`, so POLManager's OWN address must
     *           be a `polTargets` entry, otherwise every {deploy} /
     *           {harvest} / {compound} / {rebalance} reverts
     *           `POLTargetNotAllowed`;
     *        3. call `setPOLTarget(rwaAmm, true)` so LP tokens for a
     *           pool can also be routed when needed.
     *      POLManager enforces step 2 at the start of every fund-moving
     *      keeper action via {_requirePOLManagerIsTreasuryTarget};
     *      a missing wiring fails loudly with
     *      {POLManagerNotTreasuryTarget} rather than an opaque revert.
     *
     *      GOVERNANCE CONFIG before keepers go live:
     *        - {setRwaammSourceId} with the router-registered RWAAMM
     *          source id (audit H-01);
     *        - {setMaxDeployPerCall} with a sane per-call cap
     *          (audit C-01 / M-05);
     *        - {setKeeper} for each authorized keeper address
     *          (audit C-01);
     *        - {setCadence} per pool with `minDeployInterval` /
     *          `minRebalanceInterval` floors (audit A3).
     *      `maxSlippageBps` defaults to `DEFAULT_MAX_SLIPPAGE_BPS` (1%)
     *      and can be tuned via {setMaxSlippageBps}. `minTwapWindow`
     *      defaults to `DEFAULT_MIN_TWAP_WINDOW` (30 minutes) and can be
     *      tuned via {setMinTwapWindow} (audit A1 / B2).
     *
     *      TWAP FIRST-USE RUNBOOK (audit B2): every keeper action that
     *      consults a pool's TWAP requires a completed window. For each
     *      managed pool, before the first {deploy} / {harvest} /
     *      {compound} / {rebalance}: call {pokeObservation} once to seed
     *      the window anchor, wait at least `minTwapWindow` seconds,
     *      then call {pokeObservation} again to store the first
     *      completed-window average. Thereafter a watcher cron should
     *      keep poking so the stored average never ages past
     *      `minTwapWindow` (a stale average reverts {TwapStale} —
     *      anyone may re-poke to refresh it). Each keeper action also
     *      pokes at end-of-call.
     *
     *      The deployer receives `DEFAULT_ADMIN_ROLE`, `GOVERNANCE_ROLE`,
     *      and `GUARDIAN_ROLE` for Pioneer-Phase setup; these must be
     *      transitioned to `OmniTimelockController` (governance + admin)
     *      and `EmergencyGuardian` (guardian) before POL automation goes
     *      live, mirroring the OmniTreasuryV2 handoff. `KEEPER_ROLE` is
     *      admined by `GOVERNANCE_ROLE`.
     * @param treasury_ Address of the `OmniTreasuryV2` POL wallet.
     * @param rwaAmm_ Address of the RWAAMM contract.
     * @param swapRouter_ Address of the OmniSwapRouter.
     * @param admin_ Pioneer-Phase admin/governance/guardian holder.
     * @param trustedForwarder_ ERC-2771 trusted forwarder for gasless
     *        keeper calls.
     */
    constructor(
        address treasury_,
        address rwaAmm_,
        address swapRouter_,
        address admin_,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        if (
            treasury_ == address(0) ||
            rwaAmm_ == address(0) ||
            swapRouter_ == address(0) ||
            admin_ == address(0)
        ) {
            revert ZeroAddress();
        }

        TREASURY = IOmniTreasuryV2POL(treasury_);
        TREASURY_ADDRESS = treasury_;
        RWA_AMM = IRWAAMM(rwaAmm_);
        SWAP_ROUTER = IOmniSwapRouter(swapRouter_);
        maxSlippageBps = DEFAULT_MAX_SLIPPAGE_BPS;
        minTwapWindow = DEFAULT_MIN_TWAP_WINDOW;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(GOVERNANCE_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE, admin_);

        // KEEPER_ROLE is managed by GOVERNANCE_ROLE (the timelock), not
        // by DEFAULT_ADMIN_ROLE, so keeper management inherits the
        // governance pipeline (audit C-01).
        _setRoleAdmin(KEEPER_ROLE, GOVERNANCE_ROLE);
    }

    // ─────────────────── Governance: Policy Setters ──────────────────

    /**
     * @notice Add or remove a token from the POL principal whitelist.
     * @dev Governance-only; inherits the timelock delay. A token must be
     *      whitelisted before any pool using it can be whitelisted.
     * @param token The token address.
     * @param allowed True to whitelist, false to remove.
     */
    function whitelistToken(
        address token,
        bool allowed
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (token == address(0)) revert ZeroAddress();

        whitelistedToken[token] = allowed;

        emit TokenWhitelisted(token, allowed);
    }

    /**
     * @notice Bring a RWAAMM pool under POLManager management.
     * @dev Governance-only. Both tokens of the pair must already be on
     *      the principal whitelist.
     *
     *      Audit H-06: the RWAAMM pool MUST already exist — this
     *      function calls {IRWAAMM-poolExists} and reverts
     *      {PoolDoesNotExist} if the pool has not been created. A
     *      whitelisted-but-nonexistent pool would brick every later
     *      {deploy} with an opaque `NotPoolCreator` revert.
     *
     *      Audit H-03: the stored `token0` / `token1` are read from the
     *      live RWAPool itself (`RWAPool.token0()` / `token1()` via the
     *      AMM-resolved pool address) — NOT locally sorted. The RWAPool
     *      fixes its own ordering at creation; storing a self-sorted
     *      order can invert per-side accounting and route the split
     *      swap the wrong way.
     *
     *      Initializes a default-disabled policy; call {setPolicy} to
     *      enable keeper triggers.
     * @param token0 First token of the pair (any order — the stored
     *        order is taken from the RWAPool).
     * @param token1 Second token of the pair.
     * @return poolId The RWAAMM pool ID now under management.
     */
    function whitelistPool(
        address token0,
        address token1
    ) external onlyRole(GOVERNANCE_ROLE) returns (bytes32 poolId) {
        if (token0 == address(0) || token1 == address(0)) {
            revert ZeroAddress();
        }
        if (!whitelistedToken[token0]) {
            revert TokenNotWhitelisted(token0);
        }
        if (!whitelistedToken[token1]) {
            revert TokenNotWhitelisted(token1);
        }
        // solhint-disable-next-line gas-strict-inequalities
        if (poolIds.length >= MAX_POOLS) revert TooManyPools();

        poolId = RWA_AMM.getPoolId(token0, token1);
        if (whitelistedPool[poolId]) {
            revert PoolAlreadyWhitelisted(poolId);
        }
        // H-06: the pool must be live on the RWAAMM registry.
        if (!RWA_AMM.poolExists(poolId)) {
            revert PoolDoesNotExist(poolId);
        }

        // H-03: read the RWAPool's OWN token ordering and store that,
        // so amount0/amount1 always line up with the pool's reserves.
        IRWAAMM.PoolInfo memory info = RWA_AMM.getPool(poolId);

        whitelistedPool[poolId] = true;
        poolIds.push(poolId);

        poolPolicy[poolId] = PoolPolicy({
            token0: info.token0,
            targetWeightBps: 0,
            token1: info.token1,
            enabled: false,
            minIdleToDeploy: 0,
            rebalanceDriftBps: 0,
            minHarvestInterval: 0
        });

        emit PoolWhitelisted(poolId, info.token0, info.token1);
    }

    /**
     * @notice Remove a pool from POLManager management.
     * @dev Governance-only (audit M-06). Swap-pops `poolIds` and clears
     *      the pool's `whitelistedPool` flag so stale pools no longer
     *      skew {_realizedWeightBps} or bloat the rebalance loop. The
     *      pool MUST have a zero LP position first — its liquidity must
     *      be fully withdrawn (via {harvest} or {rebalance}) before
     *      retirement, otherwise {PoolStillHasLiquidity} reverts and
     *      the protocol's POL would be silently stranded.
     * @param poolId The RWAAMM pool ID to retire.
     */
    function deWhitelistPool(
        bytes32 poolId
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (!whitelistedPool[poolId]) {
            revert PoolNotWhitelisted(poolId);
        }
        uint256 lpHeld = poolAccounting[poolId].lpTokensHeld;
        if (lpHeld != 0) revert PoolStillHasLiquidity(lpHeld);

        whitelistedPool[poolId] = false;
        delete poolPolicy[poolId];
        delete poolAccounting[poolId];

        // Swap-pop the pool id out of the enumerable array.
        uint256 len = poolIds.length;
        for (uint256 i; i < len; ++i) {
            if (poolIds[i] == poolId) {
                poolIds[i] = poolIds[len - 1];
                poolIds.pop();
                break;
            }
        }

        emit PoolDeWhitelisted(poolId);
    }

    /**
     * @notice Set the operational policy for a whitelisted pool.
     * @dev Governance-only; inherits the timelock delay. Does not touch
     *      `targetWeightBps` — weights are managed in batch via
     *      {setTargetWeights} so the cross-pool sum stays consistent.
     * @param poolId The RWAAMM pool ID.
     * @param enabled Whether keeper triggers may act on the pool.
     * @param minIdleToDeploy Minimum idle `token1` to trigger {deploy},
     *        in `token1` base units.
     * @param rebalanceDriftBps Drift threshold in bps permitting
     *        {rebalance}; must not exceed `MAX_WEIGHT_BPS`.
     * @param minHarvestInterval Minimum seconds between consecutive
     *        {harvest}/{compound} actions on this pool (audit C-02 /
     *        A6 cadence guard). MUST be non-zero when `enabled` is true
     *        — a zero interval on an enabled pool is rejected with
     *        {HarvestCadenceRequired} so the cadence guard can never be
     *        disabled for a live pool. May be zero only for a disabled
     *        pool (no keeper action can run anyway).
     */
    function setPolicy(
        bytes32 poolId,
        bool enabled,
        uint256 minIdleToDeploy,
        uint256 rebalanceDriftBps,
        uint256 minHarvestInterval
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (!whitelistedPool[poolId]) {
            revert PoolNotWhitelisted(poolId);
        }
        if (rebalanceDriftBps > MAX_WEIGHT_BPS) {
            revert InvalidWeight(rebalanceDriftBps);
        }
        // A6: an enabled pool MUST carry a non-zero harvest cadence so
        // the {harvest}/{compound} spam guard is never bypassable.
        if (enabled && minHarvestInterval == 0) {
            revert HarvestCadenceRequired(poolId);
        }

        PoolPolicy storage policy = poolPolicy[poolId];
        policy.enabled = enabled;
        policy.minIdleToDeploy = minIdleToDeploy;
        policy.rebalanceDriftBps = rebalanceDriftBps;
        policy.minHarvestInterval = minHarvestInterval;

        emit PolicyUpdated(
            poolId, enabled, minIdleToDeploy, rebalanceDriftBps
        );
    }

    /**
     * @notice Assign target POL weights to a batch of pools.
     * @dev Governance-only. Validates each weight individually and the
     *      batch sum against `MAX_WEIGHT_BPS`. Pools omitted from the
     *      batch keep their existing weight, so callers SHOULD pass the
     *      full managed set when rebalancing the allocation.
     * @param poolIds_ The pool IDs to assign weights to.
     * @param weightsBps_ The target weight for each pool, in bps,
     *        index-aligned with `poolIds_`.
     */
    function setTargetWeights(
        bytes32[] calldata poolIds_,
        uint256[] calldata weightsBps_
    ) external onlyRole(GOVERNANCE_ROLE) {
        uint256 len = poolIds_.length;
        if (len != weightsBps_.length) revert ArrayLengthMismatch();

        uint256 totalBps;
        for (uint256 i; i < len; ++i) {
            bytes32 poolId = poolIds_[i];
            if (!whitelistedPool[poolId]) {
                revert PoolNotWhitelisted(poolId);
            }
            uint256 weight = weightsBps_[i];
            if (weight > MAX_WEIGHT_BPS) revert InvalidWeight(weight);

            totalBps += weight;
            poolPolicy[poolId].targetWeightBps = uint96(weight);
        }
        if (totalBps > MAX_WEIGHT_BPS) revert InvalidWeight(totalBps);

        emit TargetWeightsSet(len, totalBps);
    }

    /**
     * @notice Add or remove an address from the keeper allowlist.
     * @dev Governance-only (audit C-01). Keeper triggers ({deploy},
     *      {harvest}, {compound}, {rebalance}) are gated to `KEEPER_ROLE`
     *      holders; this setter manages that role. `KEEPER_ROLE` is
     *      admined by `GOVERNANCE_ROLE`, so this is the canonical entry
     *      point. Granting via the raw {AccessControl-grantRole} also
     *      works and is equivalent.
     * @param keeper The keeper address.
     * @param allowed True to authorize the keeper, false to revoke.
     */
    function setKeeper(
        address keeper,
        bool allowed
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (keeper == address(0)) revert ZeroAddress();

        if (allowed) {
            _grantRole(KEEPER_ROLE, keeper);
        } else {
            _revokeRole(KEEPER_ROLE, keeper);
        }

        emit KeeperSet(keeper, allowed);
    }

    /**
     * @notice Set the global slippage tolerance for keeper actions.
     * @dev Governance-only (audit C-01). Hard-capped at
     *      `MAX_SLIPPAGE_BPS_CAP` (5%) so the zero-slippage drain can
     *      never be re-opened, even by a coerced governance proposal.
     * @param newBps The new slippage tolerance in basis points.
     */
    function setMaxSlippageBps(
        uint256 newBps
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (newBps > MAX_SLIPPAGE_BPS_CAP) {
            revert ValueAboveCap(newBps, MAX_SLIPPAGE_BPS_CAP);
        }

        uint256 oldBps = maxSlippageBps;
        maxSlippageBps = newBps;

        emit MaxSlippageBpsSet(oldBps, newBps);
    }

    /**
     * @notice Set the maximum `token1` notional a single {deploy} /
     *         {compound} redeploy may move from the treasury.
     * @dev Governance-only (audit C-01 / M-05). Must be non-zero. Caps
     *      the per-call deploy size so one keeper call cannot move the
     *      whole idle balance, shrinking the MEV target and bounding the
     *      blast radius of any single keeper action.
     * @param newCap The new per-call cap in `token1` base units.
     */
    function setMaxDeployPerCall(
        uint256 newCap
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (newCap == 0) revert ZeroValue();

        uint256 oldCap = maxDeployPerCall;
        maxDeployPerCall = newCap;

        emit MaxDeployPerCallSet(oldCap, newCap);
    }

    /**
     * @notice Set the OmniSwapRouter liquidity-source identifier used
     *         for the `token1 -> token0` split swap.
     * @dev Governance-only (audit H-01). Must be a non-zero source id
     *      that is registered on the OmniSwapRouter; {_swapExactIn}
     *      reverts {SwapSourceNotConfigured} while it is `bytes32(0)`.
     * @param newSourceId The router-registered source id.
     */
    function setRwaammSourceId(
        bytes32 newSourceId
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (newSourceId == bytes32(0)) revert SwapSourceNotConfigured();

        bytes32 oldSourceId = rwaammSourceId;
        rwaammSourceId = newSourceId;

        emit RwaammSourceIdSet(oldSourceId, newSourceId);
    }

    /**
     * @notice Set the minimum age a TWAP {Observation} must have before
     *         a keeper swap may reference it.
     * @dev Governance-only (audit A1). Hard-floored at
     *      `MIN_TWAP_WINDOW_FLOOR` (10 minutes) so the window can never
     *      be shrunk toward a spot price — a sub-floor window would
     *      re-open the same-block sandwich surface A1 describes. There
     *      is intentionally no ceiling: a longer window is strictly
     *      more conservative.
     * @param newWindow The new minimum TWAP window in seconds.
     */
    function setMinTwapWindow(
        uint256 newWindow
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (newWindow < MIN_TWAP_WINDOW_FLOOR) {
            revert ValueBelowFloor(newWindow, MIN_TWAP_WINDOW_FLOOR);
        }

        uint256 oldWindow = minTwapWindow;
        minTwapWindow = newWindow;

        emit MinTwapWindowSet(oldWindow, newWindow);
    }

    /**
     * @notice Set the per-pool {deploy} and {rebalance} cadence floors.
     * @dev Governance-only (audit A3). Mirrors `minHarvestInterval` for
     *      the deploy and rebalance triggers: a keeper cannot loop the
     *      per-call deploy cap into a drain, nor spam {rebalance},
     *      because consecutive calls on the same pool are interval-gated
     *      against `lastDeployTimestamp` / `lastRebalanceTimestamp`.
     *
     *      Audit B5: both intervals MUST be non-zero — a zero interval
     *      would disable the corresponding spam floor and re-open the
     *      keeper loop, the same hole the A6 harvest-cadence guard
     *      closes for {harvest}/{compound}. A zero value is rejected
     *      with {DeployCadenceRequired}.
     * @param poolId The RWAAMM pool ID.
     * @param minDeployInterval_ Minimum seconds between {deploy}s; must
     *        be non-zero (audit B5).
     * @param minRebalanceInterval_ Minimum seconds between {rebalance}s;
     *        must be non-zero (audit B5).
     */
    function setCadence(
        bytes32 poolId,
        uint256 minDeployInterval_,
        uint256 minRebalanceInterval_
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (!whitelistedPool[poolId]) {
            revert PoolNotWhitelisted(poolId);
        }
        // B5: a zero interval would disable the keeper spam floor.
        if (minDeployInterval_ == 0 || minRebalanceInterval_ == 0) {
            revert DeployCadenceRequired(poolId);
        }

        minDeployInterval[poolId] = minDeployInterval_;
        minRebalanceInterval[poolId] = minRebalanceInterval_;

        emit CadenceSet(
            poolId, minDeployInterval_, minRebalanceInterval_
        );
    }

    // ──────────────────── Guardian / Admin Control ───────────────────

    /**
     * @notice Pause every keeper trigger in an emergency.
     * @dev `GUARDIAN_ROLE`, held by `EmergencyGuardian` — satisfies the
     *      {IPausable} interface so the guardian can pause this contract
     *      with a single guardian signature.
     */
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Resume keeper triggers after an emergency.
     * @dev `DEFAULT_ADMIN_ROLE` (the timelock), not the guardian — a
     *      compromised guardian cannot undo its own halt. Matches the
     *      OmniTreasuryV2 pause/unpause split.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ─────────── Keeper Triggers (KEEPER_ROLE) + pokeObservation ──────────

    /**
     * @notice Advance a managed pool's TWAP window, refreshing its
     *         stored last-completed-window average if the window has
     *         matured.
     * @dev Audit A1 / A2 / B2. PERMISSIONLESS and GRIEF-PROOF:
     *
     *      - If the current window has run less than `minTwapWindow`
     *        seconds, this call is a SILENT NO-OP — it stores nothing,
     *        emits nothing, and wastes only the caller's gas. A griefer
     *        spamming pokes every block therefore changes no state and
     *        cannot keep any window "perpetually immature": the stored
     *        average and the anchor are untouched.
     *      - If the window HAS matured (`>= minTwapWindow`), the call
     *        computes the window's UQ112x112 time-weighted average,
     *        stores it as `price{0,1}AverageUQ`, and advances the anchor
     *        to the current block. A griefer poking exactly at maturity
     *        just stores a valid average and advances the anchor — also
     *        harmless.
     *      - On the FIRST ever poke for a pool (no anchor yet), the call
     *        only sets the anchor; no average is stored. The keeper
     *        runbook then waits `minTwapWindow` and pokes again to
     *        produce the first completed-window average.
     *
     *      Consumers ({_consultTwap} / {_twapPriceUQ}) read the STORED
     *      average, never a live `[anchor, now]` window — so a griefer
     *      cannot make a keeper action revert. The snapshot uses the
     *      pool's own UQ112x112 accumulators (see
     *      {_currentCumulativePrices}), never a caller-supplied number,
     *      so a poke can never bias the average toward an attacker's
     *      price.
     * @param poolId The RWAAMM pool ID to advance.
     */
    function pokeObservation(bytes32 poolId) external whenNotPaused {
        if (!whitelistedPool[poolId]) {
            revert PoolNotWhitelisted(poolId);
        }
        bool refreshed = _pokeObservation(poolId);

        // B2: only a real window-completing refresh emits an event; an
        // early no-op poke is silent so watchers can distinguish them.
        if (refreshed) {
            Observation memory obs = poolObservation[poolId];
            emit ObservationPoked(
                poolId,
                _msgSender(),
                obs.price0AverageUQ,
                obs.price1AverageUQ,
                obs.averageTimestamp
            );
        }
    }

    /**
     * @notice Deploy idle treasury liquidity into a managed pool.
     * @dev `KEEPER_ROLE`-gated (audit C-01) — keeper triggers are an
     *      allowlist, not permissionless. The on-chain policy further
     *      constrains the outcome:
     *
     *      1. The pool must be whitelisted and its policy `enabled`.
     *      2. POLManager must itself be a treasury `polTargets` entry
     *         (audit M-01) — asserted up front.
     *      3. The pool's `minDeployInterval` cadence floor must have
     *         elapsed since the last {deploy} (audit A3) — a keeper
     *         cannot loop the per-call cap into a drain.
     *      4. The treasury's idle `token1` balance must be at least the
     *         pool's `minIdleToDeploy`, else reverts
     *         {IdleBelowThreshold} (deters dust deploys / gas griefing).
     *      5. The deploy amount is capped:
     *         `min(idle, maxDeployPerCall, weight-budgeted share)`
     *         (audit C-01 / M-05) — a single call can never dump the
     *         whole idle balance into one pool.
     *      6. Half the capped amount is swapped `token1 -> token0` via
     *         OmniSwapRouter with a `minAmountOut` derived from the
     *         pool's TWAP, not a same-block spot quote (audit A1).
     *      7. Both sides are supplied to RWAAMM `addLiquidity` with the
     *         live, TWAP-equivalent `amount1Min` floor; the minted LP
     *         tokens and any residual dust are swept back to the
     *         treasury.
     *      8. END-TO-END VALUE BOUND (audit D1): {deploy} ADDS new
     *         capital, so the position's TWAP-valued worth must RISE by
     *         at least the deployed notional minus ONE `maxSlippageBps`
     *         band. The pre-deploy {_poolStableValue} is snapshotted,
     *         the post-deploy value taken after the redeploy, and
     *         `postValue - preValue >= _applySlippage(amountToDeploy)`
     *         is asserted. A sandwiched split swap yields less `token0`,
     *         dragging the realized principal — and thus the value
     *         gained — below the band, reverting {DeployValueLoss}. This
     *         replaces the previously stacked swap-leg + add-leg bands
     *         (~2x `maxSlippageBps`) with a single end-to-end bound,
     *         matching the assertion {compound} already carries.
     *
     *      Funds never rest in this contract between transactions.
     * @param poolId The RWAAMM pool ID to deploy into.
     */
    function deploy(bytes32 poolId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
    {
        PoolPolicy memory policy = _requireEnabledPool(poolId);
        _requirePOLManagerIsTreasuryTarget();
        _requireDeployCadence(poolId);

        // Idle balance is whatever sits in the treasury for token1.
        uint256 idle = IERC20(policy.token1).balanceOf(TREASURY_ADDRESS);
        if (idle < policy.minIdleToDeploy) {
            revert IdleBelowThreshold(idle, policy.minIdleToDeploy);
        }
        if (idle == 0) revert NothingToDo();

        // C-01 / M-05: size the commit — never the whole idle balance.
        uint256 amountToDeploy = _deployableAmount(poolId, policy, idle);
        if (amountToDeploy == 0) revert NothingToDo();

        // D1: TWAP-valued worth of the position BEFORE adding capital.
        uint256 preValue = _poolStableValue(poolId, policy);

        _deployInternal(poolId, policy, amountToDeploy);

        // D1: one end-to-end bound across the whole swap->add chain.
        // Deploy adds `amountToDeploy` of token1 notional, so the
        // position's TWAP-valued worth must have risen by at least that
        // notional minus a single `maxSlippageBps` band. The post value
        // can never be below the pre value when capital is added (the
        // realized principal counters only increment), but the
        // subtraction is guarded against underflow defensively.
        uint256 postValue = _poolStableValue(poolId, policy);
        if (postValue < preValue) {
            revert DeployValueLoss(0, _applySlippage(amountToDeploy));
        }
        uint256 valueGained = postValue - preValue;
        uint256 minValueGained = _applySlippage(amountToDeploy);
        // solhint-disable-next-line gas-strict-inequalities
        if (valueGained < minValueGained) {
            revert DeployValueLoss(valueGained, minValueGained);
        }

        // A1 / A2: this call consumed the pool's TWAP (the split swap
        // and, when weight-budgeted, the valuation); refresh the
        // observation so the next window starts fresh.
        _pokeObservation(poolId);
    }

    /**
     * @notice Harvest accrued LP fees from a managed pool, returning the
     *         fee surplus to the treasury and atomically redeploying the
     *         principal.
     * @dev `KEEPER_ROLE`-gated (audit C-01). RWAAMM accrues LP fees as a
     *      donation that grows pool reserves. This implementation
     *      realizes fees as a full burn-then-redeploy that is ATOMIC in
     *      the single call (audit C-02 / H-04):
     *
     *      1. snapshot the deployed principal BEFORE withdrawing
     *         (audit C-02 — fixes the read-after-zero corruption);
     *      2. burn the whole LP position with slippage-bounded
     *         `amount0Min`/`amount1Min` (audit C-01);
     *      3. book `feeN = redeemedN > snapshotPrincipalN ?
     *         redeemedN - snapshotPrincipalN : 0` — clamped at 0 so a
     *         below-principal redemption never inflates the cumulative
     *         counters;
     *      4. atomically redeploy the principal portion back into the
     *         pool in the SAME call — the position is never left
     *         undeployed across transactions (audit H-04). The fee
     *         surplus is left in the treasury.
     *
     *      Cadence: gated by the pool's `minHarvestInterval` against
     *      `lastHarvestTimestamp` (audit C-02 / L-02) so the action
     *      cannot be spammed to grief the position.
     *
     *      Audit D1 — end-to-end value conservation: {harvest} is a
     *      withdraw-then-redeploy, value-conserving minus execution
     *      slippage, exactly like {compound}. Left unchecked, its
     *      withdraw + split-swap + add legs each carry their own
     *      `maxSlippageBps` band that can silently stack to ~2x the
     *      headline tolerance. This function therefore snapshots the
     *      pool's TWAP-valued position worth BEFORE the harvest and
     *      asserts, AFTER the redeploy, that the new position's
     *      TWAP-valued worth is at least
     *      `preValue * (BPS_DENOMINATOR - maxSlippageBps)
     *      / BPS_DENOMINATOR` — ONE bound over the whole chain. The
     *      harvested fee surplus is left in the treasury (NOT
     *      redeployed) and {_poolStableValue} values tracked principal
     *      only, so both `preValue` and `postValue` exclude fees: the
     *      comparison is principal-vs-principal and a multi-leg leak
     *      beyond the band reverts {HarvestValueLoss}.
     *
     *      No treasury allowance is required — `transferTokenToPOL` is a
     *      treasury-side push, not a pull. POLManager must hold
     *      `POL_DEPLOYER_ROLE` and its own address must be a `polTargets`
     *      entry (asserted by {_requirePOLManagerIsTreasuryTarget}).
     * @param poolId The RWAAMM pool ID to harvest.
     */
    function harvest(bytes32 poolId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
    {
        PoolPolicy memory policy = _requireEnabledPool(poolId);
        _requirePOLManagerIsTreasuryTarget();
        _requireHarvestCadence(poolId, policy);

        // D1: TWAP-valued worth of the position BEFORE the operation.
        uint256 preValue = _poolStableValue(poolId, policy);

        // Both principal sides are needed for the value-conserving
        // two-sided redeploy below.
        (
            uint256 feeToken0,
            uint256 feeToken1,
            uint256 principal0,
            uint256 principal1
        ) = _harvestInternal(poolId, policy);

        emit FeesHarvested(
            poolId, _msgSender(), feeToken0, feeToken1
        );

        // H-04 / C-02: atomically redeploy the principal in the SAME
        // call. The whole LP position was redeemed to the treasury by
        // _harvestInternal as `principal0` token0 + `principal1` token1
        // (in the pool's own ratio). Redeploy BOTH sides directly via
        // {_redeployBothSides} — no split swap is needed because the
        // burn already returned both sides in pool proportion. The fee
        // surplus (`feeToken0`/`feeToken1`) stays in the treasury.
        //
        // FIX (functional bug found by GATE-1 testing): the prior
        // implementation redeployed only the `principal1` token1 side
        // via `_deployInternal`, which swaps half to token0 — that
        // rebuilds a position worth only `principal1` in token1
        // numeraire (~half the pre-harvest value), abandoning the
        // redeemed `principal0` token0 idle in the treasury and making
        // every honest harvest revert {HarvestValueLoss}.
        //
        // A5: the redeploy amounts are this position's OWN tracked
        // principal — not the wallet's full balance. The clamps below
        // can only REDUCE them, never pull in extra balance, so the
        // redeploy stays scoped to POL float by construction.
        _redeployBothSides(poolId, policy, principal0, principal1);

        // D1: one end-to-end bound across the whole withdraw->
        // redeploy chain. The post-redeploy position (valued on the
        // same TWAP observation, principal only) must not have lost
        // more than `maxSlippageBps` versus the pre-harvest position.
        uint256 postValue = _poolStableValue(poolId, policy);
        uint256 minPostValue = _applySlippage(preValue);
        // solhint-disable-next-line gas-strict-inequalities
        if (postValue < minPostValue) {
            revert HarvestValueLoss(postValue, minPostValue);
        }

        // A1 / A2: this call consumed the pool's TWAP via the redeploy
        // swap; refresh the observation so the next window starts fresh.
        _pokeObservation(poolId);
    }

    /**
     * @notice Harvest accrued LP fees and redeploy BOTH the principal
     *         and the realized fees, atomically, in one call.
     * @dev `KEEPER_ROLE`-gated (audit C-01). Identical to {harvest}
     *      except the fee surplus is redeployed alongside the principal
     *      rather than left idle — the protocol's LP position compounds.
     *      The redeploy is atomic and unconditional (audit H-04): there
     *      is no best-effort `minIdleToDeploy` gate that could strand
     *      principal as idle cash. Same `minHarvestInterval` cadence
     *      guard as {harvest}.
     *
     *      Audit A4 — end-to-end value conservation: {compound} crosses
     *      roughly four AMM legs (withdraw + the {_deployInternal} swap
     *      + addLiquidity), each with its own per-leg `maxSlippageBps`
     *      band; left unchecked, the worst-case tolerated loss
     *      compounds well past the headline 5%. This function therefore
     *      snapshots the pool's TWAP-valued position worth BEFORE the
     *      harvest and asserts, AFTER the redeploy, that the new
     *      position's TWAP-valued worth is at least
     *      `preValue * (BPS_DENOMINATOR - maxSlippageBps)
     *      / BPS_DENOMINATOR`. One bound on the whole operation — the
     *      per-leg bands can no longer silently stack. Realized fees
     *      only ADD to the post value, so a healthy compound clears the
     *      bound comfortably; a multi-leg slippage leak beyond the band
     *      reverts {CompoundValueLoss}.
     *
     *      Pre/post values are taken against the SAME stored
     *      {Observation} (the post-action refresh runs last), so the
     *      comparison is apples-to-apples; the observation is then
     *      refreshed so the next TWAP window starts fresh.
     * @param poolId The RWAAMM pool ID to compound.
     */
    function compound(bytes32 poolId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
    {
        PoolPolicy memory policy = _requireEnabledPool(poolId);
        _requirePOLManagerIsTreasuryTarget();
        _requireHarvestCadence(poolId, policy);

        // A4: TWAP-valued worth of the position BEFORE the operation.
        uint256 preValue = _poolStableValue(poolId, policy);

        // Both principal sides are needed for the value-conserving
        // two-sided redeploy below.
        (
            uint256 feeToken0,
            uint256 feeToken1,
            uint256 principal0,
            uint256 principal1
        ) = _harvestInternal(poolId, policy);

        emit FeesHarvested(
            poolId, _msgSender(), feeToken0, feeToken1
        );

        // H-04: redeploy principal + realized fees, atomically and
        // unconditionally. The whole position was redeemed to the
        // treasury as `principal0 + feeToken0` token0 and
        // `principal1 + feeToken1` token1; redeploy BOTH sides via
        // {_redeployBothSides}. Unlike {harvest}, the realized fees
        // are folded into the redeploy so the position compounds.
        //
        // FIX (functional bug found by GATE-1 testing): the prior
        // implementation redeployed only the token1 side via
        // `_deployInternal`, abandoning the redeemed token0 and making
        // every honest compound revert {CompoundValueLoss}.
        _redeployBothSides(
            poolId,
            policy,
            principal0 + feeToken0,
            principal1 + feeToken1
        );

        // A4: one end-to-end bound across the whole withdraw->
        // redeploy chain. The post-redeploy position (valued on the
        // same TWAP observation) must not have lost more than
        // `maxSlippageBps` versus the pre-compound position.
        uint256 postValue = _poolStableValue(poolId, policy);
        uint256 minPostValue = _applySlippage(preValue);
        // solhint-disable-next-line gas-strict-inequalities
        if (postValue < minPostValue) {
            revert CompoundValueLoss(postValue, minPostValue);
        }

        // A1 / A2: this call consumed the pool's TWAP; refresh the
        // observation so the next window starts from the post-action
        // state.
        _pokeObservation(poolId);
    }

    /**
     * @notice Rebalance a pool position toward its target weight.
     * @dev `KEEPER_ROLE`-gated (audit C-01). Compares the pool's
     *      realized POL weight — its LP position valued in the paired-
     *      stable (`token1`) side as a share of the same valuation
     *      summed across every managed pool (audit H-02 — a common
     *      numeraire, not raw LP-token counts) — against
     *      `targetWeightBps`. If the drift exceeds `rebalanceDriftBps`,
     *      the over-weighted excess LP is withdrawn back to the treasury
     *      as idle principal (which a later {deploy} can redistribute).
     *      If the drift is within tolerance, reverts
     *      {DriftWithinTolerance} so the keeper transaction cleanly
     *      no-ops.
     *
     *      Rebalancing only ever withdraws toward the treasury — it
     *      never moves funds between pools directly, keeping every hop
     *      auditable as a treasury credit.
     *
     *      Cadence: gated by the pool's `minRebalanceInterval` against
     *      `lastRebalanceTimestamp` (audit A3) so the trigger cannot be
     *      spammed to grief the position.
     * @param poolId The RWAAMM pool ID to rebalance.
     */
    function rebalance(bytes32 poolId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(KEEPER_ROLE)
    {
        PoolPolicy memory policy = _requireEnabledPool(poolId);
        _requirePOLManagerIsTreasuryTarget();
        _requireRebalanceCadence(poolId);

        PoolAccounting storage acct = poolAccounting[poolId];
        uint256 lpHeld = acct.lpTokensHeld;
        if (lpHeld == 0) revert NothingToDo();

        uint256 realizedBps = _realizedWeightBps(poolId);
        uint256 targetBps = policy.targetWeightBps;
        uint256 driftBps = realizedBps > targetBps
            ? realizedBps - targetBps
            : targetBps - realizedBps;

        // Non-strict: drift exactly at the tolerance is "within"
        // tolerance and must not trigger a rebalance.
        // solhint-disable-next-line gas-strict-inequalities
        if (driftBps <= policy.rebalanceDriftBps) {
            revert DriftWithinTolerance(
                driftBps, policy.rebalanceDriftBps
            );
        }

        // Only over-weight positions are trimmed; under-weight pools
        // are corrected by the next {deploy}, which routes idle funds.
        // Non-strict: a position exactly at target is not over-weight.
        // solhint-disable-next-line gas-strict-inequalities
        if (realizedBps <= targetBps) revert NothingToDo();

        // Withdraw the over-weight excess LP fraction to the treasury.
        uint256 excessLp = (lpHeld * driftBps) / BPS_DENOMINATOR;
        if (excessLp == 0) revert NothingToDo();

        _withdrawLiquidity(poolId, policy, excessLp);

        // A3: stamp the rebalance so the next call is cadence-gated.
        // solhint-disable-next-line not-rely-on-time
        lastRebalanceTimestamp[poolId] = block.timestamp;

        // A1 / A2: this rebalance consumed the pool's TWAP via
        // _realizedWeightBps; refresh the observation so the next
        // window starts fresh from this post-action state.
        _pokeObservation(poolId);

        emit PositionRebalanced(poolId, _msgSender(), excessLp);
    }

    // ──────────────────────── View Functions ─────────────────────────

    /**
     * @notice Get the number of pools under POLManager management.
     * @return count The managed pool count.
     */
    function poolCount() external view returns (uint256 count) {
        count = poolIds.length;
    }

    /**
     * @notice Read the full accounting record for a managed pool.
     * @param poolId The RWAAMM pool ID.
     * @return accounting The pool's {PoolAccounting} record.
     */
    function getPoolAccounting(
        bytes32 poolId
    ) external view returns (PoolAccounting memory accounting) {
        accounting = poolAccounting[poolId];
    }

    /**
     * @notice Read the full policy for a managed pool.
     * @param poolId The RWAAMM pool ID.
     * @return policy The pool's {PoolPolicy} record.
     */
    function getPoolPolicy(
        bytes32 poolId
    ) external view returns (PoolPolicy memory policy) {
        policy = poolPolicy[poolId];
    }

    // ─────────────────────── Internal Helpers ────────────────────────

    /**
     * @notice Realize a pool's LP fees back to the treasury and return
     *         the fee/principal split.
     * @dev Shared by {harvest} and {compound}. Audit C-02:
     *
     *      1. The deployed principal is SNAPSHOTTED into memory BEFORE
     *         {_withdrawLiquidity} is called — {_withdrawLiquidity}
     *         zeroes the storage principal counters, so reading them
     *         afterward (the original bug) booked the entire principal
     *         as fee.
     *      2. The whole LP position is redeemed with slippage-bounded
     *         minimums (audit C-01).
     *      3. `feeN = redeemedN > snapshotPrincipalN ?
     *         redeemedN - snapshotPrincipalN : 0` — clamped at 0 so a
     *         below-principal (impermanent-loss) redemption can never
     *         inflate `cumulativeFeesHarvested*`.
     *
     *      The caller ({harvest} / {compound}) is responsible for the
     *      atomic redeploy of the principal in the same transaction.
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy (token addresses).
     * @return feeToken0 `token0` fee surplus credited to the treasury.
     * @return feeToken1 `token1` fee surplus credited to the treasury.
     * @return principal0 Snapshotted `token0` principal before withdraw.
     * @return principal1 Snapshotted `token1` principal before withdraw.
     */
    function _harvestInternal(
        bytes32 poolId,
        PoolPolicy memory policy
    )
        internal
        returns (
            uint256 feeToken0,
            uint256 feeToken1,
            uint256 principal0,
            uint256 principal1
        )
    {
        PoolAccounting storage acct = poolAccounting[poolId];
        uint256 lpHeld = acct.lpTokensHeld;
        if (lpHeld == 0) revert NothingToDo();

        // C-02: snapshot principal BEFORE the withdraw zeroes it.
        principal0 = acct.deployedPrincipalToken0;
        principal1 = acct.deployedPrincipalToken1;

        // Redeem the whole position (slippage-bounded inside).
        (uint256 got0, uint256 got1) =
            _withdrawLiquidity(poolId, policy, lpHeld);

        // C-02: fee = redeemed surplus over snapshotted principal,
        // clamped at 0 so impermanent loss never inflates the counters.
        feeToken0 = got0 > principal0 ? got0 - principal0 : 0;
        feeToken1 = got1 > principal1 ? got1 - principal1 : 0;

        // M-04: cumulative counters are uint256 — no narrowing, no
        // overflow-brick. Solidity 0.8 still reverts on a genuine
        // 2^256 overflow, which is unreachable for any real treasury.
        acct.cumulativeFeesHarvestedToken0 += feeToken0;
        acct.cumulativeFeesHarvestedToken1 += feeToken1;
        // solhint-disable-next-line not-rely-on-time
        acct.lastHarvestTimestamp = uint64(block.timestamp);

        // Return actual burn proceeds (not snapshotted principal) so
        // harvest()/compound() redeploy what was actually received,
        // not what was snapshotted before impermanent loss.
        principal0 = got0;
        principal1 = got1;
    }

    /**
     * @notice Deploy a known `token1` amount into a pool.
     * @dev Shared by {deploy}, {harvest} and {compound}. The caller has
     *      already sized `amountToDeploy` (capped via {_deployableAmount}
     *      or set to a position's own redeployable principal). Half is
     *      swapped `token1 -> token0` with a slippage-bounded
     *      `minAmountOut`; both sides are supplied to the AMM with the
     *      live, TWAP-equivalent `amount1Min` floor; LP tokens and dust
     *      are swept to the treasury.
     *
     *      LIQ-INFO-1 — REALIZED accounting: the `token0` side of the
     *      recorded principal is the REALIZED swap output `swapOut`
     *      returned by {_swapExactIn} (the exact `token0` POLManager
     *      received), and both `token0`/`token1` principal counters are
     *      incremented by the REALIZED `(realized0, realized1)` amounts
     *      the RWAAMM actually deposited — never a pre-swap estimate or
     *      the amounts merely supplied. The RWAAMM may take ratio-dust
     *      less on one side and sweep the remainder back; recording the
     *      realized amounts keeps {_poolStableValue} an exact basis for
     *      the D1 end-to-end value assertion in the calling action.
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy (token addresses).
     * @param amountToDeploy The `token1` amount to commit, non-zero.
     */
    function _deployInternal(
        bytes32 poolId,
        PoolPolicy memory policy,
        uint256 amountToDeploy
    ) internal {
        TREASURY.transferTokenToPOL(
            policy.token1, address(this), amountToDeploy
        );

        uint256 half = amountToDeploy / 2;
        // LIQ-INFO-1: `swapOut` is the REALIZED token0 received from the
        // `token1 -> token0` split swap, not a pre-swap estimate.
        uint256 swapOut = _swapExactIn(
            poolId, policy.token1, policy.token0, half
        );
        uint256 amount1Supplied = amountToDeploy - half;

        // LIQ-INFO-1: `realized0`/`realized1` are the amounts the RWAAMM
        // actually deposited (it may take ratio-dust less on one side).
        (
            uint256 realized0,
            uint256 realized1,
            uint256 lpMinted
        ) = _addLiquidity(policy, swapOut, amount1Supplied);

        PoolAccounting storage acct = poolAccounting[poolId];
        acct.deployedPrincipalToken0 += _toUint128(realized0);
        acct.deployedPrincipalToken1 += _toUint128(realized1);
        acct.lpTokensHeld += _toUint128(lpMinted);
        // solhint-disable-next-line not-rely-on-time
        acct.lastDeployTimestamp = uint64(block.timestamp);

        address poolAddr = RWA_AMM.getPool(policy.token0, policy.token1);
        _sweepToTreasury(poolAddr);
        _sweepToTreasury(policy.token0);
        _sweepToTreasury(policy.token1);

        emit LiquidityDeployed(
            poolId, _msgSender(), realized0, realized1, lpMinted
        );
    }

    /**
     * @notice Redeploy a previously-redeemed two-sided position back
     *         into a pool, no split swap.
     * @dev Shared by {harvest} and {compound}. Unlike {_deployInternal}
     *      — which takes a single-asset `token1` input and swaps half
     *      to `token0` — this helper pulls BOTH the `token0` and
     *      `token1` sides the {harvest}/{compound} burn already
     *      redeemed to the treasury (in the pool's own ratio) and adds
     *      them straight to the AMM. No swap means no swap-fee or
     *      price-impact leak, so an honest redeploy conserves the
     *      pre-harvest position value end-to-end (the D1 / A4
     *      `_poolStableValue` assertion in the caller verifies this).
     *
     *      Each amount is clamped to the treasury's live balance
     *      (audit A5 — the redeploy is scoped to this position's own
     *      tracked principal; the clamp can only reduce it). A zero
     *      pair is a silent no-op. LP tokens and any ratio-dust are
     *      swept back to the treasury, so POLManager retains nothing
     *      between transactions (non-custodial invariant).
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy (token addresses in pool order).
     * @param amount0 The `token0` amount to redeploy.
     * @param amount1 The `token1` amount to redeploy.
     */
    function _redeployBothSides(
        bytes32 poolId,
        PoolPolicy memory policy,
        uint256 amount0,
        uint256 amount1
    ) internal {
        uint256 bal0 = IERC20(policy.token0).balanceOf(TREASURY_ADDRESS);
        uint256 bal1 = IERC20(policy.token1).balanceOf(TREASURY_ADDRESS);
        if (amount0 > bal0) amount0 = bal0;
        if (amount1 > bal1) amount1 = bal1;
        if (amount0 == 0 || amount1 == 0) return;

        TREASURY.transferTokenToPOL(
            policy.token0, address(this), amount0
        );
        TREASURY.transferTokenToPOL(
            policy.token1, address(this), amount1
        );

        // LIQ-INFO-1: `realized0`/`realized1` are the amounts the RWAAMM
        // actually deposited (it may take ratio-dust less on one side).
        (
            uint256 realized0,
            uint256 realized1,
            uint256 lpMinted
        ) = _addLiquidity(policy, amount0, amount1);

        PoolAccounting storage acct = poolAccounting[poolId];
        acct.deployedPrincipalToken0 += _toUint128(realized0);
        acct.deployedPrincipalToken1 += _toUint128(realized1);
        acct.lpTokensHeld += _toUint128(lpMinted);
        // solhint-disable-next-line not-rely-on-time
        acct.lastDeployTimestamp = uint64(block.timestamp);

        address poolAddr = RWA_AMM.getPool(policy.token0, policy.token1);
        _sweepToTreasury(poolAddr);
        _sweepToTreasury(policy.token0);
        _sweepToTreasury(policy.token1);

        emit LiquidityDeployed(
            poolId, _msgSender(), realized0, realized1, lpMinted
        );
    }

    /**
     * @notice Swap an exact input amount through the OmniSwapRouter
     *         with a TWAP-anchored, slippage-bounded `minAmountOut`.
     * @dev Audit A1 / H-01:
     *
     *      - `minAmountOut` is derived from the pool's TIME-WEIGHTED
     *        AVERAGE PRICE over `[storedObservation, now]` — NOT from a
     *        same-transaction `getQuote` spot quote. The original C-01
     *        fix referenced `getQuote`, whose output is pure
     *        spot-reserve constant-product math; an attacker who
     *        flash-skews the pool reserves in the same block moves both
     *        `getQuote` and the realized fill identically, so the
     *        slippage band compared two attacker-controlled numbers and
     *        gave no sandwich protection. {_consultTwap} references a
     *        price that PREDATES the transaction by at least
     *        `minTwapWindow` (30 min default) — a same-block flash-skew
     *        cannot move a 30-minute average, so the floor is now real.
     *      - `sources[0]` is populated with the governance-configured
     *        `rwaammSourceId`; a still-unset (`bytes32(0)`) source id
     *        reverts {SwapSourceNotConfigured} rather than silently
     *        routing through `liquiditySources[bytes32(0)]`.
     * @param poolId The RWAAMM pool ID whose TWAP anchors the floor.
     * @param tokenIn The token sold.
     * @param tokenOut The token bought.
     * @param amountIn The exact input amount.
     * @return amountOut The amount of `tokenOut` received.
     */
    function _swapExactIn(
        bytes32 poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        // H-01: the swap source must be configured.
        bytes32 sourceId = rwaammSourceId;
        if (sourceId == bytes32(0)) {
            revert SwapSourceNotConfigured();
        }

        // A1: derive a non-zero minimum from the pool's TWAP, not a
        // same-block spot quote. The TWAP predates this transaction by
        // at least `minTwapWindow`, so a sandwicher's same-block
        // reserve skew cannot drag the floor down to the manipulated
        // price.
        uint256 expectedOut = _consultTwap(poolId, tokenIn, amountIn);
        uint256 minAmountOut = _applySlippage(expectedOut);

        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        bytes32[] memory sources = new bytes32[](1);
        sources[0] = sourceId;

        IOmniSwapRouter.SwapResult memory result = SWAP_ROUTER.swap(
            IOmniSwapRouter.SwapParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: minAmountOut,
                path: path,
                sources: sources,
                // solhint-disable-next-line not-rely-on-time
                deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
                recipient: address(this)
            })
        );
        amountOut = result.amountOut;

        // Clear any residual router allowance (defense in depth).
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), 0);

        // Defense in depth: the router already enforces minAmountOut,
        // but assert it here too so the slippage bound is local and
        // explicit.
        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }
    }

    /**
     * @notice Supply both sides of a pair to the RWAAMM with TWAP-
     *         anchored, slippage-bounded protection on the add leg, and
     *         return the REALIZED deposit amounts.
     * @dev Audit C-01 / M-02 / C1-C2 / D2 / LIQ-INFO-1:
     *
     *      - `amount1Min` passed to RWAAMM is the slippage-bounded
     *        `token1` input. Because `token1` is the POL numeraire, the
     *        nominal `token1` amount IS its own fair value, so
     *        `_applySlippage(amount1)` is a TWAP-equivalent floor; it is
     *        LIVE and load-bearing.
     *      - THE TOKEN0-SIDE BOUND (audit D2 — corrected): RWAAMM's
     *        `_calcOptimalAmounts` has two branches. For a `token1`-side
     *        deploy whose supplied ratio sits at or above the live pool
     *        ratio — the branch this contract's split deploy always
     *        takes — it returns `(amount0Desired, amount1Optimal)` and
     *        compares ONLY `amount1Min`; `amount0Min` is never read on
     *        that path. A TWAP-derived `amount0Min` argument was
     *        therefore dead code on the executing path and has been
     *        removed (audit D2). The token0 side is instead bounded by
     *        two live, effective guards: (1) the swap-leg TWAP floor in
     *        {_swapExactIn}, which already caps how little `token0` the
     *        `token1 -> token0` split can yield; and (2) the end-to-end
     *        `_poolStableValue` pre/post assertion in {deploy} /
     *        {harvest} / {compound} (audit D1), which reverts the whole
     *        operation if the recorded principal — now the REALIZED
     *        principal, see below — falls outside the single
     *        `maxSlippageBps` band. RWAAMM's `removeLiquidity` is purely
     *        proportional, so a zero `amount0Min` there cannot be
     *        loss-sandwiched; passing `0` for the AMM `amount0Min`
     *        argument here is sound.
     *      - LIQ-INFO-1 — REALIZED principal: RWAAMM may deposit
     *        ratio-dust less on one side than the amounts supplied and
     *        sweep the remainder back. This function returns the
     *        AMM-reported realized `(realizedAmount0, realizedAmount1)`
     *        so {_deployInternal} records EXACT principal, making
     *        {_poolStableValue} an exact basis for the D1 assertion.
     *      - `onBehalfOf` is the treasury address (audit M-02): for a
     *        protocol-owned deposit the compliance subject the RWAAMM
     *        must check is the fund owner (the treasury), not
     *        `address(0)` (which would resolve to POLManager, a
     *        contract with no compliance registration).
     *
     *      Same pool observation: the TWAP read here is the same stored
     *      completed-window average the surrounding keeper action
     *      already consulted in the call — {_pokeObservation} runs only
     *      at end-of-call, so no mid-operation re-poke occurs.
     * @param policy The pool's policy (token addresses in pool order).
     * @param amount0 `token0` amount to supply.
     * @param amount1 `token1` amount to supply.
     * @return realizedAmount0 `token0` actually deposited by the RWAAMM.
     * @return realizedAmount1 `token1` actually deposited by the RWAAMM.
     * @return liquidity LP tokens minted to this contract.
     */
    function _addLiquidity(
        PoolPolicy memory policy,
        uint256 amount0,
        uint256 amount1
    )
        internal
        returns (
            uint256 realizedAmount0,
            uint256 realizedAmount1,
            uint256 liquidity
        )
    {
        address token0 = policy.token0;
        address token1 = policy.token1;

        IERC20(token0).forceApprove(address(RWA_AMM), amount0);
        IERC20(token1).forceApprove(address(RWA_AMM), amount1);

        // C1-C2 / D2: only `amount1Min` is a live AMM-side bound — it is
        // TWAP-equivalent because `token1` is the numeraire. The token0
        // side is NOT bounded by an AMM `amount0Min` (the executing
        // `_calcOptimalAmounts` branch never compares it); it is bounded
        // by the swap-leg TWAP floor in {_swapExactIn} and the D1
        // end-to-end value assertion in the calling keeper action. `0`
        // for the AMM `amount0Min` argument is therefore sound — and
        // proportional `removeLiquidity` cannot be loss-sandwiched.
        uint256 amount1Min = _applySlippage(amount1);

        // M-02: onBehalfOf = treasury (the compliance subject / fund
        // owner), not address(0). LIQ-INFO-1: the realized
        // `(amount0, amount1)` returns ARE now consumed — the principal
        // accounting in {_deployInternal} records the exact amounts the
        // RWAAMM deposited, not the amounts POLManager supplied.
        (realizedAmount0, realizedAmount1, liquidity) = RWA_AMM.addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            0,
            amount1Min,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + SWAP_DEADLINE_BUFFER,
            TREASURY_ADDRESS
        );

        IERC20(token0).forceApprove(address(RWA_AMM), 0);
        IERC20(token1).forceApprove(address(RWA_AMM), 0);

        if (liquidity == 0) revert SlippageExceeded(liquidity, 1);
    }

    /**
     * @notice Withdraw an LP fraction from a pool back to the treasury
     *         with TWAP-anchored, slippage-bounded protection.
     * @dev Audit C-01 / H-03 / C1-C2: pulls `lpAmount` LP tokens from
     *      the treasury via `transferTokenToPOL`, approves the AMM,
     *      calls {IRWAAMM-removeLiquidity}, then sweeps the redeemed
     *      assets to the treasury. `policy.token0`/`token1` are in the
     *      RWAPool's own order (audit H-03) so the per-side accounting
     *      is correct.
     *
     *      Audit C1-C2 — proportional removal is not loss-sandwichable:
     *      `RWAPool.removeLiquidity` is purely proportional. POLManager
     *      receives exactly `lpAmount / totalSupply` of EACH live
     *      reserve (`amountN = lpAmount * balanceN / totalSupply`).
     *      Valued at ANY fixed price, a sandwicher who skews the pool
     *      around the burn cannot make POLManager redeem LESS total
     *      value: by AM-GM, any reserve perturbation a swap or token
     *      donation causes can only RAISE the fixed-price value of the
     *      proportional `(reserve0, reserve1)` bundle. There is no
     *      sandwich that extracts value from a proportional burn, so no
     *      post-operation value assertion is required.
     *
     *      Consequently the per-side minimums passed to RWAAMM are
     *      small fixed dust floors (`1` wei each) — just enough to
     *      reject a degenerate zero-return griefing edge — NOT values
     *      derived from live `getReserves()` or from the (now-removed)
     *      manipulable `_lpStableValue` primitive. This is the C1-C2
     *      fix: the earlier B1 path valued the burned LP via
     *      `_lpStableValue`, which read live `k = reserve0 * reserve1`
     *      and was movable in-block by a donation + permissionless
     *      `RWAPool.sync()`. That primitive is deleted.
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy (token addresses in pool order).
     * @param lpAmount LP tokens to burn.
     * @return amount0 `token0` redeemed and credited to the treasury.
     * @return amount1 `token1` redeemed and credited to the treasury.
     */
    function _withdrawLiquidity(
        bytes32 poolId,
        PoolPolicy memory policy,
        uint256 lpAmount
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (lpAmount == 0) return (0, 0);

        address poolAddr = RWA_AMM.getPool(policy.token0, policy.token1);
        if (poolAddr == address(0)) revert ZeroAddress();

        // Pull LP tokens from the treasury into this contract.
        TREASURY.transferTokenToPOL(poolAddr, address(this), lpAmount);

        // C1-C2: proportional removal cannot be loss-sandwiched (see
        // NatSpec / AM-GM rationale above), so the AMM minimums are
        // fixed `1`-wei dust floors that only reject a degenerate
        // zero-return edge — never live-reserve-derived values.
        IERC20(poolAddr).forceApprove(address(RWA_AMM), lpAmount);
        (amount0, amount1) = RWA_AMM.removeLiquidity(
            policy.token0,
            policy.token1,
            lpAmount,
            1,
            1,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + SWAP_DEADLINE_BUFFER,
            TREASURY_ADDRESS
        );
        IERC20(poolAddr).forceApprove(address(RWA_AMM), 0);

        // Reduce accounting counters by the redeemed fraction.
        // Non-strict `>=` is required: these are clamp-at-zero guards
        // that prevent an underflow revert if a counter ever lags the
        // redeemed amount (e.g. AMM optimal-ratio dust). Equality must
        // take the subtraction branch (result 0), not the literal 0
        // branch — both yield 0, so the non-strict form is correct and
        // a strict `>` would be a behavior-neutral micro-optimization
        // that obscures the underflow-guard intent.
        PoolAccounting storage acct = poolAccounting[poolId];
        /* solhint-disable gas-strict-inequalities */
        acct.lpTokensHeld = acct.lpTokensHeld >= _toUint128(lpAmount)
            ? acct.lpTokensHeld - _toUint128(lpAmount)
            : 0;
        acct.deployedPrincipalToken0 =
            acct.deployedPrincipalToken0 >= _toUint128(amount0)
                ? acct.deployedPrincipalToken0 - _toUint128(amount0)
                : 0;
        acct.deployedPrincipalToken1 =
            acct.deployedPrincipalToken1 >= _toUint128(amount1)
                ? acct.deployedPrincipalToken1 - _toUint128(amount1)
                : 0;
        /* solhint-enable gas-strict-inequalities */

        // Credit the redeemed assets to the treasury.
        _sweepToTreasury(policy.token0);
        _sweepToTreasury(policy.token1);
    }

    /**
     * @notice Forward this contract's entire balance of a token to the
     *         treasury.
     * @dev Called at the end of every keeper action so POLManager never
     *      retains funds between transactions (non-custodial invariant).
     *      A zero balance is a silent no-op.
     * @param token The token to sweep.
     */
    function _sweepToTreasury(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(TREASURY_ADDRESS, bal);
            emit DustSwept(token, bal);
        }
    }

    /**
     * @notice Advance a pool's TWAP window — Uniswap-V2
     *         `ExampleOracleSimple.update()` pattern (audit B2).
     * @dev Shared by the permissionless {pokeObservation} and by the
     *      post-action observation refresh run at the end of {deploy},
     *      {harvest}, {compound} and {rebalance}. Resolving the RWAPool
     *      address from the AMM keeps the contract free of hardcoded
     *      addresses.
     *
     *      Three cases, mirroring `ExampleOracleSimple`:
     *
     *      1. NO ANCHOR YET (`timestampLast == 0`): seed the anchor with
     *         the current cumulative prices and block timestamp. No
     *         average is produced — there is no window to average yet.
     *         Returns `false`.
     *      2. WINDOW STILL MATURING (`timeElapsed < minTwapWindow`):
     *         silent no-op. The anchor and stored averages are left
     *         exactly as they were, so a griefer's early poke cannot
     *         reset the window or perturb the stored average. Returns
     *         `false`.
     *      3. WINDOW MATURED (`timeElapsed >= minTwapWindow`): compute
     *         the window's UQ112x112 time-weighted average as
     *         `(currentCumulative - anchorCumulative) / timeElapsed`,
     *         store it as `price{0,1}AverageUQ`, stamp
     *         `averageTimestamp`, and advance the anchor to the current
     *         block. Returns `true`.
     *
     *      The cumulative subtraction is `unchecked`: the UQ112x112
     *      accumulators wrap mod 2^256 by design (Uniswap V2), so the
     *      wrapping subtraction recovers the true window delta.
     *      `timeElapsed` is taken mod 2^32 to stay correct across the
     *      32-bit timestamp wrap; division by it is safe because the
     *      matured branch is gated on `timeElapsed >= minTwapWindow >=
     *      MIN_TWAP_WINDOW_FLOOR > 0`.
     * @param poolId The RWAAMM pool ID to advance.
     * @return refreshed True if the window matured and the stored
     *         average was refreshed; false for an anchor-seed or an
     *         early no-op poke.
     */
    function _pokeObservation(
        bytes32 poolId
    ) internal returns (bool refreshed) {
        address poolAddr = RWA_AMM.getPoolAddress(poolId);
        if (poolAddr == address(0)) revert PoolDoesNotExist(poolId);

        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        ) = _currentCumulativePrices(IRWAPool(poolAddr));

        Observation storage obs = poolObservation[poolId];

        // Case 1: no anchor yet — seed it, produce no average.
        if (obs.timestampLast == 0) {
            obs.price0CumulativeLast = price0Cumulative;
            obs.price1CumulativeLast = price1Cumulative;
            obs.timestampLast = blockTimestamp;
            return false;
        }

        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - obs.timestampLast;
        }

        // Case 2: window still maturing — silent no-op (audit B2).
        if (timeElapsed < minTwapWindow) {
            return false;
        }

        // Case 3: window matured — compute and store the average, then
        // advance the anchor. Accumulator subtraction wraps by design.
        unchecked {
            obs.price0AverageUQ =
                (price0Cumulative - obs.price0CumulativeLast) /
                timeElapsed;
            obs.price1AverageUQ =
                (price1Cumulative - obs.price1CumulativeLast) /
                timeElapsed;
        }
        obs.price0CumulativeLast = price0Cumulative;
        obs.price1CumulativeLast = price1Cumulative;
        obs.timestampLast = blockTimestamp;
        obs.averageTimestamp = blockTimestamp;
        return true;
    }

    // ───────────────────── Internal View Helpers ─────────────────────

    /**
     * @notice Validate that a pool is whitelisted and keeper-enabled.
     * @dev Reverts {PoolNotWhitelisted} or {PoolDisabled} as
     *      appropriate. Returns the policy in memory so callers avoid a
     *      second SLOAD-heavy read.
     * @param poolId The RWAAMM pool ID.
     * @return policy The pool's policy.
     */
    function _requireEnabledPool(
        bytes32 poolId
    ) internal view returns (PoolPolicy memory policy) {
        if (!whitelistedPool[poolId]) {
            revert PoolNotWhitelisted(poolId);
        }
        policy = poolPolicy[poolId];
        if (!policy.enabled) revert PoolDisabled(poolId);
    }

    /**
     * @notice Assert that POLManager's own address is a treasury
     *         `polTargets` entry (audit M-01).
     * @dev Every keeper action routes treasury funds *to POLManager*
     *      via `transferTokenToPOL`, which requires POLManager to be a
     *      whitelisted POL target. This check turns an otherwise opaque
     *      `POLTargetNotAllowed` revert deep inside the treasury into a
     *      clear, self-describing failure surfaced up front.
     */
    function _requirePOLManagerIsTreasuryTarget() internal view {
        if (!TREASURY.isPOLTarget(address(this))) {
            revert POLManagerNotTreasuryTarget();
        }
    }

    /**
     * @notice Enforce the per-pool harvest cadence floor.
     * @dev Audit C-02 / L-02 / A6: wires the previously
     *      written-but-unread `lastHarvestTimestamp`. Reverts
     *      {HarvestCadenceNotElapsed} if less than `minHarvestInterval`
     *      seconds have passed since the last {harvest}/{compound} on
     *      this pool, so the action cannot be spammed to grief the
     *      position.
     *
     *      Audit A6 — two intentional, non-bypass behaviors:
     *        - `interval == 0`: a no-op early return. With the A6
     *          {setPolicy} guard, an ENABLED pool can never have
     *          `minHarvestInterval == 0`, and a disabled pool cannot
     *          reach this function ({_requireEnabledPool} reverts
     *          first). The branch therefore only ever triggers for an
     *          unreachable state; it is retained as defense-in-depth.
     *        - `last == 0`: the FIRST harvest on a pool is permitted.
     *          This is NOT a permanent bypass — {_harvestInternal}
     *          unconditionally writes `lastHarvestTimestamp =
     *          block.timestamp` on every harvest, so every call after
     *          the first is fully cadence-gated.
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy (for `minHarvestInterval`).
     */
    function _requireHarvestCadence(
        bytes32 poolId,
        PoolPolicy memory policy
    ) internal view {
        uint256 interval = policy.minHarvestInterval;
        if (interval == 0) return;

        uint256 last = poolAccounting[poolId].lastHarvestTimestamp;
        // First harvest is allowed; thereafter the floor is enforced
        // because _harvestInternal always stamps lastHarvestTimestamp.
        if (last == 0) return;

        uint256 nextAllowedAt = last + interval;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < nextAllowedAt) {
            revert HarvestCadenceNotElapsed(nextAllowedAt);
        }
    }

    /**
     * @notice Enforce the per-pool {deploy} cadence floor.
     * @dev Audit A3. Reverts {DeployCadenceNotElapsed} if less than
     *      `minDeployInterval` seconds have passed since the last
     *      {deploy}, read from `PoolAccounting.lastDeployTimestamp`.
     *      A zero interval, or a never-deployed pool
     *      (`lastDeployTimestamp == 0`), permits the call — but once a
     *      pool has been deployed, the floor is permanently enforced
     *      for every subsequent call.
     * @param poolId The RWAAMM pool ID.
     */
    function _requireDeployCadence(bytes32 poolId) internal view {
        uint256 interval = minDeployInterval[poolId];
        if (interval == 0) return;

        uint256 last = poolAccounting[poolId].lastDeployTimestamp;
        if (last == 0) return;

        uint256 nextAllowedAt = last + interval;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < nextAllowedAt) {
            revert DeployCadenceNotElapsed(nextAllowedAt);
        }
    }

    /**
     * @notice Enforce the per-pool {rebalance} cadence floor.
     * @dev Audit A3. Reverts {RebalanceCadenceNotElapsed} if less than
     *      `minRebalanceInterval` seconds have passed since the last
     *      {rebalance}, read from `lastRebalanceTimestamp`. A zero
     *      interval, or a never-rebalanced pool, permits the call;
     *      thereafter the floor is permanently enforced.
     * @param poolId The RWAAMM pool ID.
     */
    function _requireRebalanceCadence(bytes32 poolId) internal view {
        uint256 interval = minRebalanceInterval[poolId];
        if (interval == 0) return;

        uint256 last = lastRebalanceTimestamp[poolId];
        if (last == 0) return;

        uint256 nextAllowedAt = last + interval;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < nextAllowedAt) {
            revert RebalanceCadenceNotElapsed(nextAllowedAt);
        }
    }

    /**
     * @notice Compute a RWAPool's cumulative prices as of the current
     *         block, with the standard Uniswap-V2 in-block adjustment.
     * @dev Audit A1. The RWAPool only advances its
     *      `price0CumulativeLast` / `price1CumulativeLast` accumulators
     *      inside `_update` (on swap/mint/burn/sync). Between those
     *      events the stored accumulator is stale by
     *      `block.timestamp - blockTimestampLast` seconds. This helper
     *      replicates Uniswap V2's `UniswapV2OracleLibrary.
     *      currentCumulativePrices`: it reads the stored accumulator and
     *      reserves, then, if `block.timestamp > blockTimestampLast`,
     *      adds the missing `(reserveOther << 112) / reserveThis`
     *      contribution scaled by the elapsed seconds — producing a
     *      cumulative value that is accurate to *this* block. Without
     *      the adjustment, an observation and a later consult could both
     *      sit on the same stale accumulator and divide by a zero
     *      `timeElapsed`, or systematically under-measure the window.
     *
     *      All accumulator arithmetic is performed `unchecked`: the
     *      UQ112x112 accumulators are designed to overflow and wrap
     *      (mod 2^256), exactly as Uniswap V2 specifies — a later
     *      `currentCumulative - storedCumulative` subtraction wraps back
     *      to the correct delta. Reserves are `uint112`, so the
     *      `<< 112` shift cannot overflow `uint256`.
     * @param rwaPool The RWAPool to read.
     * @return price0Cumulative Token0 cumulative price, in-block-adjusted.
     * @return price1Cumulative Token1 cumulative price, in-block-adjusted.
     * @return blockTimestamp The current block timestamp (mod 2^32).
     */
    function _currentCumulativePrices(
        IRWAPool rwaPool
    )
        internal
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        )
    {
        // solhint-disable-next-line not-rely-on-time
        blockTimestamp = uint32(block.timestamp % 2 ** 32);

        price0Cumulative = rwaPool.price0CumulativeLast();
        price1Cumulative = rwaPool.price1CumulativeLast();

        (
            uint256 reserve0,
            uint256 reserve1,
            uint32 blockTimestampLast
        ) = rwaPool.getReserves();

        // In-block adjustment: if the pool has not been touched this
        // block, add the accumulator contribution for the elapsed gap
        // so the returned cumulative is current to this exact block.
        if (
            blockTimestamp != blockTimestampLast &&
            reserve0 != 0 &&
            reserve1 != 0
        ) {
            // `timeElapsed` wraps mod 2^32 exactly like the pool's own
            // `_update`; `unchecked` matches the Uniswap V2 pattern.
            unchecked {
                uint32 timeElapsed =
                    blockTimestamp - blockTimestampLast;
                price0Cumulative +=
                    ((reserve1 << UQ112X112_RESOLUTION) / reserve0) *
                    timeElapsed;
                price1Cumulative +=
                    ((reserve0 << UQ112X112_RESOLUTION) / reserve1) *
                    timeElapsed;
            }
        }
    }

    /**
     * @notice Read a pool's stored last-completed-window TWAP for one
     *         direction as a UQ112x112 fixed-point value.
     * @dev Audit A1 / A2 / B2. This reads the STORED
     *      `price{0,1}AverageUQ` produced by {_pokeObservation} for the
     *      last completed window — it does NOT compute a live
     *      `[anchor, now]` window. That is the B2 fix: because no live
     *      window is computed, a griefer spamming {pokeObservation}
     *      cannot manipulate `timeElapsed` to make this consult revert.
     *
     *      Two guards:
     *      - {NoCompletedWindow} if no window has ever completed
     *        (`averageTimestamp == 0`). First use requires the keeper to
     *        poke, wait `minTwapWindow`, and poke again.
     *      - {TwapStale} if the stored average is older than
     *        `minTwapWindow` (audit C3 — tightened from the previous
     *        `2 * minTwapWindow`). The stored average is itself the mean
     *        of a completed window of length >= `minTwapWindow`;
     *        requiring it to also be no older than `minTwapWindow`
     *        bounds the stale-arbitrage window — a real price move can
     *        be traded against a stale average for at most
     *        `minTwapWindow` seconds, not `2 * minTwapWindow`. This
     *        CANNOT be griefed into permanent failure: anyone (including
     *        the keeper, in its own action) may {pokeObservation}, and
     *        once `minTwapWindow` has elapsed since the anchor the next
     *        poke always matures the window and refreshes the average,
     *        regardless of how often a griefer poked early.
     *
     *      The stored average is itself a window of at least
     *      `minTwapWindow` seconds (enforced in {_pokeObservation}), so
     *      it carries the full manipulation resistance A1 requires — an
     *      attacker cannot move a 30-minute mean with a same-block
     *      reserve skew.
     *
     *      Audit D3 — ACCEPTED inherent staleness: this is a
     *      stored-average oracle (Uniswap-V2 `ExampleOracleSimple`
     *      pattern), so the value it returns is the mean of the LAST
     *      COMPLETED window and is inherently up to one `minTwapWindow`
     *      out of date — it lags the live price by at most
     *      `minTwapWindow` seconds even immediately after a refresh.
     *      This lag is structural to any stored-average TWAP and is
     *      ACCEPTED: the C3 staleness ceiling was already tightened
     *      from `2 * minTwapWindow` to `1 * minTwapWindow`, bounding the
     *      stale-arbitrage exposure to a single window. The accepted
     *      trade is deliberate — a price that predates the transaction
     *      is precisely what makes the floor immune to a same-block
     *      flash-skew (audit A1); a more current price would re-open
     *      the manipulation surface. No code change is made for D3.
     *
     *      `direction0to1 == true` returns the token0->token1 average;
     *      false returns token1->token0.
     * @param poolId The RWAAMM pool ID.
     * @param direction0to1 True for token0->token1, false for the
     *        inverse.
     * @return priceUQ The UQ112x112 average price (price * 2^112).
     */
    function _twapPriceUQ(
        bytes32 poolId,
        bool direction0to1
    ) internal view returns (uint256 priceUQ) {
        Observation memory obs = poolObservation[poolId];

        // B2: a stored completed-window average must exist.
        if (obs.averageTimestamp == 0) {
            revert NoCompletedWindow(poolId);
        }

        // C3: the stored average must not be stale. The ceiling is
        // `minTwapWindow` (tightened from `2 * minTwapWindow`), which
        // shrinks the stale-arbitrage window; a griefer cannot keep it
        // stale because any poke at/after window maturity refreshes it.
        // solhint-disable-next-line not-rely-on-time
        uint32 nowTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 averageAge;
        unchecked {
            averageAge = nowTimestamp - obs.averageTimestamp;
        }
        uint256 maxAge = minTwapWindow;
        if (averageAge > maxAge) {
            revert TwapStale(averageAge, maxAge);
        }

        priceUQ = direction0to1
            ? obs.price0AverageUQ
            : obs.price1AverageUQ;
    }

    /**
     * @notice Convert `amountIn` of `tokenIn` to `tokenOut` at the
     *         pool's time-weighted average price.
     * @dev Audit A1 / A2. Reads the UQ112x112 TWAP via {_twapPriceUQ}
     *      and applies it to `amountIn`. `tokenIn == token0` selects the
     *      token0->token1 average; otherwise token1->token0.
     *
     *      `priceUQ` is UQ112x112 (true price * 2^112); the conversion
     *      is `amountIn * priceUQ / 2^112`. The multiplication is kept
     *      CHECKED so a genuine 2^256 overflow reverts loudly rather
     *      than silently wrapping.
     * @param poolId The RWAAMM pool ID.
     * @param tokenIn The token being priced as input.
     * @param amountIn The input amount to convert.
     * @return amountOut The TWAP-implied output amount.
     */
    function _consultTwap(
        bytes32 poolId,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        address poolAddr = RWA_AMM.getPoolAddress(poolId);
        if (poolAddr == address(0)) revert PoolDoesNotExist(poolId);

        bool direction0to1 = IRWAPool(poolAddr).token0() == tokenIn;
        uint256 priceUQ = _twapPriceUQ(poolId, direction0to1);

        amountOut = (amountIn * priceUQ) >> UQ112X112_RESOLUTION;
    }

    /**
     * @notice Compute the `token1` amount a single {deploy} call may
     *         commit to a pool.
     * @dev Audit C-01 / M-05. The result is the minimum of:
     *
     *      - `idle` — the treasury's available `token1`;
     *      - `maxDeployPerCall` — the governance per-call cap, so one
     *        call can never move the whole idle balance;
     *      - the pool's target-weight budget — `targetWeightBps` of the
     *        total POL value (deployed-across-pools + idle) minus what
     *        the pool already holds, so {deploy} respects the
     *        governance-set allocation instead of dumping everything
     *        into the first pool.
     *
     *      A zero `targetWeightBps` means "no weight budget"; the
     *      `idle`/`maxDeployPerCall` caps still apply.
     *
     *      Audit A5 — what "idle" means: `TREASURY` is the dedicated
     *      `OmniTreasuryV2` POL wallet (see the {TREASURY} NatSpec and
     *      the contract-level "non-custodial invariant" note), NOT the
     *      general protocol treasury. By the protocol's POL design that
     *      wallet holds only protocol-owned liquidity float, so its
     *      entire `token1` balance is legitimately deployable POL — the
     *      `idle = balanceOf(POL wallet)` read is not commingled with
     *      non-POL funds. The redeploy paths in {harvest}/{compound}
     *      are additionally scoped to a position's OWN tracked float
     *      (`principal1` / `principal1 + feeToken1`); their `idle`
     *      clamp can only ever REDUCE the redeploy below that tracked
     *      amount, never pull in extra balance. If, operationally, the
     *      POL wallet were ever to hold non-POL balances, that would be
     *      a wallet-funding misconfiguration to fix at the treasury
     *      level — POLManager deliberately treats its managed wallet as
     *      POL-only and does not attempt to re-derive a "POL subset"
     *      from a commingled balance, which would be unverifiable
     *      on-chain.
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy.
     * @param idle The POL wallet's idle `token1` balance.
     * @return amount The capped `token1` amount to deploy.
     */
    function _deployableAmount(
        bytes32 poolId,
        PoolPolicy memory policy,
        uint256 idle
    ) internal view returns (uint256 amount) {
        amount = idle;

        // C-01 / M-05: hard per-call cap.
        uint256 perCallCap = maxDeployPerCall;
        if (perCallCap != 0 && amount > perCallCap) {
            amount = perCallCap;
        }

        // M-05: respect the pool's target-weight budget.
        uint256 weightBps = policy.targetWeightBps;
        if (weightBps != 0) {
            uint256 deployedValue = _totalDeployedStableValue();
            uint256 totalPolValue = deployedValue + idle;
            uint256 poolBudget =
                (totalPolValue * weightBps) / BPS_DENOMINATOR;
            uint256 poolValue = _poolStableValue(poolId, policy);
            uint256 headroom = poolBudget > poolValue
                ? poolBudget - poolValue
                : 0;
            if (amount > headroom) amount = headroom;
        }
    }

    /**
     * @notice Compute a pool's realized POL weight in basis points,
     *         valued in a common numeraire.
     * @dev Audit H-02: the weight is this pool's LP position valued in
     *      its paired-stable (`token1`) side, divided by the same
     *      valuation summed across every managed pool. Raw LP-token
     *      counts from different pools are non-fungible and not
     *      commensurable; valuing each position in its stable side
     *      gives a like-for-like comparison. Returns 0 when no managed
     *      pool holds any value.
     * @param poolId The RWAAMM pool ID.
     * @return weightBps The pool's realized weight in basis points.
     */
    function _realizedWeightBps(
        bytes32 poolId
    ) internal view returns (uint256 weightBps) {
        uint256 totalValue = _totalDeployedStableValue();
        if (totalValue == 0) return 0;

        uint256 thisValue =
            _poolStableValue(poolId, poolPolicy[poolId]);
        weightBps = (thisValue * BPS_DENOMINATOR) / totalValue;
    }

    /**
     * @notice Sum every managed pool's LP position value, each valued
     *         in its own paired-stable (`token1`) side.
     * @dev Audit H-02 helper. Pools with a zero LP position contribute
     *      nothing. The per-pool valuation uses {_poolStableValue}.
     * @return totalValue The summed stable-side valuation.
     */
    function _totalDeployedStableValue()
        internal
        view
        returns (uint256 totalValue)
    {
        uint256 len = poolIds.length;
        for (uint256 i; i < len; ++i) {
            bytes32 id = poolIds[i];
            totalValue += _poolStableValue(id, poolPolicy[id]);
        }
    }

    /**
     * @notice Value a pool's POL position in its paired-stable
     *         (`token1`) side, from POLManager's OWN tracked accounting
     *         and the TWAP — manipulation-free.
     * @dev Audit C1-C2 (supersedes the A2 `_lpStableValue` valuation).
     *
     *      The A2 implementation valued the position via the
     *      fair-LP-value formula `2 * sqrt(k * p) * lpHeld / totalLp`,
     *      which read live pool reserves (`k = reserve0 * reserve1`)
     *      from `RWA_AMM.getPool()`. `k` is swap-invariant but NOT
     *      donation-invariant: transferring tokens directly into the
     *      pool and calling the permissionless `RWAPool.sync()` raises
     *      both reserves and `k` in the same block, and the value
     *      function was monotonic in `k` — so a safety/weight
     *      computation built on it had a manipulable input.
     *
     *      This implementation values the position from state that no
     *      external actor can move:
     *        - `deployedPrincipalToken0/1` — the token0/token1 principal
     *          POLManager itself committed into this pool, tracked in
     *          its own {PoolAccounting} record. Internal storage; only
     *          POLManager's own {deploy}/{withdraw} bookkeeping writes
     *          it.
     *        - `p` — the token0->token1 TWAP (UQ112x112), which predates
     *          the transaction by at least `minTwapWindow` and so cannot
     *          be moved by a same-block skew.
     *      The position's token1-numeraire value is the raw token1
     *      principal plus the token0 principal priced into token1 at the
     *      TWAP: `deployedPrincipalToken1 + p * deployedPrincipalToken0`.
     *
     *      This is correct for the RELATIVE weight comparison
     *      {rebalance} / {_deployableAmount} need: every managed pool is
     *      valued on the same basis (tracked principal at the TWAP), so
     *      the cross-pool shares {_realizedWeightBps} derives are
     *      consistent. It does not attempt to mark fee accrual or curve
     *      drift into the position value — those would require reading
     *      live pool state — which is the deliberate trade for an
     *      unmanipulable input to the safety path.
     *
     *      Because this consults the TWAP, callers that reach it
     *      ({rebalance}, {_deployableAmount}) require a sufficiently
     *      aged {Observation}; a missing/too-fresh observation reverts
     *      via {_twapPriceUQ}.
     * @param poolId The RWAAMM pool ID.
     * @param policy The pool's policy; `policy.token0` selects the TWAP
     *        direction used to price the token0 principal into token1.
     * @return value The position's `token1`-side TWAP-valued worth, from
     *         tracked principal only.
     */
    function _poolStableValue(
        bytes32 poolId,
        PoolPolicy memory policy
    ) internal view returns (uint256 value) {
        PoolAccounting memory acct = poolAccounting[poolId];
        uint256 principal0 = acct.deployedPrincipalToken0;
        uint256 principal1 = acct.deployedPrincipalToken1;
        if (principal0 == 0 && principal1 == 0) return 0;

        // token1-numeraire value: raw token1 principal + token0
        // principal priced into token1 at the TWAP. Both inputs are
        // unmanipulable (internal accounting + a >= minTwapWindow
        // average). `_consultTwap` returns 0 for a zero amount.
        value = principal1 + _consultTwap(poolId, policy.token0, principal0);
    }

    /**
     * @notice Apply the governance slippage band to an expected amount.
     * @dev Audit C-01: returns
     *      `expected * (BPS_DENOMINATOR - maxSlippageBps)
     *      / BPS_DENOMINATOR`. Because `maxSlippageBps` is hard-capped
     *      at `MAX_SLIPPAGE_BPS_CAP` (< `BPS_DENOMINATOR`), the result
     *      is always strictly positive for a positive `expected`,
     *      so a swap/add/remove minimum is never zero.
     * @param expected The expected/reference amount.
     * @return minimum The slippage-bounded minimum.
     */
    function _applySlippage(
        uint256 expected
    ) internal view returns (uint256 minimum) {
        minimum =
            (expected * (BPS_DENOMINATOR - maxSlippageBps)) /
            BPS_DENOMINATOR;
    }

    // ─────────────────── ERC-2771 Context Overrides ──────────────────

    /**
     * @notice Resolve the original sender behind a meta-transaction.
     * @dev Delegates to {ERC2771Context} so trusted-forwarder calls
     *      attribute keeper actions to the real caller.
     * @return sender The effective message sender.
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address sender)
    {
        sender = ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve the original calldata behind a meta-transaction.
     * @dev Delegates to {ERC2771Context} to strip the appended sender.
     * @return data The effective calldata.
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata data)
    {
        data = ERC2771Context._msgData();
    }

    /**
     * @notice Length of the ERC-2771 context suffix appended to
     *         calldata by the trusted forwarder.
     * @dev Delegates to {ERC2771Context}.
     * @return length The context suffix length in bytes.
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256 length)
    {
        length = ERC2771Context._contextSuffixLength();
    }

    // ──────────────────────── Internal Pure ──────────────────────────

    /**
     * @notice Narrow a `uint256` to `uint128` for accounting counters.
     * @dev Reverts on overflow via the explicit bound check. POL
     *      accounting amounts (token base units and LP supply) sit far
     *      below 2^128 for realistic treasury sizes; the check makes the
     *      assumption fail loudly rather than silently truncate.
     * @param value The value to narrow.
     * @return narrowed The value as a `uint128`.
     */
    function _toUint128(
        uint256 value
    ) internal pure returns (uint128 narrowed) {
        if (value > type(uint128).max) revert ValueTooLarge(value);
        narrowed = uint128(value);
    }
}
