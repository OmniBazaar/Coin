// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CommitteeSeedPinningLib} from "./CommitteeSeedPinningLib.sol";

/* solhint-disable max-line-length */
/* solhint-disable gas-strict-inequalities */
/* solhint-disable code-complexity */
/* solhint-disable ordering */
// ordering: _isInCommittee (pure) is grouped with the other verification
// helpers after _selectCommittee (view), matching the base contract's
// logical grouping (same disable is used in CommitteeAttestor.sol).

/**
 * @title CommitteeAttestorLib
 * @author OmniBazaar Development Team
 * @notice DELEGATECALL-linked external library holding the committee-proof
 *         verification chain extracted from {CommitteeAttestor} (VT-27
 *         EIP-170 fix). The base contract was pushed over the 24,576-byte
 *         deploy limit by the VT-27 dispute-equivocation addition, so the
 *         ~250-line verification core — `_verifyCommittee`,
 *         `_selectCommittee`, `_deriveSeed`, `_isInCommittee` — lives here
 *         and runs in the calling contract's context.
 *
 * @dev    Storage — byte-identical mirror of
 *         `CommitteeAttestor.CommitteeAttestorStorage`. The library reads
 *         the committee state via the SAME ERC-7201 slot
 *         (`omnibazaar.privacy.CommitteeAttestor`,
 *         0xfe88d9b3…83800) so it resolves to the calling proxy's own
 *         storage. All functions are `external` (linked via DELEGATECALL,
 *         so `address(this)` is the proxy and reads hit the proxy's slots).
 *         No state is declared here; the struct is a layout mirror only.
 *
 *         The proof format, digest reconstruction, and return semantics are
 *         byte-for-byte identical to the removed base functions. In
 *         particular `verifyCommittee` returns `(bool, address[])` — never
 *         reverts on a bad proof — and `committeeFor` returns an empty array
 *         on stale/missing `commitBlock` or under-sized pool. This file must
 *         never diverge from the semantics documented on the base's removed
 *         functions (see `CommitteeAttestor.sol` for the full rationale).
 */
library CommitteeAttestorLib {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ════════════════════════════════════════════════════════════════════════
    //              BYTE-IDENTICAL STORAGE LAYOUT MIRROR (NO STATE)
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Mirror of `CommitteeAttestor.CommitteeAttestorStorage`. Field
    ///      order, types, and offsets are byte-identical so reads through
    ///      the shared slot resolve to the proxy's real state. The trailing
    ///      `disputeMisbehaviorTimestamps` mapping is included for exact
    ///      layout parity (never written here — `recordDisputeEquivocation`
    ///      remains in the base).
    struct CommitteeAttestorStorage {
        uint256 committeeSize;
        uint256 quorumM;
        address[] eligibleSnapshot;
        mapping(address attester => bool inSnapshot) isInSnapshot;
        uint256 eligibleSnapshotBlock;
        uint256 eligibleSnapshotSequence;
        CommitteeSeedPinningLib.PinStore pinStore;
        bool committeeSeedPinningRequired;
        mapping(address attester => uint64[]) disputeMisbehaviorTimestamps;
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Length of one canonical ECDSA signature (r || s || v).
    uint256 internal constant SIGNATURE_LENGTH = 65;

    /// @notice Length of the `commitBlock` field at the head of every proof.
    uint256 internal constant COMMIT_BLOCK_FIELD_LENGTH = 32;

    /// @dev keccak256(abi.encode(uint256(keccak256("omnibazaar.privacy.CommitteeAttestor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _COMMITTEE_ATTESTOR_STORAGE =
        0xfe88d9b39bfa606c219219faac4fffbdae83b9dcb0e764f0507920c209d83800;

    // ════════════════════════════════════════════════════════════════════════
    //                       COMMITTEE-PROOF VERIFICATION
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify an M-of-N committee attestation over `digest`.
     * @dev Byte-for-byte the logic of `CommitteeAttestor._verifyCommittee`.
     *      Proof format (identical to L1 `RandomCommitteeVerifier.verify`):
     *
     *          proof = commitBlock(32 bytes) || sig0(65) || sig1(65) || ...
     *
     *      Number of signatures MUST be in `[quorumM, committeeSize]`.
     *      Signers MUST appear sorted ascending (dedup check). Each signer
     *      MUST be in the committee derived from
     *      `keccak256(blockhash(commitBlock), blockhash(commitBlock-1), digest)`.
     *
     *      Grinding resistance (opt-in): when the proxy's
     *      `committeeSeedPinningRequired` flag is set, the proof's
     *      `commitBlock` must equal the value pinned via
     *      {CommitteeAttestor.requestCommitteeSeed}.
     * @param digest The 32-byte message hash that signers committed to (NOT
     *        the eth-signed envelope — that wrap happens here).
     * @param proof The proof bytes as described above.
     * @return valid True if the proof verifies.
     * @return attesters The recovered attester addresses (length == sigCount).
     */
    function verifyCommittee(bytes32 digest, bytes calldata proof)
        external
        view
        returns (bool valid, address[] memory attesters)
    {
        CommitteeAttestorStorage storage $ = _getStorage();

        if (proof.length < COMMIT_BLOCK_FIELD_LENGTH + SIGNATURE_LENGTH) {
            return (false, new address[](0));
        }
        if (
            (proof.length - COMMIT_BLOCK_FIELD_LENGTH) % SIGNATURE_LENGTH != 0
        ) {
            return (false, new address[](0));
        }
        uint256 sigCount = (proof.length - COMMIT_BLOCK_FIELD_LENGTH) /
            SIGNATURE_LENGTH;
        uint256 n = $.committeeSize;
        if (sigCount < $.quorumM || sigCount > n) {
            return (false, new address[](0));
        }

        uint256 commitBlock;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            commitBlock := calldataload(proof.offset)
        }

        if (
            $.committeeSeedPinningRequired &&
            !CommitteeSeedPinningLib.matchesPin($.pinStore, digest, commitBlock)
        ) {
            return (false, new address[](0));
        }

        bytes32 seed = _deriveSeed(digest, commitBlock);
        if (seed == bytes32(0)) {
            return (false, new address[](0));
        }

        address[] memory committee = _selectCommittee($, seed, n);
        if (committee.length == 0) {
            return (false, new address[](0));
        }

        bytes32 ethSigned = digest.toEthSignedMessageHash();
        address[] memory recovered = new address[](sigCount);
        address last;
        for (uint256 i = 0; i < sigCount; ) {
            uint256 sigStart = COMMIT_BLOCK_FIELD_LENGTH +
                i *
                SIGNATURE_LENGTH;
            bytes calldata sig = proof[sigStart:sigStart + SIGNATURE_LENGTH];
            (address signer, ECDSA.RecoverError err, ) = ethSigned.tryRecover(
                sig
            );
            if (err != ECDSA.RecoverError.NoError || signer == address(0)) {
                return (false, new address[](0));
            }
            if (signer <= last) {
                return (false, new address[](0));
            }
            if (!_isInCommittee(committee, signer)) {
                return (false, new address[](0));
            }
            recovered[i] = signer;
            last = signer;
            unchecked {
                ++i;
            }
        }
        return (true, recovered);
    }

    /**
     * @notice Predict the committee for a given (digest, commitBlock). Off-
     *         chain coordinators call this to know which validators to ask
     *         for signatures. Empty array on stale/missing commitBlock or
     *         under-sized pool.
     * @dev Byte-for-byte the logic of `CommitteeAttestor.committeeFor`.
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
        CommitteeAttestorStorage storage $ = _getStorage();
        bytes32 seed = _deriveSeed(digest, commitBlock);
        if (seed == bytes32(0)) return new address[](0);
        return _selectCommittee($, seed, $.committeeSize);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              PRIVATE LOGIC
    // ════════════════════════════════════════════════════════════════════════

    function _getStorage()
        private
        pure
        returns (CommitteeAttestorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _COMMITTEE_ATTESTOR_STORAGE
        }
    }

    /**
     * @dev Multi-blockhash seed (audit H-3 mitigation from L1 verifier). A
     *      single proposer cannot bias selection without controlling two
     *      consecutive proposed blocks. Returns `bytes32(0)` on stale or
     *      unavailable block.
     */
    function _deriveSeed(bytes32 digest, uint256 commitBlock)
        private
        view
        returns (bytes32)
    {
        if (commitBlock == 0) return bytes32(0);
        bytes32 h1 = blockhash(commitBlock);
        if (h1 == bytes32(0)) return bytes32(0);
        bytes32 h2 = blockhash(commitBlock - 1);
        if (h2 == bytes32(0)) return bytes32(0);
        return keccak256(abi.encode(h1, h2, digest));
    }

    /**
     * @dev Fisher-Yates sample of `n` addresses from the eligible-set snapshot
     *      using `seed` as the RNG source. Returns the selected committee
     *      sorted ascending. Returns empty array when the pool is too small.
     */
    function _selectCommittee(
        CommitteeAttestorStorage storage $,
        bytes32 seed,
        uint256 n
    ) private view returns (address[] memory) {
        uint256 poolSize = $.eligibleSnapshot.length;
        if (poolSize == 0 || poolSize < n) {
            return new address[](0);
        }
        address[] memory pool = new address[](poolSize);
        for (uint256 i = 0; i < poolSize; ) {
            pool[i] = $.eligibleSnapshot[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < n; ) {
            // Modulo bias is acceptable: poolSize ≤ MAX_ELIGIBLE_POOL_SIZE (256),
            // and the hash space (2^256) is astronomically larger, so the bias
            // is negligible (< 2^-248 per draw).
            uint256 j = i +
                (uint256(keccak256(abi.encode(seed, i))) % (poolSize - i));
            (pool[i], pool[j]) = (pool[j], pool[i]);
            unchecked {
                ++i;
            }
        }
        address[] memory committee = new address[](n);
        for (uint256 i = 0; i < n; ) {
            committee[i] = pool[i];
            unchecked {
                ++i;
            }
        }
        // Insertion sort — n ≤ MAX_COMMITTEE_SIZE = 31, O(n²) acceptable.
        for (uint256 i = 1; i < n; ) {
            address key = committee[i];
            uint256 k = i;
            while (k > 0 && committee[k - 1] > key) {
                committee[k] = committee[k - 1];
                unchecked {
                    --k;
                }
            }
            committee[k] = key;
            unchecked {
                ++i;
            }
        }
        return committee;
    }

    /// @dev Binary search for `addr` in the sorted `committee`.
    function _isInCommittee(address[] memory committee, address addr)
        private
        pure
        returns (bool)
    {
        uint256 lo = 0;
        uint256 hi = committee.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (committee[mid] == addr) return true;
            if (committee[mid] < addr) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return false;
    }
}
