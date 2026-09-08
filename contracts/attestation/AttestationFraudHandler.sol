// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";

/**
 * @title AttestationFraudHandler
 * @author OmniBazaar Team
 * @notice Permissionless attestation-fraud slashing (VT-09). Anyone can
 *         submit cryptographic proof that a validator equivocated (signed two
 *         conflicting attestations) or that a committee outcome was overturned;
 *         on an upheld proof the handler slashes that validator's application-
 *         layer OmniCore stake, pays the reporter a bounty from the slash, and
 *         escrows the remainder under a post-slash lock before it burns — so a
 *         late, correct challenge can still reverse an exceptional wrongful
 *         slash before the funds are destroyed.
 *
 * @dev Tiers (settled founder design):
 *      - Tier 1 (equivocation): 100% full slash, applied immediately on
 *        upheld proof. Equivocation is cryptographically proven (two valid
 *        quorum attestations over different payloads by a common attester).
 *      - Tier 2 (outcome-overturned): 50% partial slash, gated by a 24h
 *        challenge window — the slash is recorded as pending and only
 *        finalizes if unchallenged.
 *      - Tier 3 (liveness): no slash — exclusion only (the existing
 *        `OmniRegistration.recordEquivocation` auto-exclusion already covers
 *        it; no contract change here).
 *
 *      Post-slash lock: the slashed remainder (after the bounty) is escrowed
 *      for {ESCROW_LOCK} before anyone may burn it. {governanceReverse} lets
 *      DEFAULT_ADMIN_ROLE return an escrow to the validator before that
 *      deadline (the governance override for wrongful slashes).
 *
 *      The handler holds OmniCore's SLASHER_ROLE. OmniCore.slash transfers the
 *      slashed XOM to this contract (the slasher); this contract then splits
 *      bounty vs escrow. Bounty and burn destinations are addresses, settable
 *      by the deployer during Pioneer (direct, no delay).
 */

/**
 * @notice Minimal OmniCore surface the handler depends on.
 */
interface IOmniCoreSlash {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    function getStake(address user) external view returns (Stake memory);
    function slash(address validator, uint256 amount) external;
    function OMNI_COIN() external view returns (address);
}

contract AttestationFraudHandler is AccessControl {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────── constants ──

    /// @notice Fraction of the slash paid to the reporter (basis points).
    uint256 public constant BOUNTY_BPS = 500; // 5%

    /// @notice Tier-2 challenge window before a pending partial slash
    ///         finalizes.
    uint256 public constant CHALLENGE_WINDOW = 24 hours;

    /// @notice Post-slash lock: the escrowed remainder cannot be burned
    ///         until this long after the slash, so a late correct challenge
    ///         can reverse it.
    uint256 public constant ESCROW_LOCK = 14 days;

    /// @notice Burn destination (tokens sent here are destroyed / removed).
    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ───────────────────────────────────────────────────────────── state ──

    /// @notice OmniCore (holds the stake + SLASHER_ROLE).
    IOmniCoreSlash public omniCore;

    /// @notice Committee verifier used to validate attestation proofs.
    IBridgeVerifier public committeeVerifier;

    /// @notice Dedup: an (target, digestA, digestB) tuple already slashed.
    mapping(bytes32 => bool) public slashedEvidence;

    /// @notice Post-slash lock escrows.
    Escrow[] public escrows;

    /// @notice A pending Tier-2 partial slash, awaiting finalize/challenge.
    struct PendingSlash {
        address target;
        uint256 amount; // computed at report time
        uint256 bps; // 50 for Tier 2
        uint256 raisedAt;
        bytes32 evidenceKey;
        address reporter; // who reported (receives the bounty at finalize)
        bool cancelled;
        bool finalized;
    }

    /// @notice A post-slash escrow, burnable after `lockedUntil`.
    struct Escrow {
        address target;
        uint256 amount;
        uint256 lockedUntil;
        bytes32 evidenceKey;
        bool reversed;
        bool burned;
    }

    PendingSlash[] public pendingSlashes;

    // ─────────────────────────────────────────────────────────── events ──

    /// @notice A validator was slashed for attestation fraud.
    event Slashed(
        address indexed target,
        bytes32 indexed evidenceKey,
        uint256 amount,
        uint256 bounty,
        uint256 escrowIndex
    );

    /// @notice A Tier-2 partial slash was reported, awaiting challenge.
    event OutcomeOverturnReported(
        address indexed target,
        uint256 indexed pendingIndex,
        uint256 amount,
        uint256 finalizeAt
    );

    /// @notice A pending slash was challenged (cancelled).
    event SlashChallenged(uint256 indexed pendingIndex, address challenger);

    /// @notice A pending slash was finalized.
    event SlashFinalized(uint256 indexed pendingIndex, uint256 escrowIndex);

    /// @notice Governance reversed an escrow (returned to the validator).
    event EscrowReversed(
        uint256 indexed escrowIndex,
        address indexed target,
        uint256 amount
    );

    /// @notice An escrow was burned after the lock expired.
    event EscrowBurned(uint256 indexed escrowIndex, uint256 amount);

    // ─────────────────────────────────────────────────────────── errors ──

    error ZeroAddress();
    error DigestsIdentical();
    error ProofVerificationFailed();
    error NotCommonAttester();
    error NotSameRound();
    error EvidenceAlreadySlashed();
    error NothingToSlash();
    error PendingSlashNotFound();
    error ChallengeWindowElapsed();
    error NotPendingTarget();
    error NotFinalizable();
    error EscrowNotFound();
    error EscrowLocked();
    error EscrowAlreadyResolved();

    // ──────────────────────────────────────────────────── construction ──

    /**
     * @notice Deploy the handler (Pioneer deployer-direct).
     * @param initialAdmin Deployer EOA (DEFAULT_ADMIN_ROLE).
     * @param _omniCore OmniCore proxy. The deployer must grant this contract
     *        OmniCore's SLASHER_ROLE after deploy.
     * @param _committeeVerifier The committee verifier (e.g.
     *        RandomCommitteeVerifier) whose `verify` validates proofs.
     */
    constructor(
        address initialAdmin,
        address _omniCore,
        address _committeeVerifier
    ) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        if (_omniCore == address(0)) revert ZeroAddress();
        if (_committeeVerifier == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        omniCore = IOmniCoreSlash(_omniCore);
        committeeVerifier = IBridgeVerifier(_committeeVerifier);
    }

    // ──────────────────────────────────────────────────── admin setters ──

    /**
     * @notice Replace the committee verifier.
     * @dev Deployer-direct (Pioneer). No delay.
     */
    function setCommitteeVerifier(
        address _verifier
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_verifier == address(0)) revert ZeroAddress();
        committeeVerifier = IBridgeVerifier(_verifier);
    }

    // ──────────────────────────────────────────────── Tier 1: equivocation ──

    /**
     * @notice Report equivocation: two valid committee attestations over
     *         DIFFERENT digests, both signed by `target` (Tier 1 → full slash).
     * @dev Permissionless. Verifies both proofs via {committeeVerifier},
     *      requires `target` to be a common attester, dedups, then slashes
     *      `target`'s full stake, pays the reporter a bounty, and escrows the
     *      remainder under {ESCROW_LOCK}.
     * @param digestA First attested digest.
     * @param proofA Committee proof over `digestA`.
     * @param digestB Second (conflicting) attested digest.
     * @param proofB Committee proof over `digestB`.
     * @param target The equivocating attester to slash.
     */
    function reportEquivocation(
        bytes32 digestA,
        bytes calldata proofA,
        bytes32 digestB,
        bytes calldata proofB,
        address target
    ) external {
        if (digestA == digestB) revert DigestsIdentical();
        if (target == address(0)) revert ZeroAddress();

        // Bind both proofs to the SAME committee round: equivocation is
        // "signed two different digests for the same commitBlock", not "signed
        // two different digests at any point in history". Without this, two
        // unrelated legitimate proofs would slash an innocent attester.
        uint256 commitA = _commitBlock(proofA);
        uint256 commitB = _commitBlock(proofB);
        if (commitA == 0 || commitA != commitB) revert NotSameRound();

        (bool validA, address[] memory attestersA) = committeeVerifier.verify(
            digestA,
            proofA
        );
        (bool validB, address[] memory attestersB) = committeeVerifier.verify(
            digestB,
            proofB
        );
        if (!validA || !validB) revert ProofVerificationFailed();
        if (!_contains(attestersA, target) || !_contains(attestersB, target)) {
            revert NotCommonAttester();
        }

        bytes32 key = _evidenceKey(1, target, digestA, digestB);
        if (slashedEvidence[key]) revert EvidenceAlreadySlashed();
        slashedEvidence[key] = true;

        _slash(target, 100, key, msg.sender);
    }

    // ────────────────────────────── Tier 2: outcome-overturned (partial) ──

    /**
     * @notice Report an overturned committee outcome (Tier 2 → 50% slash).
     * @dev Permissionless. Same evidence shape as {reportEquivocation}, but
     *      the slash is recorded as PENDING and only finalizes after
     *      {CHALLENGE_WINDOW} unless the target challenges it first.
     * @param digestA First attested outcome digest.
     * @param proofA Committee proof over `digestA`.
     * @param digestB Second (overturning) outcome digest.
     * @param proofB Committee proof over `digestB`.
     * @param target The attester to partially slash.
     */
    function reportOutcomeOverturned(
        bytes32 digestA,
        bytes calldata proofA,
        bytes32 digestB,
        bytes calldata proofB,
        address target
    ) external {
        if (digestA == digestB) revert DigestsIdentical();
        if (target == address(0)) revert ZeroAddress();

        // Same round binding as {reportEquivocation} — see the note there.
        uint256 commitA = _commitBlock(proofA);
        uint256 commitB = _commitBlock(proofB);
        if (commitA == 0 || commitA != commitB) revert NotSameRound();

        (bool validA, address[] memory attestersA) = committeeVerifier.verify(
            digestA,
            proofA
        );
        (bool validB, address[] memory attestersB) = committeeVerifier.verify(
            digestB,
            proofB
        );
        if (!validA || !validB) revert ProofVerificationFailed();
        if (!_contains(attestersA, target) || !_contains(attestersB, target)) {
            revert NotCommonAttester();
        }

        // Tier-2 uses its own dedup namespace so a self-reported Tier-2
        // challenge cannot consume a later Tier-1 evidence key.
        bytes32 key = _evidenceKey(2, target, digestA, digestB);
        if (slashedEvidence[key]) revert EvidenceAlreadySlashed();
        slashedEvidence[key] = true;

        IOmniCoreSlash.Stake memory stake = omniCore.getStake(target);
        uint256 amount = (stake.amount * 50) / 100;
        if (amount == 0) revert NothingToSlash();

        pendingSlashes.push(
            PendingSlash({
                target: target,
                amount: amount,
                bps: 50,
                // solhint-disable-next-line not-rely-on-time
                raisedAt: block.timestamp,
                evidenceKey: key,
                reporter: msg.sender,
                cancelled: false,
                finalized: false
            })
        );
        uint256 index = pendingSlashes.length - 1;
        // solhint-disable-next-line not-rely-on-time
        emit OutcomeOverturnReported(
            target, index, amount, block.timestamp + CHALLENGE_WINDOW
        );
    }

    /**
     * @notice Cancel a pending Tier-2 slash (the target disputes it).
     * @dev Callable by the target only, within the challenge window.
     * @param pendingIndex Index into {pendingSlashes}.
     */
    function challengeSlash(uint256 pendingIndex) external {
        PendingSlash storage p = pendingSlashes[pendingIndex];
        if (p.target == address(0)) revert PendingSlashNotFound();
        if (p.cancelled || p.finalized) revert NotFinalizable();
        if (msg.sender != p.target) revert NotPendingTarget();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > p.raisedAt + CHALLENGE_WINDOW) {
            revert ChallengeWindowElapsed();
        }
        p.cancelled = true;
        emit SlashChallenged(pendingIndex, msg.sender);
    }

    /**
     * @notice Finalize an unchallenged Tier-2 slash after the window.
     * @dev Permissionless. Executes the 50% slash, pays the reporter bounty,
     *      and escrows the remainder.
     * @param pendingIndex Index into {pendingSlashes}.
     */
    function finalizeSlash(uint256 pendingIndex) external {
        PendingSlash storage p = pendingSlashes[pendingIndex];
        if (p.target == address(0)) revert PendingSlashNotFound();
        if (p.cancelled || p.finalized) revert NotFinalizable();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < p.raisedAt + CHALLENGE_WINDOW) {
            revert NotFinalizable();
        }
        p.finalized = true;
        _slash(p.target, p.bps, p.evidenceKey, p.reporter);
        // The escrow created by _slash is the last one.
        emit SlashFinalized(pendingIndex, escrows.length - 1);
    }

    // ───────────────────────────────────── post-slash lock (escrow/burn) ──

    /**
     * @notice Governance override: return an escrow to the validator before
     *         it burns (exceptional wrongful slashes).
     * @dev Only DEFAULT_ADMIN_ROLE. Must be called before {ESCROW_LOCK}
     *      elapses and before a burn.
     * @param escrowIndex Index into {escrows}.
     */
    function governanceReverse(
        uint256 escrowIndex
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Escrow storage e = escrows[escrowIndex];
        if (e.target == address(0)) revert EscrowNotFound();
        if (e.reversed || e.burned) revert EscrowAlreadyResolved();
        e.reversed = true;
        IERC20(omniCore.OMNI_COIN()).safeTransfer(e.target, e.amount);
        emit EscrowReversed(escrowIndex, e.target, e.amount);
    }

    /**
     * @notice Burn an escrow after the post-slash lock elapses.
     * @dev Permissionless. Sends the escrowed XOM to {BURN_ADDRESS}.
     * @param escrowIndex Index into {escrows}.
     */
    function burnEscrow(uint256 escrowIndex) external {
        Escrow storage e = escrows[escrowIndex];
        if (e.target == address(0)) revert EscrowNotFound();
        if (e.reversed || e.burned) revert EscrowAlreadyResolved();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < e.lockedUntil) revert EscrowLocked();
        e.burned = true;
        IERC20(omniCore.OMNI_COIN()).safeTransfer(BURN_ADDRESS, e.amount);
        emit EscrowBurned(escrowIndex, e.amount);
    }

    // ─────────────────────────────────────────────────────────── helpers ──

    /**
     * @notice Slash `target` at `bps`/100 of its stake, pay the bounty to
     *         `reporter`, and escrow the remainder.
     * @dev `omniCore.slash` transfers the slashed XOM to this contract. The
     *      escrow is pushed BEFORE the bounty transfer so a re-entrant token
     *      cannot reorder `escrows` indices (CEI).
     */
    function _slash(
        address target,
        uint256 bps,
        bytes32 key,
        address reporter
    ) internal {
        IOmniCoreSlash.Stake memory stake = omniCore.getStake(target);
        uint256 amount = (stake.amount * bps) / 100;
        if (amount == 0) revert NothingToSlash();

        uint256 bounty = (amount * BOUNTY_BPS) / 10_000;
        uint256 remainder = amount - bounty;

        // Effects first: push the escrow before any external token transfer.
        escrows.push(
            Escrow({
                target: target,
                amount: remainder,
                // solhint-disable-next-line not-rely-on-time
                lockedUntil: block.timestamp + ESCROW_LOCK,
                evidenceKey: key,
                reversed: false,
                burned: false
            })
        );

        // OmniCore.slash reduces the stake and sends `amount` XOM here.
        omniCore.slash(target, amount);

        if (bounty > 0) {
            IERC20(omniCore.OMNI_COIN()).safeTransfer(reporter, bounty);
        }

        emit Slashed(target, key, amount, bounty, escrows.length - 1);
    }

    /**
     * @notice Deterministic, order-independent, tier-salted evidence key.
     */
    function _evidenceKey(
        uint256 tier,
        address target,
        bytes32 digestA,
        bytes32 digestB
    ) internal pure returns (bytes32) {
        (bytes32 lo, bytes32 hi) = digestA < digestB
            ? (digestA, digestB)
            : (digestB, digestA);
        return keccak256(abi.encode(tier, target, lo, hi));
    }

    /**
     * @notice Extract the leading 32-byte `commitBlock` field from a proof.
     */
    function _commitBlock(bytes calldata proof) internal pure returns (uint256) {
        if (proof.length < 32) return 0;
        uint256 cb;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            cb := calldataload(proof.offset)
        }
        return cb;
    }

    /**
     * @notice Whether `account` is in `list`.
     */
    function _contains(
        address[] memory list,
        address account
    ) internal pure returns (bool) {
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ++i) {
            if (list[i] == account) return true;
        }
        return false;
    }
}
