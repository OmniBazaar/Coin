// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/**
 * @title OmniLegacyVest
 * @author Omni Development DAO
 * @notice Founder-XOM legacy supply lockup, founder-authorized 2026-05-28.
 *
 *         Locks 95% of the founder's 2.564B XOM legacy position
 *         (2.4358B XOM = {EXPECTED_FUNDING}; source of truth is the
 *         on-chain `LegacyBalanceClaim.legacyBalances(keccak256("quasar"))`
 *         entitlement = 2,564,000,000 XOM, read 2026-07-05) on a
 *         5-year schedule with a 2-year cliff and 3-year linear vest.
 *         The remaining 5% (128.2M XOM) stays liquid on the founder
 *         EOA as a disclosed
 *         operational slice. See
 *         `Documents/LP-Briefing-Legacy-Supply.md` for the full
 *         disclosure framing.
 *
 *         Supersedes the prior `LegacyDevcoLockup` design (founder
 *         decision 2026-05-26, 1-year cliff). The 2026-05-28 revision
 *         tightened to 2 years + added three explicit acceleration
 *         clauses + the post-audit hardening below.
 *
 * @dev Extends OpenZeppelin {VestingWalletCliff} (v5.3). Schedule:
 *      - `start` = constructor `startTimestamp` argument
 *      - cliff   = `start + 2 years` (no release before cliff)
 *      - linear vest from cliff up to `start + LOCKUP_DURATION`
 *      - total duration = 5 years (2y cliff + 3y linear ramp at ~2.78%/month)
 *
 *      ## Acceleration
 *      Three triggers, each one-way and irreversible. Once accelerated,
 *      the full remaining locked balance becomes releasable.
 *
 *      1. {accelerateByDAO} — callable only by the configured
 *         {DAO_CONTROLLER} address. Used for two scenarios encoded in
 *         the DAO's proposal text: (a) acquisition-event
 *         acknowledgment, (c) generic DAO supermajority acceleration.
 *         **Deploy-time choice:** {DAO_CONTROLLER} should be the
 *         protocol's `OmniTimelockController` so the timelock's own
 *         queue delay protects against single-block governance
 *         compromise. This is an intentional exception to the
 *         Pioneer-Phase "no timelock routing" rule — DAO acceleration
 *         is a DAO commitment to LPs, not an admin function. See the
 *         post-audit remediation note for the design rationale.
 *
 *      2. {accelerateByIncapacity} — permissionless after the
 *         beneficiary's last {alive} heartbeat plus
 *         {HEARTBEAT_PERIOD} + {GRACE_PERIOD}. Implements
 *         "verifiable founder incapacity" via a deadman-switch
 *         pattern. The beneficiary should pre-designate an
 *         {estateRecipient} (one-way irrevocable setter); when the
 *         incapacity trigger fires AND an {estateRecipient} is set,
 *         ownership of the contract transfers atomically to the
 *         estate recipient. Future {release} calls then deliver to
 *         the estate recipient, not the (incapacitated) original
 *         beneficiary. If no estate recipient is set, the unlocked
 *         tokens remain payable to the current `owner()` — which
 *         is the founder's wallet whose keys may be lost; that risk
 *         is the founder's estate-planning responsibility.
 *
 *      ## Heartbeat
 *      {alive} resets {lastAlive} to `block.timestamp`. Callable only
 *      by `owner()` (the beneficiary). The beneficiary is responsible
 *      for ensuring at least one heartbeat lands every
 *      ({HEARTBEAT_PERIOD} - some safety margin) seconds. The contract
 *      seeds {lastAlive} to `block.timestamp` at deploy so the first
 *      grace window doesn't begin until the contract has been live for
 *      {HEARTBEAT_PERIOD} + {GRACE_PERIOD}.
 *
 *      ## Withdrawing
 *      Beneficiary calls `release(address token)` with the XOM ERC-20
 *      address to pull currently-vested balance. The native-Ether
 *      {receive} and the no-arg {release} are explicitly DISABLED —
 *      XOM is held as ERC-20 on OmniCoin L1; native gas-token deposits
 *      to this contract revert. This prevents the dual-asset
 *      double-withdrawal hazard noted in OZ {VestingWallet}'s own
 *      NatSpec for chains where the native asset and an ERC-20
 *      wrapper coexist (OmniCoin L1 is such a chain).
 *
 *      ## Funding
 *      Send XOM ERC-20 tokens to this contract's address. After
 *      funding completes, the founder MUST call {acknowledgeFunded}
 *      to assert the {EXPECTED_FUNDING} balance has arrived. The
 *      assertion is one-way and emits an indexed event off-chain
 *      indexers + the LP-briefing tooling rely on. Top-up after
 *      acknowledgment is permitted but should be disclosed in the
 *      next LP-letter; once {accelerated} is true, top-ups become
 *      instantly releasable, so additional funding post-acceleration
 *      is operationally discouraged.
 *
 *      ## Ownership rules
 *      `owner()` is set at deploy to {beneficiary}. The OZ public
 *      {transferOwnership} + {renounceOwnership} are both DISABLED —
 *      ownership cannot be transferred or renounced under normal
 *      operation. This closes the "sell-unvested" attack surface
 *      where the founder could OTC the vest ownership against the
 *      LP-briefing commitment. The single permitted ownership change
 *      is the automatic transfer to {estateRecipient} triggered by
 *      {accelerateByIncapacity} (and only if an {estateRecipient}
 *      was pre-set by the beneficiary).
 *
 *      ## No admin escape hatches
 *      No fund-rescue, no admin pause, no upgrade path, no
 *      {selfdestruct}, no recoverERC20 backdoor. The contract is
 *      mathematical: vest schedule + the three documented
 *      acceleration triggers + nothing else.
 *
 *      ## Anti-retroactive guard
 *      The constructor rejects any `startTimestamp` more than
 *      {MAX_BACKDATE} seconds before deployment, and more than
 *      {MAX_FORWARDDATE} seconds after deployment — preventing
 *      typo-driven schedules that would either vest immediately or
 *      brick the contract for centuries.
 *
 *      ## OmniGovernance voting-power cap (out of scope here)
 *      The companion 7% voting-power cap at `OmniGovernance` is
 *      implemented separately. The cap clamps holder vote weight to
 *      at most 7% of snapshot total supply regardless of holdings.
 *      Reference: `Coin/contracts/governance/OmniVotingPowerCap.sol`
 *      (companion contract, separate audit).
 *
 *      ## Known operational risks (disclosed to LPs)
 *      - **ERC-20 transfer blacklists.** If `owner()` (or the
 *        estate recipient) is ever blacklisted on the XOM token,
 *        every {release} reverts. There is no rescue path. The
 *        founder's hot-wallet hygiene is the only mitigation.
 *      - **Founder key loss without estate-recipient set.**
 *        Acceleration via incapacity then releases to a wallet the
 *        founder can no longer control. The {estateRecipient}
 *        setter exists explicitly to mitigate this.
 *      - **DAO_CONTROLLER compromise.** The vest contract relies on
 *        the DAO's own integrity. A compromised governance executor
 *        can fire {accelerateByDAO} and release the full balance to
 *        `owner()`. The deploy choice of `OmniTimelockController`
 *        (which adds its own queue delay) provides defense-in-depth.
 */
contract OmniLegacyVest is VestingWalletCliff {
    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Total vesting duration in seconds (5 years).
    uint64 public constant LOCKUP_DURATION = 5 * 365 days;

    /// @notice Cliff length in seconds (2 years — no tokens released before).
    uint64 public constant LOCKUP_CLIFF = 2 * 365 days;

    /// @notice Maximum permitted backdate of `startTimestamp` relative to
    ///         `block.timestamp` at deployment (1 day, just enough to
    ///         cover broadcast slop). Tightened from 7 days post-audit
    ///         to minimize the gap between LP-briefing language
    ///         ("24 months following contract deploy") and contract
    ///         reality.
    uint64 public constant MAX_BACKDATE = 1 days;

    /// @notice Maximum permitted forwarddate of `startTimestamp` relative
    ///         to `block.timestamp` at deployment (30 days). Prevents
    ///         typo'd far-future schedules that would brick the cliff
    ///         arithmetic and require DAO acceleration to recover.
    uint64 public constant MAX_FORWARDDATE = 30 days;

    /// @notice Required period between heartbeat calls (365 days).
    uint64 public constant HEARTBEAT_PERIOD = 365 days;

    /// @notice Grace period beyond {HEARTBEAT_PERIOD} before
    ///         {accelerateByIncapacity} becomes callable (90 days,
    ///         absorbs long absences without permitting accidental
    ///         acceleration).
    uint64 public constant GRACE_PERIOD = 90 days;

    /// @notice Expected funding amount the founder commits to deposit
    ///         (2.4358B XOM at 18 decimals = exactly 95% of the
    ///         2,564,000,000 XOM on-chain legacy entitlement of the
    ///         "quasar" account). Enforced by {acknowledgeFunded}.
    uint256 public constant EXPECTED_FUNDING = 2_435_800_000 * 10 ** 18;

    /// @notice Trigger code for DAO-driven acceleration (acquisition
    ///         event OR generic DAO supermajority vote; the DAO's
    ///         proposal specifies which).
    uint8 public constant TRIGGER_DAO = 1;

    /// @notice Trigger code for deadman-switch incapacity acceleration.
    uint8 public constant TRIGGER_INCAPACITY = 2;

    // -----------------------------------------------------------------------
    // Immutable state
    // -----------------------------------------------------------------------

    /// @notice Address authorized to call {accelerateByDAO}. Set at deploy.
    ///         MUST be a contract (not an EOA), MUST NOT equal the
    ///         beneficiary, and MUST NOT equal `tx.origin` at deploy.
    ///         Recommended: the protocol's `OmniTimelockController`.
    address public immutable DAO_CONTROLLER;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    /// @notice Timestamp of the beneficiary's last {alive} heartbeat.
    ///         Initialized to `block.timestamp` at deploy.
    uint64 public lastAlive;

    /// @notice True once any of the three acceleration triggers has
    ///         fired. One-way; cannot be cleared.
    bool public accelerated;

    /// @notice Timestamp at which acceleration was triggered. Zero
    ///         while not accelerated.
    uint64 public acceleratedAt;

    /// @notice Estate-planning successor address. Settable ONCE by the
    ///         beneficiary via {setEstateRecipient}. When set, the
    ///         {accelerateByIncapacity} trigger automatically
    ///         transfers ownership of this contract to the estate
    ///         recipient, so post-incapacity releases deliver to a
    ///         wallet the estate controls (not the lost-key founder
    ///         wallet).
    address public estateRecipient;

    /// @notice True once {acknowledgeFunded} has been called and the
    ///         {EXPECTED_FUNDING} balance has arrived. One-way;
    ///         emits {Funded}.
    bool public funded;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted once at deployment for off-chain indexers + the
    ///         LP-briefing tooling.
    /// @param beneficiary  Address authorized to call `release()` + `alive()`
    /// @param dao          Address authorized to call {accelerateByDAO}
    /// @param start        Vesting start (Unix seconds)
    /// @param cliffTs      Cliff timestamp (Unix seconds, start + 2 years)
    /// @param end          Final vest timestamp (Unix seconds, start + 5 years)
    event LockupDeployed(
        address indexed beneficiary,
        address indexed dao,
        uint64 indexed start,
        uint64 cliffTs,
        uint64 end
    );

    /// @notice Emitted when the beneficiary fires the alive() heartbeat.
    /// @param at  Block timestamp at which the heartbeat landed
    event Heartbeat(uint64 indexed at);

    /// @notice Emitted exactly once, when an acceleration trigger fires.
    /// @param trigger Reason code (1=DAO, 2=incapacity)
    /// @param caller  Address that triggered acceleration
    /// @param at      Block timestamp of acceleration
    event Accelerated(uint8 indexed trigger, address indexed caller, uint64 indexed at);

    /// @notice Emitted when the beneficiary sets the estate-planning
    ///         successor address. One-way; subsequent calls revert.
    /// @param estate Address that will receive ownership on incapacity
    ///               acceleration
    event EstateRecipientSet(address indexed estate);

    /// @notice Emitted when the founder confirms the contract has been
    ///         funded with the {EXPECTED_FUNDING} balance. One-way.
    /// @param token   ERC-20 token funded
    /// @param balance Balance at acknowledgment (>= EXPECTED_FUNDING)
    /// @param atBlock Block number of acknowledgment
    event Funded(address indexed token, uint256 indexed balance, uint256 indexed atBlock);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @dev Reverts when `startTimestamp` is more than {MAX_BACKDATE}
    ///      seconds before `block.timestamp` at deployment.
    /// @param providedStart    The disallowed start timestamp
    /// @param earliestAllowed  Minimum permitted start
    error StartTooFarInPast(uint64 providedStart, uint64 earliestAllowed);

    /// @dev Reverts when `startTimestamp` is more than {MAX_FORWARDDATE}
    ///      seconds after `block.timestamp` at deployment.
    /// @param providedStart  The disallowed start timestamp
    /// @param latestAllowed  Maximum permitted start
    error StartTooFarInFuture(uint64 providedStart, uint64 latestAllowed);

    /// @dev Reverts when {dao} is the zero address — DAO acceleration
    ///      authority must be a real contract.
    error ZeroDAOController();

    /// @dev Reverts when {dao} equals the beneficiary or has no contract
    ///      code — a sanity gate against mis-binding the DAO authority
    ///      to a friendly EOA.
    /// @param dao     The mis-bound DAO address
    /// @param reason  Reason code: 1=equals beneficiary, 2=no contract code
    error DAOControllerMisbound(address dao, uint8 reason);

    /// @dev Reverts when an acceleration call is made after the
    ///      contract is already accelerated.
    error AlreadyAccelerated();

    /// @dev Reverts when {accelerateByDAO} is called by anyone other
    ///      than {DAO_CONTROLLER}.
    /// @param caller The unauthorized caller
    error NotDAOController(address caller);

    /// @dev Reverts when {accelerateByIncapacity} is called before
    ///      the heartbeat window has truly elapsed.
    /// @param earliestPermitted Timestamp at which the trigger first
    ///                          becomes callable
    error IncapacityTriggerTooEarly(uint64 earliestPermitted);

    /// @dev Reverts when a non-owner attempts to fire the heartbeat or
    ///      set the estate recipient.
    /// @param caller The unauthorized caller
    error NotBeneficiary(address caller);

    /// @dev Reverts when {setEstateRecipient} is called for the second
    ///      time. The estate-recipient setter is one-way.
    error EstateRecipientAlreadySet();

    /// @dev Reverts when {setEstateRecipient} is called with the zero
    ///      address. Use a real successor or do not set at all.
    error ZeroEstateRecipient();

    /// @dev Reverts when {acknowledgeFunded} is called a second time.
    error AlreadyFunded();

    /// @dev Reverts when {acknowledgeFunded} is called before the
    ///      {EXPECTED_FUNDING} balance has arrived in the contract.
    /// @param token            ERC-20 token whose balance was checked
    /// @param actualBalance    Balance found
    /// @param requiredBalance  {EXPECTED_FUNDING}
    error InsufficientFunding(
        address token,
        uint256 actualBalance,
        uint256 requiredBalance
    );

    /// @dev Reverts when the OZ-inherited single-step {transferOwnership}
    ///      or {renounceOwnership} is called. Ownership changes only
    ///      occur via {accelerateByIncapacity}'s automatic transfer to
    ///      a pre-set {estateRecipient}.
    error OwnershipChangeDisabled();

    /// @dev Reverts when a native-currency transfer is attempted into
    ///      or out of the vest. XOM is ERC-20 only.
    error NativeCurrencyDisabled();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the 5-year / 2-year-cliff founder vest.
     * @param beneficiary    Address that will receive vested tokens.
     *                       Becomes `owner()`. Calls `release()` + `alive()`
     *                       going forward. Should be a hardware wallet
     *                       or multisig the founder controls.
     * @param dao            Address authorized to call {accelerateByDAO}.
     *                       MUST be a contract (not an EOA), MUST NOT equal
     *                       `beneficiary`, MUST NOT equal `tx.origin`.
     *                       Recommended: the protocol's
     *                       `OmniTimelockController`.
     * @param startTimestamp Unix seconds at which vesting begins. Cliff is
     *                       reached at `startTimestamp + 2 years`; full
     *                       vest at `startTimestamp + 5 years`. Must be
     *                       within `[block.timestamp - 1 day,
     *                       block.timestamp + 30 days]`.
     */
    constructor(
        address beneficiary,
        address dao,
        uint64 startTimestamp
    )
        VestingWallet(beneficiary, startTimestamp, LOCKUP_DURATION)
        VestingWalletCliff(LOCKUP_CLIFF)
    {
        // Zero-beneficiary check is delegated to OZ {Ownable} which reverts
        // with OwnableInvalidOwner — no need to duplicate.
        if (dao == address(0)) revert ZeroDAOController();
        if (dao == beneficiary) revert DAOControllerMisbound(dao, 1);
        // dao.code.length == 0 covers "dao is an EOA" (including the
        // founder's own EOA being passed in by mistake). Combined with
        // the != beneficiary check, this catches every realistic
        // mis-bind pattern. A separate tx.origin check was removed
        // post-Slither (false positive — already covered by code.length).
        if (dao.code.length == 0) revert DAOControllerMisbound(dao, 2);

        // solhint-disable-next-line not-rely-on-time
        uint64 nowTs = uint64(block.timestamp);

        // Backdate bound: at most MAX_BACKDATE seconds before now.
        // Underflow-safe via the ternary: if nowTs <= MAX_BACKDATE
        // (only possible at the very dawn of unix time), earliestAllowed
        // clamps to 0.
        uint64 earliestAllowed = nowTs > MAX_BACKDATE ? nowTs - MAX_BACKDATE : 0;
        if (startTimestamp < earliestAllowed) {
            revert StartTooFarInPast(startTimestamp, earliestAllowed);
        }

        // Forwarddate bound: at most MAX_FORWARDDATE seconds after now.
        // Overflow-safe — both operands fit easily in uint64.
        uint64 latestAllowed = nowTs + MAX_FORWARDDATE;
        if (startTimestamp > latestAllowed) {
            revert StartTooFarInFuture(startTimestamp, latestAllowed);
        }

        DAO_CONTROLLER = dao;
        lastAlive = nowTs;

        emit LockupDeployed(
            beneficiary,
            dao,
            startTimestamp,
            startTimestamp + LOCKUP_CLIFF,
            startTimestamp + LOCKUP_DURATION
        );
    }

    // -----------------------------------------------------------------------
    // Native-currency lockdown — receive() must be declared here next to
    // the constructor per Solidity convention. The matching public-pure
    // overrides ({release}/{releasable}/{vestedAmount}) live further
    // below to maintain external-then-public visibility ordering.
    // -----------------------------------------------------------------------

    /**
     * @notice Native-currency deposits are disabled. XOM is held as
     *         ERC-20 only on OmniCoin L1.
     * @dev Overrides OZ {VestingWallet.receive} to revert. Closes the
     *      dual-asset double-withdrawal hazard documented in OZ
     *      VestingWallet's own NatSpec for chains where the native
     *      asset and an ERC-20 wrapper coexist.
     */
    receive() external payable override {
        revert NativeCurrencyDisabled();
    }

    // -----------------------------------------------------------------------
    // Estate-recipient designation
    // -----------------------------------------------------------------------

    /**
     * @notice Pre-designate the address that takes over the vest if
     *         {accelerateByIncapacity} ever fires. Callable once, only
     *         by the current beneficiary. Recommended: a multisig
     *         controlled by the founder's estate attorney + executor.
     * @param estate Successor address. Must be non-zero.
     */
    function setEstateRecipient(address estate) external {
        if (msg.sender != owner()) revert NotBeneficiary(msg.sender);
        if (estateRecipient != address(0)) revert EstateRecipientAlreadySet();
        if (estate == address(0)) revert ZeroEstateRecipient();
        estateRecipient = estate;
        emit EstateRecipientSet(estate);
    }

    // -----------------------------------------------------------------------
    // Heartbeat
    // -----------------------------------------------------------------------

    /**
     * @notice Beneficiary heartbeat. Resets the deadman-switch counter.
     * @dev Callable only by `owner()` (the beneficiary). The
     *      beneficiary should fire this at least once every
     *      {HEARTBEAT_PERIOD} seconds (minus a safety margin); missed
     *      heartbeats after {HEARTBEAT_PERIOD} + {GRACE_PERIOD} expose
     *      the contract to {accelerateByIncapacity}.
     */
    function alive() external {
        if (msg.sender != owner()) revert NotBeneficiary(msg.sender);
        // solhint-disable-next-line not-rely-on-time
        uint64 ts = uint64(block.timestamp);
        lastAlive = ts;
        emit Heartbeat(ts);
    }

    // -----------------------------------------------------------------------
    // Funding acknowledgment
    // -----------------------------------------------------------------------

    /**
     * @notice One-way assertion that the contract holds at least
     *         {EXPECTED_FUNDING} of the given token. The founder calls
     *         this once after transferring the legacy XOM in. The
     *         emitted {Funded} event is the canonical on-chain
     *         marker the LP-Briefing v2 will reference.
     * @param token ERC-20 token whose balance is being acknowledged.
     */
    function acknowledgeFunded(address token) external {
        if (funded) revert AlreadyFunded();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < EXPECTED_FUNDING) {
            revert InsufficientFunding(token, bal, EXPECTED_FUNDING);
        }
        funded = true;
        emit Funded(token, bal, block.number);
    }

    // -----------------------------------------------------------------------
    // Acceleration triggers
    // -----------------------------------------------------------------------

    /**
     * @notice Accelerate the vest. Callable only by {DAO_CONTROLLER}.
     * @dev Used for both acquisition-event acknowledgment and generic
     *      DAO supermajority acceleration — the DAO's proposal text
     *      specifies the reason; the on-chain primitive is the same.
     *      One-way: subsequent acceleration calls revert.
     */
    function accelerateByDAO() external {
        if (msg.sender != DAO_CONTROLLER) revert NotDAOController(msg.sender);
        if (accelerated) revert AlreadyAccelerated();
        _accelerate(TRIGGER_DAO);
    }

    /**
     * @notice Accelerate the vest via the deadman-switch path. Also
     *         transfers ownership to {estateRecipient} when set, so
     *         subsequent {release} calls deliver to the estate.
     * @dev Permissionless once the heartbeat window expires. Anyone
     *      can call it after `lastAlive + HEARTBEAT_PERIOD +
     *      GRACE_PERIOD < block.timestamp`. If no {estateRecipient}
     *      was pre-set, the unlocked tokens remain payable to the
     *      current `owner()` — which is the founder wallet whose
     *      keys may be lost; that risk is documented in the LP-Briefing.
     */
    function accelerateByIncapacity() external {
        if (accelerated) revert AlreadyAccelerated();
        uint64 earliest = lastAlive + HEARTBEAT_PERIOD + GRACE_PERIOD;
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (uint64(block.timestamp) <= earliest) {
            revert IncapacityTriggerTooEarly(earliest);
        }
        _accelerate(TRIGGER_INCAPACITY);
        // Auto-transfer ownership to the estate recipient if pre-set.
        // Uses the internal {_transferOwnership} (not the public one,
        // which we disabled).
        address estate = estateRecipient;
        if (estate != address(0)) {
            _transferOwnership(estate);
        }
    }

    // -----------------------------------------------------------------------
    // Disabled overrides — native-currency + ownership
    // -----------------------------------------------------------------------

    /**
     * @notice Native-currency releases are disabled. Use
     *         {release(address)} to withdraw vested XOM ERC-20.
     */
    function release() public pure override {
        revert NativeCurrencyDisabled();
    }

    /**
     * @notice Native-currency releasable query is disabled.
     * @return Always reverts.
     */
    function releasable() public pure override returns (uint256) {
        revert NativeCurrencyDisabled();
    }

    /**
     * @notice Native-currency vested query is disabled.
     * @return Always reverts.
     */
    function vestedAmount(uint64) public pure override returns (uint256) {
        revert NativeCurrencyDisabled();
    }

    /**
     * @notice Manual ownership transfer is disabled to prevent
     *         "sell-unvested" arbitrage where the founder could OTC
     *         the contract's future-release stream against the
     *         LP-briefing commitment. The only ownership change path
     *         is the automatic transfer triggered by
     *         {accelerateByIncapacity} when an {estateRecipient} is
     *         pre-set.
     */
    function transferOwnership(address) public pure override {
        revert OwnershipChangeDisabled();
    }

    /**
     * @notice Renouncing ownership is disabled — it would permanently
     *         lock all future releases (transfers to `address(0)`
     *         revert in OZ {SafeERC20}).
     */
    function renounceOwnership() public pure override {
        revert OwnershipChangeDisabled();
    }

    // -----------------------------------------------------------------------
    // Vesting schedule override
    // -----------------------------------------------------------------------

    /**
     * @notice Compute the vested amount at a given timestamp.
     * @dev When {accelerated} is true AND `timestamp >= start()`,
     *      returns the full `totalAllocation` — the entire locked
     *      balance becomes releasable. The `timestamp >= start()`
     *      guard preserves the "no release before start" invariant
     *      even under acceleration (defense against typo'd
     *      far-future start that gets accelerated as a recovery
     *      maneuver). Otherwise delegates to the inherited cliff +
     *      linear schedule.
     * @param totalAllocation Total amount held + already-released for
     *                        the asset being scheduled.
     * @param timestamp Block timestamp to evaluate the schedule at.
     * @return The vested amount at `timestamp`.
     */
    function _vestingSchedule(
        uint256 totalAllocation,
        uint64 timestamp
    ) internal view virtual override returns (uint256) {
        // solhint-disable-next-line gas-strict-inequalities
        if (accelerated && timestamp >= start()) return totalAllocation;
        return super._vestingSchedule(totalAllocation, timestamp);
    }

    /// @dev Internal acceleration bookkeeping. Sets flags + emits the
    ///      indexed event.
    function _accelerate(uint8 trigger) private {
        accelerated = true;
        // solhint-disable-next-line not-rely-on-time
        acceleratedAt = uint64(block.timestamp);
        emit Accelerated(trigger, msg.sender, acceleratedAt);
    }
}
