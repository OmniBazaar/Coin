// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AbstractMessageIdMultisigIsm} from "../vendor/hyperlane/isms/multisig/AbstractMessageIdMultisigIsm.sol";
import {AbstractMultisigIsm} from "../vendor/hyperlane/isms/multisig/AbstractMultisigIsm.sol";
import {IInterchainSecurityModule} from "../vendor/hyperlane/interfaces/IInterchainSecurityModule.sol";
import {CommitteeAttestor} from "../attestation/CommitteeAttestor.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title CommitteeMessageIdMultisigIsm
 * @author OmniBazaar Development Team
 * @notice Hyperlane Interchain Security Module that secures the XOM Warp Route
 *         (OmniCoin L1 88008 ↔ COTI 2632500) using OmniBazaar's OWN scaling
 *         validator set instead of a static validator list.
 *
 * @dev    Why this exists (founder-authorized 2026-05-30, supersedes the
 *         static-MultisigISM choice in the original bridge-pivot decision). A
 *         stock Hyperlane `StaticMessageIdMultisigIsm` bakes a fixed validator
 *         array into immutable bytecode — it does NOT scale with permissionless
 *         validator entry (architectural invariant #7) and re-creates the
 *         fixed M-of-N committee the random-committee system was built to
 *         retire. This ISM instead reads the LIVE eligible-set snapshot that
 *         the 5 COTI privacy contracts already trust.
 *
 *         **Composition.** Two audited bases, no bespoke crypto:
 *           - {AbstractMessageIdMultisigIsm} — the upstream Hyperlane
 *             message-id multisig verifier (vendored from hyperlane-xyz
 *             core v11.3.1). It reconstructs the checkpoint digest,
 *             recovers signers with
 *             `ECDSA.recover`, and runs the two-pointer threshold check. We
 *             override ONLY {validatorsAndThreshold}.
 *           - {CommitteeAttestor} — OmniBazaar's COTI-side eligible-set
 *             snapshot base (audited 2026-05-28), already inherited by the 5
 *             privacy contracts. It holds a sorted-ascending validator snapshot
 *             kept in sync with the L1 `RandomCommitteeVerifier` pool by the
 *             existing validator-side eligible-set pusher service via the
 *             inherited, permissionless
 *             {CommitteeAttestor.pushEligibleSetUpdate}. Pointing that service
 *             at THIS contract's address is the only Phase-3 wiring needed — no
 *             new sync service, no separate registry contract (honoring the
 *             minimise-COTI-contracts principle).
 *
 *         **Validator set + threshold.** {validatorsAndThreshold} returns the
 *         full inherited `eligibleSnapshot()` (sorted ascending — exactly the
 *         ordering Hyperlane's verifier and the relayer's signature ordering
 *         expect) and a threshold derived as a BFT supermajority
 *         `floor(2n/3) + 1`. At n=5 this is 4-of-5; it scales automatically as
 *         validators qualify (4-of-5 → 5-of-7 → 7-of-10 …) with no redeploy
 *         and no manual tuning.
 *
 *         **Eligible set, not the per-epoch random subset (deliberate).** Every
 *         eligible validator runs a Hyperlane agent and signs every checkpoint,
 *         so the right model is "threshold of the eligible set." The random
 *         per-message committee that {CommitteeAttestor._verifyCommittee}
 *         implements is NOT used here: it would strand in-flight messages
 *         across an eligible-set rotation (a liveness bug on a bridge), and
 *         per-message randomness adds nothing to Hyperlane's all-sign-threshold
 *         model. `_verifyCommittee` remains available but unused by the ISM.
 *
 *         **Upgrade path.** The Warp Route can swap this ISM for a ZK /
 *         light-client module later via `setInterchainSecurityModule` with NO
 *         token-route redeploy.
 *
 *         **Ownership.** Pioneer-Phase rule: `owner` is the deployer EOA, which
 *         directly holds the admin escape hatches ({setCommitteeParameters},
 *         {adminBootstrapSnapshot}). No timelock intermediary.
 */
contract CommitteeMessageIdMultisigIsm is
    AbstractMessageIdMultisigIsm,
    AbstractMultisigIsm,
    CommitteeAttestor,
    Ownable2Step
{
    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the ISM and bootstrap its initial eligible set.
     * @param owner_ Initial owner (Pioneer Phase: the deployer EOA).
     * @param initialEligibleSet Sorted-ascending, deduped validator addresses
     *        (the current L1 eligible pool mirrored onto COTI).
     * @param initialCommitteeSize Initial N for the inherited snapshot-update
     *        gate (e.g. 5). Bounds {pushEligibleSetUpdate} signer accounting;
     *        does NOT set the bridge verification threshold, which is derived.
     * @param initialQuorumM Initial M for the snapshot-update gate (e.g. 4).
     *        Must satisfy `initialQuorumM * 3 >= initialCommitteeSize * 2`.
     * @param initialL1Block L1 block at which `initialEligibleSet` was computed
     *        (0 for a clean bootstrap).
     */
    constructor(
        address owner_,
        address[] memory initialEligibleSet,
        uint256 initialCommitteeSize,
        uint256 initialQuorumM,
        uint256 initialL1Block
    ) Ownable(owner_) {
        __CommitteeAttestor_init(initialCommitteeSize, initialQuorumM);
        // Sequence starts at 1 (must exceed the initial 0). Subsequent updates
        // arrive via the inherited permissionless pushEligibleSetUpdate.
        _bootstrapSnapshot(initialEligibleSet, initialL1Block, 1);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                          ADMIN ESCAPE HATCHES
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Owner-gated bootstrap/override of the eligible-set snapshot.
     *         Mirror of {CommitteeAttestor._bootstrapSnapshot} with the role
     *         check the base requires the child to provide. Use only if every
     *         current-snapshot signer is unreachable (the normal update path is
     *         the permissionless {pushEligibleSetUpdate}).
     * @param set Sorted-ascending, deduped eligible set.
     * @param l1Block L1 block at which `set` was computed.
     * @param sequence Monotonic id; must exceed the current snapshot sequence.
     */
    function adminBootstrapSnapshot(
        address[] calldata set,
        uint256 l1Block,
        uint256 sequence
    ) external onlyOwner {
        _bootstrapSnapshot(set, l1Block, sequence);
    }

    /**
     * @notice Owner-gated update of the inherited committee parameters (N, M)
     *         that gate {pushEligibleSetUpdate}. The bridge verification
     *         threshold is derived from the live set size and is NOT affected.
     * @param newCommitteeSize New N. Must be in
     *        [MIN_COMMITTEE_SIZE, MAX_COMMITTEE_SIZE] and not exceed the
     *        current snapshot size.
     * @param newQuorumM New M. Must satisfy `newQuorumM * 3 >= newCommitteeSize * 2 + 1`.
     */
    function setCommitteeParameters(uint256 newCommitteeSize, uint256 newQuorumM)
        external
        onlyOwner
    {
        _setCommitteeParameters(newCommitteeSize, newQuorumM);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                          HYPERLANE ISM SURFACE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice The current bridge verification threshold (number of validator
     *         signatures required), derived from the live eligible-set size.
     * @return The BFT supermajority threshold for the current set.
     */
    function bridgeThreshold() external view returns (uint8) {
        return _bftThreshold(eligibleSnapshotLength());
    }

    /**
     * @notice ISM type discriminator read by Hyperlane relayers to format
     *         metadata. This is a message-id multisig module.
     * @return The `MESSAGE_ID_MULTISIG` enum value.
     */
    function moduleType() external pure override returns (uint8) {
        return uint8(IInterchainSecurityModule.Types.MESSAGE_ID_MULTISIG);
    }

    /**
     * @notice The validator set and signature threshold for verifying a
     *         message. Same set for every message on this lane (the bridge
     *         eligible set), so the message argument is unused. Overrides
     *         `AbstractMultisigIsm.validatorsAndThreshold`.
     * @dev Returns the inherited `eligibleSnapshot()` (sorted ascending, as
     *      Hyperlane's two-pointer verifier and the relayer's signature
     *      ordering require) and a derived BFT supermajority threshold. The
     *      external self-call to `eligibleSnapshot()` is required because the
     *      base exposes it as an external getter; it is a cheap staticcall on
     *      the read-only verification path.
     * @return validators Sorted-ascending eligible validator addresses.
     * @return threshold BFT supermajority `floor(2n/3) + 1` (0 if the set is
     *         below the design floor, which makes Hyperlane's `verify` fail
     *         closed).
     */
    function validatorsAndThreshold(bytes calldata)
        public
        view
        override
        returns (address[] memory validators, uint8 threshold)
    {
        validators = this.eligibleSnapshot();
        threshold = _bftThreshold(validators.length);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              PRIVATE LOGIC
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice BFT supermajority quorum: `floor(2n/3) + 1` (strictly greater
     *         than two-thirds).
     * @dev Returns 0 below the `MIN_COMMITTEE_SIZE` (3) design floor so callers
     *      FAIL CLOSED: `AbstractMultisigIsm.verify` requires `threshold > 0`,
     *      so an empty set OR a set rotated down to 1-2 members (a fat-fingered
     *      or coerced `pushEligibleSetUpdate`) halts the bridge rather than
     *      allowing a near-single-signer mint. The committee's
     *      `MIN_COMMITTEE_SIZE` bounds the parameter `committeeSize`, but the
     *      live snapshot length is what gates verification, so the floor is
     *      re-asserted here against the live length (defense-in-depth, security
     *      review 2026-05-30). `n` is bounded by `MAX_SNAPSHOT_SIZE` (256), so
     *      the result always fits in `uint8` (max 171).
     * @param n Size of the live eligible set.
     * @return The required number of signatures (0 = fail closed).
     */
    function _bftThreshold(uint256 n) private pure returns (uint8) {
        if (n < MIN_COMMITTEE_SIZE) return 0;
        return uint8((n * 2) / 3 + 1);
    }
}
