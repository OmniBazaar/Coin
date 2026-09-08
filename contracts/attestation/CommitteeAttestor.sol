// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CommitteeSeedPinningLib} from "./CommitteeSeedPinningLib.sol";
import {CommitteeAttestorLib} from "./CommitteeAttestorLib.sol";

/* solhint-disable max-line-length */
/* solhint-disable gas-strict-inequalities */
/* solhint-disable gas-small-strings */
/* solhint-disable code-complexity */
/* solhint-disable ordering */
// gas-strict-inequalities: `<=` semantics required throughout (monotonic
// sequence comparisons, signer sort-unique enforcement, bounded-range
// checks). Strict `<` would change behavior.
// ordering: OZ-style `__init` helpers conventionally come before external
// API in upgradeable contracts (e.g. ContextUpgradeable, OwnableUpgradeable).
// Solhint's strict external-before-internal rule conflicts with this idiom.
// gas-small-strings: SNAPSHOT_UPDATE_DOMAIN is keccak'd at compile time,
// never stored — the gas-small-strings warning is a false positive here.
// code-complexity: pushEligibleSetUpdate and _verifyCommittee perform
// multiple required validation steps that don't decompose cleanly.

/**
 * @title CommitteeAttestor
 * @author OmniBazaar Development Team
 * @notice COTI-side inheritable base for the 5 privacy contracts that need
 *         M-of-N committee verification of off-chain attestations. Holds an
 *         eligible-set snapshot mirrored from L1 `RandomCommitteeVerifier`
 *         via permissionless signed updates.
 *
 * @dev    Rationale. The L1 `RandomCommitteeVerifier` computes its pool from
 *         on-chain `Bootstrap` + `OmniCore` (staking) + `OmniRegistration`
 *         (KYC). Those three contracts only exist on chain id 88008 — they
 *         have no COTI counterpart. Rather than spin up a fresh verifier
 *         contract on COTI (founder direction: minimise contract count), the
 *         attestation function is folded into the 5 privacy contracts via
 *         inheritance of this base, and each contract holds its own mirrored
 *         snapshot updated by a permissionless `pushEligibleSetUpdate`
 *         protected by signatures from the *current* snapshot members.
 *
 *         Storage layout — ERC-7201 namespaced storage is used so a child
 *         contract's existing UUPS storage layout cannot collide with the
 *         base's state when added to an already-deployed proxy. The single
 *         namespace `omnibazaar.privacy.CommitteeAttestor` is shared by every
 *         child contract (different proxies = different storage tries = no
 *         cross-contract aliasing).
 *
 *         Proof format — identical to the L1 verifier's. A committee proof
 *         is:
 *
 *             proof = commitBlock(32 bytes) || sig0(65) || sig1(65) || ...
 *
 *         where `commitBlock` is the L1-or-COTI block number whose `blockhash`
 *         seeds Fisher-Yates committee selection. `_verifyCommittee(digest,
 *         proof)` returns `(true, recoveredAttesters)` on success and is the
 *         only attestation entry point children call from their *WithCommittee
 *         paths.
 *
 *         Snapshot update format — caller submits a sorted-unique address
 *         list + the L1 block at which that pool was computed + a monotonic
 *         sequence number + concatenated ECDSA signatures over the digest
 *
 *             keccak256(abi.encode(
 *                 SNAPSHOT_UPDATE_DOMAIN,
 *                 block.chainid,
 *                 address(this),
 *                 newSequence,
 *                 newL1Block,
 *                 keccak256(abi.encode(newSet))
 *             ))
 *
 *         At least `quorumM` of the signatures MUST come from members of the
 *         CURRENT snapshot. This bootstraps from `_bootstrapSnapshot(...)`
 *         which is gated by the child contract's admin role.
 *
 *         Grinding resistance (opt-in, one-way). `commitBlock` is normally
 *         free for the prover to choose from any of the last ~256 mined
 *         blocks, which lets a colluding minority of the pool enumerate
 *         candidates and pick whichever seats enough of themselves — see
 *         `CommitteeSeedPinningLib` for the full analysis. Once a child
 *         contract's admin calls {_requireCommitteeSeedPinning} (never
 *         reversible), {_verifyCommittee} additionally requires that the
 *         proof's `commitBlock` was pre-pinned via
 *         {requestCommitteeSeed} — a future block nobody could predict the
 *         hash of at pin time. Defaults to OFF so this file can be safely
 *         added to already-deployed proxies without changing any live
 *         `*WithCommittee` behavior; a child's admin flips it only after
 *         its off-chain coordinator has been upgraded to pin ahead of
 *         collecting signatures.
 */
abstract contract CommitteeAttestor {
    // VT-27 EIP-170: the committee-verification chain is DELEGATECALL-linked
    // to `CommitteeAttestorLib`, which declares no state variables and reads
    // the proxy's ERC-7201 namespaced storage through a fixed slot — so the
    // link is upgrade-safe (same rationale as `BridgeDestinationLib`). Test
    // fixtures that go through `upgrades.deployProxy` pass
    // `unsafeAllow: ["external-library-linking"]` for this.
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ════════════════════════════════════════════════════════════════════════
    //                       ERC-7201 NAMESPACED STORAGE
    // ════════════════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:omnibazaar.privacy.CommitteeAttestor
    struct CommitteeAttestorStorage {
        uint256 committeeSize;
        uint256 quorumM;
        address[] eligibleSnapshot;
        mapping(address attester => bool inSnapshot) isInSnapshot;
        uint256 eligibleSnapshotBlock; // L1 block at which the source snapshot was computed
        uint256 eligibleSnapshotSequence; // monotonic id; rejects out-of-order pushes
        // Appended (not inserted) — safe for already-deployed proxies. See
        // `CommitteeSeedPinningLib` for the grinding-resistance rationale.
        CommitteeSeedPinningLib.PinStore pinStore;
        bool committeeSeedPinningRequired; // one-way; see {_requireCommitteeSeedPinning}
        // VT-27: dispute-equivocation misbehavior timestamps, appended
        // (never inserted) to preserve the storage layout of already-deployed
        // privacy proxies. Written by {recordDisputeEquivocation}; feeds the
        // off-chain L1 {AttestationFraudHandler} slashing pipeline.
        mapping(address attester => uint64[]) disputeMisbehaviorTimestamps;
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Length of one canonical ECDSA signature (r || s || v).
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @notice Length of the `commitBlock` field at the head of every proof.
    uint256 public constant COMMIT_BLOCK_FIELD_LENGTH = 32;

    /// @notice Lower bound on committee size. Matches L1 verifier's floor.
    uint256 public constant MIN_COMMITTEE_SIZE = 3;

    /// @notice Upper bound on committee size. Matches L1 verifier's ceiling.
    uint256 public constant MAX_COMMITTEE_SIZE = 31;

    /// @notice Maximum addresses we accept in a single snapshot push.
    uint256 public constant MAX_SNAPSHOT_SIZE = 256;

    /// @notice Blocks of lead time {requestCommitteeSeed} pins ahead of the
    ///         current block. See `CommitteeSeedPinningLib.MIN_PIN_DELAY`.
    uint256 public constant COMMIT_SEED_PIN_DELAY = 2;

    /// @notice Domain tag bound into every snapshot-update digest. Prevents
    ///         a snapshot signature from one COTI contract being replayed
    ///         against a different one (per-contract `address(this)` also
    ///         hashes in for belt-and-suspenders).
    bytes32 public constant SNAPSHOT_UPDATE_DOMAIN =
        keccak256("OmniBazaar.Privacy.CotiSnapshotUpdate.v1");

    /// @dev keccak256(abi.encode(uint256(keccak256("omnibazaar.privacy.CommitteeAttestor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _COMMITTEE_ATTESTOR_STORAGE =
        0xfe88d9b39bfa606c219219faac4fffbdae83b9dcb0e764f0507920c209d83800;

    // ════════════════════════════════════════════════════════════════════════
    //                                  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Emitted whenever the eligible-set snapshot is replaced.
    /// @param sequence Monotonic snapshot id (strictly greater than the previous).
    /// @param l1Block L1 block at which the source snapshot was computed.
    /// @param poolSize Number of validators in the new snapshot.
    event EligibleSetUpdated(
        uint256 indexed sequence,
        uint256 indexed l1Block,
        uint256 indexed poolSize
    );

    /// @notice Emitted when committee parameters (N, M) are updated.
    /// @param committeeSize New `committeeSize` (N).
    /// @param quorumM New `quorumM` (M).
    event CommitteeParametersUpdated(
        uint256 indexed committeeSize,
        uint256 indexed quorumM
    );

    /// @notice Emitted once, when a child contract's admin permanently
    ///         switches on commit-block pin enforcement.
    /// @param activatedAtBlock Block at which enforcement began.
    event CommitteeSeedPinningRequired(uint256 indexed activatedAtBlock);

    /// @notice Emitted when {recordDisputeEquivocation} attributes a common
    ///         attester across two conflicting dispute outcomes (VT-27).
    /// @param attester The committee member who signed both outcomes.
    /// @param digestA First outcome digest.
    /// @param digestB Conflicting outcome digest.
    /// @param timestamp Block timestamp of the attribution.
    event DisputeEquivocationRecorded(
        address indexed attester,
        bytes32 indexed digestA,
        bytes32 indexed digestB,
        uint256 timestamp
    );

    // ════════════════════════════════════════════════════════════════════════
    //                                  ERRORS
    // ════════════════════════════════════════════════════════════════════════

    error CommitteeSizeOutOfRange(uint256 size);
    error QuorumBelowSupermajority(uint256 m, uint256 n);
    error QuorumExceedsCommittee(uint256 m, uint256 n);
    error AlreadyInitialized();
    error SnapshotTooLarge(uint256 size);
    error SnapshotEmpty();
    error SnapshotBelowMinimum();
    error SnapshotNotSorted();
    error ZeroAddressInSnapshot();
    error StaleSnapshotSequence(uint256 provided, uint256 expectedMin);
    error InsufficientSnapshotSigners(uint256 got, uint256 required);
    error SnapshotSignerNotInCurrentSet(address signer);
    error SnapshotSignaturesNotSortedUnique(address signer, address prev);
    error SnapshotSignatureMalformed();
    error SnapshotSigConcatMalformed(uint256 length);

    // ════════════════════════════════════════════════════════════════════════
    //                             INITIALIZATION
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice One-shot initializer. Sub-classes MUST call this from their UUPS
     *         initializer (or a reinitializer when adding the base to an
     *         already-deployed proxy).
     * @param committeeSize_ Initial N (e.g. 5).
     * @param quorumM_ Initial M (e.g. 3 — supermajority of 5).
     */
    // solhint-disable-next-line func-name-mixedcase
    function __CommitteeAttestor_init(uint256 committeeSize_, uint256 quorumM_)
        internal
    {
        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        if ($.committeeSize != 0) revert AlreadyInitialized();
        _validateParameters(committeeSize_, quorumM_);
        $.committeeSize = committeeSize_;
        $.quorumM = quorumM_;
        emit CommitteeParametersUpdated(committeeSize_, quorumM_);
    }

    /**
     * @notice Bootstrap-write the initial eligible-set snapshot. Admin-gated;
     *         the child contract MUST wrap the call in its own role check
     *         (e.g. `onlyRole(DEFAULT_ADMIN_ROLE)`). Used at deploy time to
     *         seed the snapshot before any signed updates are possible, and
     *         as an admin-override escape hatch if every previous-snapshot
     *         signer is unreachable.
     * @param set Sorted-ascending, deduped eligible-set.
     * @param l1Block L1 block at which the source pool was computed (or zero
     *        for a clean bootstrap).
     * @param sequence Monotonic id; must exceed the current
     *        `eligibleSnapshotSequence`.
     */
    function _bootstrapSnapshot(
        address[] memory set,
        uint256 l1Block,
        uint256 sequence
    ) internal {
        _writeSnapshot(set, l1Block, sequence);
    }

    /**
     * @notice Update committee parameters (N, M). Admin-gated; the child
     *         contract MUST wrap the call in its own role check.
     * @param newCommitteeSize New N. Must be in [MIN_COMMITTEE_SIZE, MAX_COMMITTEE_SIZE].
     * @param newQuorumM New M. Must satisfy `newQuorumM * 3 >= newCommitteeSize * 2 + 1`.
     */
    function _setCommitteeParameters(
        uint256 newCommitteeSize,
        uint256 newQuorumM
    ) internal {
        _validateParameters(newCommitteeSize, newQuorumM);
        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        // Audit Pass-3 L-3 — reject params that would lock out
        // `pushEligibleSetUpdate` immediately. The current snapshot must
        // be able to muster N signers (and ≥M of them current-pool
        // members) for the committee path to remain alive. Setting
        // `newCommitteeSize` greater than the current snapshot bricks
        // both `_verifyCommittee` AND `pushEligibleSetUpdate` until
        // another snapshot lands by some other means.
        //
        // Bootstrap case: `committeeSize` is set BEFORE the first
        // snapshot in `__CommitteeAttestor_init`. At that moment the
        // snapshot is empty and this check would unconditionally revert,
        // so we skip the gate during init by exempting an empty pool.
        uint256 poolSize = $.eligibleSnapshot.length;
        if (poolSize != 0 && newCommitteeSize > poolSize) {
            revert CommitteeSizeOutOfRange(newCommitteeSize);
        }
        $.committeeSize = newCommitteeSize;
        $.quorumM = newQuorumM;
        emit CommitteeParametersUpdated(newCommitteeSize, newQuorumM);
    }

    /**
     * @notice One-way switch: once true, {_verifyCommittee} rejects any
     *         proof whose `commitBlock` was not pre-pinned via
     *         {requestCommitteeSeed} for that exact digest. Admin-gated;
     *         the child contract MUST wrap this in its own role check AND
     *         only call it after its off-chain coordinator has been
     *         upgraded to pin ahead of collecting signatures — flipping
     *         early breaks every live `*WithCommittee` call because no
     *         historical proof will ever have a matching pin. Same
     *         caution as `RandomCommitteeVerifier.disableLegacySignatures`.
     */
    function _requireCommitteeSeedPinning() internal {
        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        $.committeeSeedPinningRequired = true;
        emit CommitteeSeedPinningRequired(block.number);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                       PERMISSIONLESS SNAPSHOT UPDATE
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Replace the eligible-set snapshot with a new one signed by ≥M
     *         members of the CURRENT snapshot. Anyone may call.
     * @param newSet Sorted-ascending, deduped eligible-set.
     * @param newL1Block L1 block at which the source pool was computed.
     * @param newSequence Monotonic id; must exceed current
     *        `eligibleSnapshotSequence`.
     * @param sigs Concatenated 65-byte ECDSA signatures over the digest, in
     *        ascending recovered-address order, all from CURRENT snapshot
     *        members. ≥`quorumM` valid signatures required.
     */
    function pushEligibleSetUpdate(
        address[] calldata newSet,
        uint256 newL1Block,
        uint256 newSequence,
        bytes calldata sigs
    ) external {
        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        uint256 currentSeq = $.eligibleSnapshotSequence;
        if (newSequence <= currentSeq) {
            revert StaleSnapshotSequence(newSequence, currentSeq + 1);
        }
        if (newSet.length == 0) revert SnapshotEmpty();
        if (newSet.length > MAX_SNAPSHOT_SIZE) {
            revert SnapshotTooLarge(newSet.length);
        }
        if (sigs.length == 0 || sigs.length % SIGNATURE_LENGTH != 0) {
            revert SnapshotSigConcatMalformed(sigs.length);
        }

        // Shape validation is now performed by _writeSnapshot for both
        // pushEligibleSetUpdate AND _bootstrapSnapshot (audit Pass-3 M-2).

        uint256 nlen = newSet.length;
        bytes32 digest = keccak256(
            abi.encode(
                SNAPSHOT_UPDATE_DOMAIN,
                block.chainid,
                address(this),
                newSequence,
                newL1Block,
                keccak256(abi.encode(newSet))
            )
        );
        bytes32 ethSigned = digest.toEthSignedMessageHash();

        uint256 required = $.quorumM;
        uint256 sigCount = sigs.length / SIGNATURE_LENGTH;
        if (sigCount < required) {
            revert InsufficientSnapshotSigners(sigCount, required);
        }

        address prevSigner = address(0);
        for (uint256 i = 0; i < sigCount; ) {
            uint256 sigStart = i * SIGNATURE_LENGTH;
            bytes calldata sig = sigs[sigStart:sigStart + SIGNATURE_LENGTH];
            (address signer, ECDSA.RecoverError err, ) = ethSigned.tryRecover(sig);
            if (err != ECDSA.RecoverError.NoError || signer == address(0)) {
                revert SnapshotSignatureMalformed();
            }
            if (signer <= prevSigner) {
                revert SnapshotSignaturesNotSortedUnique(signer, prevSigner);
            }
            if (!$.isInSnapshot[signer]) {
                revert SnapshotSignerNotInCurrentSet(signer);
            }
            prevSigner = signer;
            unchecked {
                ++i;
            }
        }

        // Promote calldata to memory for the storage writer.
        address[] memory toWrite = new address[](nlen);
        for (uint256 i = 0; i < nlen; ) {
            toWrite[i] = newSet[i];
            unchecked {
                ++i;
            }
        }
        _writeSnapshot(toWrite, newL1Block, newSequence);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Current committee size (N).
    function committeeSize() public view returns (uint256) {
        return _getCommitteeAttestorStorage().committeeSize;
    }

    /// @notice Current committee quorum (M).
    function quorumM() public view returns (uint256) {
        return _getCommitteeAttestorStorage().quorumM;
    }

    /// @notice Full current eligible-set snapshot, sorted ascending.
    function eligibleSnapshot() external view returns (address[] memory) {
        return _getCommitteeAttestorStorage().eligibleSnapshot;
    }

    /// @notice Number of validators in the current snapshot.
    function eligibleSnapshotLength() public view returns (uint256) {
        return _getCommitteeAttestorStorage().eligibleSnapshot.length;
    }

    /**
     * @notice True if `account` is in the current snapshot.
     * @param account Address to test for membership.
     */
    function isInSnapshot(address account) public view returns (bool) {
        return _getCommitteeAttestorStorage().isInSnapshot[account];
    }

    /// @notice L1 block at which the current snapshot's source pool was computed.
    function eligibleSnapshotBlock() public view returns (uint256) {
        return _getCommitteeAttestorStorage().eligibleSnapshotBlock;
    }

    /// @notice Monotonic id of the current snapshot.
    function eligibleSnapshotSequence() public view returns (uint256) {
        return _getCommitteeAttestorStorage().eligibleSnapshotSequence;
    }

    /// @notice True once commit-block pin enforcement is active. See
    ///         {_requireCommitteeSeedPinning}.
    function committeeSeedPinningRequired() public view returns (bool) {
        return _getCommitteeAttestorStorage().committeeSeedPinningRequired;
    }

    /**
     * @notice Pin the future block whose hash will seed committee selection
     *         for `digest` — the grinding-resistance primitive from
     *         `CommitteeSeedPinningLib`. Permissionless; harmless to call
     *         even before {committeeSeedPinningRequired} is flipped on, so
     *         an off-chain coordinator can switch over ahead of the
     *         on-chain toggle. MUST be called (and mined) before the
     *         resulting proof is submitted once pinning is required.
     * @param digest The message digest a future committee proof will cover.
     * @return pinnedBlock The block number whose hash will seed selection.
     */
    function requestCommitteeSeed(bytes32 digest)
        external
        returns (uint256 pinnedBlock)
    {
        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        return
            CommitteeSeedPinningLib.pin(
                $.pinStore,
                digest,
                COMMIT_SEED_PIN_DELAY
            );
    }

    /**
     * @notice Read the pinned commitBlock for `digest`, if any.
     * @param digest The message digest to look up.
     * @return pinnedBlock The pinned block number (0 if never pinned).
     * @return isPinned True if a pin has been recorded.
     */
    function pinnedCommitBlock(bytes32 digest)
        external
        view
        returns (uint256 pinnedBlock, bool isPinned)
    {
        return
            CommitteeSeedPinningLib.get(
                _getCommitteeAttestorStorage().pinStore,
                digest
            );
    }

    /**
     * @notice Predict the committee for a given (digest, commitBlock). Off-
     *         chain coordinators call this to know which validators to ask
     *         for signatures. Empty array on stale/missing commitBlock or
     *         under-sized pool.
     * @param digest The 32-byte message hash that signers will commit to.
     * @param commitBlock The L1-or-COTI block whose blockhash seeds selection.
     * @return committee The sorted committee addresses (length == committeeSize),
     *         OR empty array if commitBlock is stale / out of range / pool too small.
     */
    function committeeFor(bytes32 digest, uint256 commitBlock)
        external
        view
        returns (address[] memory committee)
    {
        // VT-27 EIP-170: the committee-selection chain (derive seed +
        // Fisher-Yates sample) lives in the DELEGATECALL-linked
        // {CommitteeAttestorLib}. Byte-identical semantics — see the
        // library's {CommitteeAttestorLib.committeeFor}.
        return CommitteeAttestorLib.committeeFor(digest, commitBlock);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                       COMMITTEE-PROOF VERIFICATION
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify an M-of-N committee attestation over `digest`.
     * @dev Proof format (identical to L1 `RandomCommitteeVerifier.verify`):
     *
     *          proof = commitBlock(32 bytes) || sig0(65) || sig1(65) || ...
     *
     *      Number of signatures MUST be in `[quorumM, committeeSize]`.
     *      Signers MUST appear sorted ascending (dedup check). Each signer
     *      MUST be in the committee derived from
     *      `keccak256(blockhash(commitBlock), blockhash(commitBlock-1), digest)`.
     *
     *      Unlike the L1 verifier, no live per-signer eligibility recheck is
     *      done — the COTI snapshot IS the source of truth for membership
     *      on this chain. Slashing on L1 propagates here via the next signed
     *      `pushEligibleSetUpdate`.
     *
     *      VT-27 EIP-170: the body is delegated to {CommitteeAttestorLib}
     *      (DELEGATECALL). Byte-identical semantics; never reverts on a bad
     *      proof — returns `(false, [])` instead.
     * @param digest The 32-byte message hash that signers committed to (NOT
     *        the eth-signed envelope — that wrap happens here).
     * @param proof The proof bytes as described above.
     * @return valid True if the proof verifies.
     * @return attesters The recovered attester addresses (length == sigCount).
     */
    function _verifyCommittee(bytes32 digest, bytes calldata proof)
        internal
        view
        returns (bool valid, address[] memory attesters)
    {
        return CommitteeAttestorLib.verifyCommittee(digest, proof);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              PRIVATE LOGIC
    // ════════════════════════════════════════════════════════════════════════

    function _getCommitteeAttestorStorage()
        private
        pure
        returns (CommitteeAttestorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _COMMITTEE_ATTESTOR_STORAGE
        }
    }

    function _writeSnapshot(
        address[] memory set,
        uint256 l1Block,
        uint256 sequence
    ) private {
        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        uint256 nlen = set.length;
        if (nlen == 0) revert SnapshotEmpty();
        // Audit H-02 (CommitteeMessageIdMultisigIsm): reject snapshots below
        // MIN_COMMITTEE_SIZE (3). A set of 1-2 validators collapses the ISM's
        // BFT threshold to 0 and halts the bridge (fail-closed); preventing
        // the shrink keeps the bridge alive. Gates both `pushEligibleSetUpdate`
        // (permissionless, signed) and `_bootstrapSnapshot` (admin hatch).
        if (nlen < MIN_COMMITTEE_SIZE) revert SnapshotBelowMinimum();
        if (nlen > MAX_SNAPSHOT_SIZE) revert SnapshotTooLarge(nlen);
        uint256 currentSeq = $.eligibleSnapshotSequence;
        if (sequence <= currentSeq) {
            revert StaleSnapshotSequence(sequence, currentSeq + 1);
        }
        // Audit Pass-3 M-2 — shape validation (sort-ascending + non-zero
        // + dedup) now runs HERE so it gates both `pushEligibleSetUpdate`
        // (permissionless, signed) and `_bootstrapSnapshot` (admin escape
        // hatch). Previously only the permissionless path validated, so a
        // single admin typo (duplicates / out-of-order / zero addresses)
        // could brick the contract by mistuning the snapshot below the
        // sorted-unique invariant `_verifyCommittee` relies on.
        address prev = address(0);
        for (uint256 i = 0; i < nlen; ) {
            address a = set[i];
            if (a == address(0)) revert ZeroAddressInSnapshot();
            if (a <= prev) revert SnapshotNotSorted();
            prev = a;
            unchecked {
                ++i;
            }
        }

        // Clear old membership lookup.
        uint256 oldLen = $.eligibleSnapshot.length;
        for (uint256 i = 0; i < oldLen; ) {
            $.isInSnapshot[$.eligibleSnapshot[i]] = false;
            unchecked {
                ++i;
            }
        }
        // Reset the array and re-populate.
        // solhint-disable-next-line max-line-length
        // Use direct slot manipulation (delete) for the dynamic array length.
        delete $.eligibleSnapshot;

        for (uint256 i = 0; i < nlen; ) {
            address a = set[i];
            $.eligibleSnapshot.push(a);
            $.isInSnapshot[a] = true;
            unchecked {
                ++i;
            }
        }
        $.eligibleSnapshotBlock = l1Block;
        $.eligibleSnapshotSequence = sequence;
        emit EligibleSetUpdated(sequence, l1Block, nlen);
    }

    function _validateParameters(uint256 n, uint256 m) private pure {
        if (n < MIN_COMMITTEE_SIZE || n > MAX_COMMITTEE_SIZE) {
            revert CommitteeSizeOutOfRange(n);
        }
        if (m > n) revert QuorumExceedsCommittee(m, n);
        // M ≥ ⌊2N/3⌋ + 1  ↔  3M ≥ 2N + 1  (strict BFT supermajority).
        // The strict form closes M-01: the snapshot-update quorum must be at
        // least the bridge verification threshold (floor(2n/3)+1). The loose
        // ⌈2N/3⌉ form under-shoots by one whenever N is divisible by 3
        // (e.g. N=6: loose M=4 vs bridge threshold 5).
        if (m * 3 < n * 2 + 1) revert QuorumBelowSupermajority(m, n);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                    DISPUTE EQUIVOCATION ATTRIBUTION (VT-27)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Attribute dispute-equivocation: two valid committee proofs over
     *         CONFLICTING outcomes for the SAME dispute (VT-27).
     * @dev Permissionless. Mirrors `OmniRegistrationDigestLib.recordEquivocation`
     *      with the binding that the canonical implementation has and the audit
     *      flagged as missing: both digests are RECONSTRUCTED here from
     *      `(typehash, subject, winner)`, so a valid proof for the second digest
     *      is only possible if the committee genuinely signed the conflicting
     *      winner. Two unrelated proofs (different subjects/rounds) can no
     *      longer be replayed to falsely attribute an innocent committee member.
     *
     *      On conflict, the attributed attesters' timestamps are recorded and
     *      `DisputeEquivocationRecorded` is emitted — the off-chain pipeline
     *      feeds this to the L1 {AttestationFraudHandler}, which slashes the
     *      equivocating attester's OmniCore stake. No synchronous cross-chain
     *      call is possible from COTI, so the event is the bridge.
     * @param typehash The dispute-outcome EIP-712 typehash (child-specific).
     * @param subject The dispute identifier (e.g. `escrowId`).
     * @param winnerA First attested winner.
     * @param proofA Committee proof over `(typehash, subject, winnerA)`.
     * @param winnerB Second (conflicting) attested winner.
     * @param proofB Committee proof over `(typehash, subject, winnerB)`.
     */
    function recordDisputeEquivocation(
        bytes32 typehash,
        bytes32 subject,
        address winnerA,
        bytes calldata proofA,
        address winnerB,
        bytes calldata proofB
    ) external {
        if (winnerA == winnerB) return;

        bytes32 digestA = keccak256(abi.encode(typehash, subject, winnerA));
        bytes32 digestB = keccak256(abi.encode(typehash, subject, winnerB));

        (bool validA, address[] memory attestersA) = _verifyCommittee(
            digestA,
            proofA
        );
        (bool validB, address[] memory attestersB) = _verifyCommittee(
            digestB,
            proofB
        );
        if (!validA || !validB) return;

        CommitteeAttestorStorage storage $ = _getCommitteeAttestorStorage();
        // solhint-disable-next-line not-rely-on-time
        uint256 ts = block.timestamp;

        uint256 lenA = attestersA.length;
        uint256 lenB = attestersB.length;
        for (uint256 i = 0; i < lenA; ) {
            address candidate = attestersA[i];
            for (uint256 j = 0; j < lenB; ) {
                if (attestersB[j] == candidate) {
                    $.disputeMisbehaviorTimestamps[candidate].push(uint64(ts));
                    emit DisputeEquivocationRecorded(
                        candidate, digestA, digestB, ts
                    );
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
