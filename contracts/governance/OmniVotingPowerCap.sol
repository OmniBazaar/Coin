// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOmniVotingPowerCap
 * @author Omni Development DAO
 * @notice Minimal interface OmniGovernance consults at vote-cast time
 *         to clamp a voter's weight to a configured cap.
 */
interface IOmniVotingPowerCap {
    /**
     * @notice Return the effective voting power for `voter`, clamped to
     *         the configured cap if any.
     * @param voter                 Address whose vote weight is being evaluated.
     * @param rawWeight             The pre-cap weight (delegated + staked).
     * @param snapshotVoteableSupply Per-proposal snapshot of the VOTEABLE XOM
     *                              supply (OmniGovernance passes
     *                              `voteableSupply()` = totalSupply minus the
     *                              quorum-excluded holders), NOT raw
     *                              `totalSupply()`.
     * @return The lesser of `rawWeight` and the cap (if a cap is set).
     */
    function effectiveWeight(
        address voter,
        uint256 rawWeight,
        uint256 snapshotVoteableSupply
    ) external view returns (uint256);
}

/**
 * @title OmniVotingPowerCap
 * @author Omni Development DAO
 * @notice Sidecar voting-power cap for `OmniGovernance`. When a voter
 *         is registered with a non-zero cap, that voter's effective
 *         vote weight on every proposal is clamped to:
 *
 *             min(rawWeight, snapshotVoteableSupply * capBps / 10000)
 *
 *         The cap is expressed in basis points of the per-proposal
 *         snapshot VOTEABLE XOM supply (NOT of raw totalSupply, and NOT
 *         of votes cast). `OmniGovernance` passes `voteableSupply()` =
 *         `totalSupply()` minus the live balances of the
 *         quorum-excluded holders (undistributed reward/bonus pools,
 *         unclaimed legacy, founder vest). This is deliberate: capping
 *         a voter at 7% of the *voteable* universe is what actually
 *         enforces "no single holder dominates the vote". Two
 *         consequences the LP-Briefing MUST reflect: (1) the absolute
 *         XOM ceiling is 7% of voteableSupply, materially LOWER than
 *         7% of the 16.6B nominal supply (~1.162B), because most of
 *         genesis supply is quorum-excluded at launch; (2) that
 *         absolute ceiling FLOATS block-to-block as excluded pools
 *         distribute/claim and as the admin-managed `quorumExcluded`
 *         set changes — so the cap is auditable from
 *         (snapshotVoteableSupply, capBps), NOT from nominal supply
 *         alone. The clamp only ever gets TIGHTER than a
 *         total-supply-denominated cap, never looser, so the
 *         constraint is conservative. At low turnout the cap may
 *         exceed votes cast (no normalization); at high turnout it
 *         bites harder.
 *
 *         Why this shape: matches Compound / MakerDAO / Uniswap-class
 *         voting-cap patterns. Avoids the brittle "X% of votes cast"
 *         pattern that requires post-tally normalization and
 *         order-dependent semantics. Investor-facing claim is
 *         deterministic and auditable from snapshot data alone.
 *
 *         Founder-authorized 2026-05-29 as the companion change to
 *         `OmniLegacyVest`. Cap = 700 bp on the founder's EOA at
 *         deploy; future voters can be added by `admin` (Pioneer:
 *         deployer EOA; post-Pioneer: `OmniGovernance` itself).
 *         Per Pioneer-Phase rule, admin transfer must NOT route
 *         through `OmniTimelockController` during Pioneer (banned
 *         intermediary pattern per CLAUDE.md
 *         `feedback_no_builtin_timelocks.md`).
 *
 *         ## Known limitation — snapshot-pre-dating (audit M-1)
 *         The cap operates per-address. A capped voter can split
 *         their balance across fresh, uncapped EOAs **before** a
 *         proposal snapshot is taken, evading the clamp at vote
 *         time. This is by-design — the cap is a voluntary stated
 *         commitment, not a Sybil-resistant primitive. The
 *         mitigation is operational: any token movement out of a
 *         capped address is publicly visible on-chain and is
 *         treated by the LP-Briefing as a governance trust break.
 *         Admin can also react: register caps on newly-discovered
 *         large holders before the next proposal. See the
 *         LP-Briefing for the founder's commitment framing.
 *
 * @dev Standalone contract. Not upgradeable, no proxy. Admin role is
 *      a single mutable address rotated via `transferAdmin` /
 *      `acceptAdmin` (2-step).
 *      Read by `OmniGovernance._castVote` via the
 *      `IOmniVotingPowerCap` interface. If `OmniGovernance`'s
 *      `votingPowerCap` slot is `address(0)`, no clamping happens —
 *      the contract is inert until governance wires it in.
 */
contract OmniVotingPowerCap is IOmniVotingPowerCap {
    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Basis-points denominator. 10000 = 100%.
    uint16 public constant BASIS_POINTS = 10_000;

    /// @notice Hard upper bound on per-voter caps (10% = 1000 bp). The
    ///         LP-Briefing's authorized cap is 700 bp (7%); the
    ///         MAX_CAP_BPS allows headroom for moderately higher
    ///         policy choices but rejects anything above 10%, which
    ///         would defeat the cap's purpose. Lowered from 5000 to
    ///         1000 post-audit (finding L-4).
    uint16 public constant MAX_CAP_BPS = 1_000;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    /// @notice Per-voter cap in basis points. 0 = uncapped (no
    ///         clamping). Non-zero = clamped to `(snapshot * value) /
    ///         BASIS_POINTS` per proposal.
    mapping(address voter => uint16 capBps) public capBps;

    /// @notice Current admin authorized to set / clear voter caps.
    address public admin;

    /// @notice Pending admin (Ownable2Step-style; must call
    ///         {acceptAdmin} to finalize).
    address public pendingAdmin;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a voter's cap is set or changed.
    /// @param voter   Address whose cap changed
    /// @param oldCap  Previous cap in basis points (0 = uncapped)
    /// @param newCap  New cap in basis points (0 = uncapped)
    event CapSet(
        address indexed voter,
        uint16 indexed oldCap,
        uint16 indexed newCap
    );

    /// @notice Emitted when admin rotation is proposed (step 1 of 2).
    /// @param currentAdmin  Address currently holding admin
    /// @param proposed      Address proposed as successor
    event AdminProposed(
        address indexed currentAdmin,
        address indexed proposed
    );

    /// @notice Emitted when admin rotation completes (step 2 of 2).
    /// @param oldAdmin  Address that previously held admin
    /// @param newAdmin  Address that now holds admin
    event AdminTransferred(
        address indexed oldAdmin,
        address indexed newAdmin
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @dev Reverts on calls from non-admin addresses.
    /// @param caller The unauthorized caller
    error NotAdmin(address caller);

    /// @dev Reverts when {acceptAdmin} is called by anyone other than
    ///      {pendingAdmin}, or when no rotation is in flight.
    /// @param caller The unauthorized caller
    error NotPendingAdmin(address caller);

    /// @dev Reverts when constructor receives zero admin.
    error ZeroAdmin();

    /// @dev Reverts when a cap above {MAX_CAP_BPS} is proposed.
    /// @param proposed The disallowed cap value
    error CapTooHigh(uint16 proposed);

    /// @dev Reverts when {setCap} is called with the zero address.
    error ZeroVoter();

    /// @dev Reverts when {setCap} is called with the same value the
    ///      voter already has — eliminates event-stream noise from
    ///      no-op admin calls.
    error NoChange();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the voting-power cap.
     * @param initialAdmin Address that can set / clear voter caps + rotate
     *                     admin. Pioneer-Phase: deployer EOA. Post-Pioneer:
     *                     transfer to `OmniGovernance` (the Governor
     *                     contract). Do NOT route through
     *                     `OmniTimelockController` during Pioneer — see
     *                     contract-level NatSpec for the rule.
     */
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAdmin();
        admin = initialAdmin;
        emit AdminTransferred(address(0), initialAdmin);
    }

    // -----------------------------------------------------------------------
    // Admin actions
    // -----------------------------------------------------------------------

    /**
     * @notice Set (or clear by passing 0) the cap for a voter.
     * @dev Admin-only. Emits {CapSet}.
     * @param voter   Voter whose cap is being set.
     * @param newCap  New cap in basis points. 0 to remove the cap;
     *                otherwise in `(0, MAX_CAP_BPS]`.
     */
    function setCap(address voter, uint16 newCap) external {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        if (voter == address(0)) revert ZeroVoter();
        if (newCap > MAX_CAP_BPS) revert CapTooHigh(newCap);
        uint16 oldCap = capBps[voter];
        if (newCap == oldCap) revert NoChange();
        capBps[voter] = newCap;
        emit CapSet(voter, oldCap, newCap);
    }

    /**
     * @notice Propose admin rotation (step 1 of 2).
     * @dev Admin-only. The {newAdmin} must call {acceptAdmin} to
     *      finalize. Pass `address(0)` to clear any pending rotation.
     * @param newAdmin Proposed successor admin address.
     */
    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        pendingAdmin = newAdmin;
        emit AdminProposed(admin, newAdmin);
    }

    /**
     * @notice Accept the pending admin rotation (step 2 of 2).
     * @dev Callable only by {pendingAdmin}. Clears {pendingAdmin} on
     *      success.
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin(msg.sender);
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    // -----------------------------------------------------------------------
    // View — read by OmniGovernance._castVote
    // -----------------------------------------------------------------------

    /**
     * @inheritdoc IOmniVotingPowerCap
     */
    function effectiveWeight(
        address voter,
        uint256 rawWeight,
        uint256 snapshotVoteableSupply
    ) external view returns (uint256) {
        uint16 c = capBps[voter];
        if (c == 0) return rawWeight;
        // Overflow-safe: snapshotVoteableSupply <= totalSupply (~1.66e28)
        // and c <= MAX_CAP_BPS (1000), so the product <= ~1.66e31, far
        // below 2**256. Division by the non-zero BASIS_POINTS constant
        // floors the cap DOWN (conservative — never grants > capBps).
        uint256 cap = (snapshotVoteableSupply * c) / BASIS_POINTS;
        return rawWeight < cap ? rawWeight : cap;
    }
}
