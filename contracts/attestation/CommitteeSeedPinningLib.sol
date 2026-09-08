// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable gas-strict-inequalities */
// gas-strict-inequalities: the abandoned-pin check is an inclusive
// "still within window" range comparison — strict `<` would change
// behavior (a pin abandoned exactly at the boundary block must stay
// replaceable).

/**
 * @title CommitteeSeedPinningLib
 * @author OmniBazaar Development Team
 * @notice Grinding-resistant companion to the Fisher-Yates committee
 *         selection used by {CommitteeAttestor} and
 *         {RandomCommitteeVerifierV2}. Pins the FUTURE block whose hash will
 *         seed committee selection for a given digest, so the seed cannot be
 *         chosen from an already-mined set of candidates.
 *
 * @dev Problem this closes (tracked as `security_committee_grinding_gap`,
 *      TODO.md `COMMITTEE-GRINDING`). Both {CommitteeAttestor} and
 *      `RandomCommitteeVerifier` v1 derive their selection seed from
 *      `blockhash(commitBlock)` where `commitBlock` is a value the PROVER
 *      supplies at verify-time, freely chosen from any of the last ~256
 *      mined blocks. A submitter — or a colluding minority of the eligible
 *      pool — can enumerate all ~256 already-known blockhashes via the
 *      public `committeeFor(digest, commitBlock)` view, pick whichever one
 *      seats >= M of their own members, and have those members sign on
 *      demand (ECDSA signing takes microseconds; it needs no prior
 *      commitment). Binding the signed digest to `commitBlock` does NOT
 *      close this on its own — it only stops signatures from being
 *      REPLAYED across different `commitBlock`s by someone who doesn't hold
 *      the signing key; it does nothing to stop the colluding signers
 *      themselves from producing a fresh signature for whichever
 *      `commitBlock` the attack selects. This gap is INERT only while
 *      `poolSize == committeeSize` (launch config, 5 validators) —
 *      degenerate case, every possible seed yields the same committee (the
 *      whole pool). It becomes live risk the moment the eligible pool grows
 *      past the committee size.
 *
 *      Fix. Require the digest's `commitBlock` to be PINNED on-chain,
 *      before its hash exists, via {pin}. `pin` sets
 *      `pinnedBlock = block.number + delay` (delay >= {MIN_PIN_DELAY}) — a
 *      value nobody, not even the pinner, can predict the blockhash of yet.
 *      The consumer then requires (at verify-time) that the proof's
 *      `commitBlock` equal exactly the pinned value — removing the
 *      "choose from N known candidates" degree of freedom entirely.
 *
 *      Residual. A would-be attacker can still elect not to complete a
 *      pinned flow if the resulting committee (revealed once the pinned
 *      block mines) isn't to their liking — a liveness/griefing residual,
 *      not a security compromise (same class as every commit-reveal /
 *      RANDAO-style design). This matches the system's existing trust
 *      model, where the worst case for a censoring party is liveness, never
 *      theft (see memory `private_dex_committee_architecture_2026-06-18`).
 *
 *      The existing multi-blockhash mitigation
 *      (`h1 = blockhash(commitBlock)`, `h2 = blockhash(commitBlock - 1)`,
 *      audit H-3) is orthogonal and stays in place in both consumers — it
 *      stops a single block PROPOSER from biasing the pinned block's own
 *      hash; this library stops the PROVER from choosing among many
 *      already-known hashes. Composing both closes the full class:
 *      grinding requires colluding across two consecutive block proposers
 *      AND being able to predict the outcome before it is pinned, which are
 *      now mutually exclusive.
 *
 *      No linking required — every function here is `internal` and takes
 *      the caller's own storage struct by reference, so it inlines into the
 *      consuming contract exactly like `EnumerableSet`. Safe to add to an
 *      already-deployed ERC-7201 namespaced storage struct: {PinStore} is
 *      appended at the END of the consumer's struct, never inserted, so no
 *      existing field's slot offset changes.
 */
library CommitteeSeedPinningLib {
    // ════════════════════════════════════════════════════════════════════
    //                                STORAGE
    // ════════════════════════════════════════════════════════════════════

    /// @notice One pinned-block record per digest.
    struct PinStore {
        mapping(bytes32 digest => uint256 pinnedBlock) pinnedBlock;
        mapping(bytes32 digest => bool isPinned) isPinned;
    }

    // ════════════════════════════════════════════════════════════════════
    //                               CONSTANTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Minimum blocks of lead time between {pin} and the pinned
    ///         block. MUST be >= 1 so the pinned block's hash is
    ///         unknowable at pin time.
    uint256 internal constant MIN_PIN_DELAY = 1;

    /// @notice Blocks after which an unused pin is considered abandoned and
    ///         may be replaced by a fresh {pin} call. Matches the 256-block
    ///         `blockhash` availability window the consumer's own
    ///         staleness check already relies on — after this many blocks
    ///         the old pin can never verify successfully anyway, so
    ///         refusing to let it be replaced would only create a
    ///         permanent dead digest.
    uint256 internal constant PIN_ABANDONED_AFTER = 256;

    // ════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted whenever a digest is (re-)pinned to a future block.
     * @param digest The message digest the pin covers.
     * @param pinnedBlock The future block number whose hash will seed
     *        committee selection for `digest`.
     */
    event CommitteeSeedPinned(bytes32 indexed digest, uint256 indexed pinnedBlock);

    // ════════════════════════════════════════════════════════════════════
    //                                 ERRORS
    // ════════════════════════════════════════════════════════════════════

    error DigestAlreadyPinned(bytes32 digest, uint256 existingBlock);
    error PinDelayTooShort(uint256 delay);

    // ════════════════════════════════════════════════════════════════════
    //                                  LOGIC
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Pin the future block whose hash will seed committee selection
     *         for `digest`. Permissionless — anyone may pin (typically the
     *         off-chain coordinator that will go on to collect committee
     *         signatures). Reverts if `digest` already has a live
     *         (non-abandoned) pin.
     * @param self Storage pointer to the consumer's pin store.
     * @param digest The message digest a future proof will cover.
     * @param delay Blocks of lead time; MUST be >= {MIN_PIN_DELAY}.
     * @return pinnedBlock The block number whose hash will seed selection.
     */
    function pin(PinStore storage self, bytes32 digest, uint256 delay)
        internal
        returns (uint256 pinnedBlock)
    {
        if (delay < MIN_PIN_DELAY) revert PinDelayTooShort(delay);
        if (self.isPinned[digest]) {
            uint256 existing = self.pinnedBlock[digest];
            if (block.number <= existing + PIN_ABANDONED_AFTER) {
                revert DigestAlreadyPinned(digest, existing);
            }
            // Abandoned — fall through and overwrite.
        }
        pinnedBlock = block.number + delay;
        self.pinnedBlock[digest] = pinnedBlock;
        self.isPinned[digest] = true;
        emit CommitteeSeedPinned(digest, pinnedBlock);
    }

    /**
     * @notice Read the pinned block for `digest`, if any.
     * @param self Storage pointer to the consumer's pin store.
     * @param digest The message digest to look up.
     * @return pinnedBlock The pinned block number (0 if never pinned).
     * @return isPinned True if a pin has been recorded (does not imply the
     *         block has been mined yet, nor that it hasn't expired).
     */
    function get(PinStore storage self, bytes32 digest)
        internal
        view
        returns (uint256 pinnedBlock, bool isPinned)
    {
        return (self.pinnedBlock[digest], self.isPinned[digest]);
    }

    /**
     * @notice True iff `commitBlock` is exactly the live pin recorded for
     *         `digest`. The single check every `verify`/`_verifyCommittee`
     *         call gates on once pinning is required.
     * @param self Storage pointer to the consumer's pin store.
     * @param digest The message digest the proof covers.
     * @param commitBlock The `commitBlock` field carried in the proof.
     * @return True iff a pin exists for `digest` and equals `commitBlock`.
     */
    function matchesPin(
        PinStore storage self,
        bytes32 digest,
        uint256 commitBlock
    ) internal view returns (bool) {
        if (!self.isPinned[digest]) return false;
        return self.pinnedBlock[digest] == commitBlock;
    }
}
