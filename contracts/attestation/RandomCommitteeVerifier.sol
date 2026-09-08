// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";

/* solhint-disable max-line-length */

/**
 * @title RandomCommitteeVerifier
 * @author OmniBazaar Development Team
 * @notice Phase 2 trustless attestation verifier for `OmniRegistration` (KYC + AML).
 *         Replaces the single `trustedVerificationKey` model with a randomized
 *         M-of-N validator committee drawn from an on-chain eligibility pool.
 *
 * @dev Implements {IBridgeVerifier} so `OmniRegistration` can swap verifiers
 *      under governance + timelock without changing its consumer code.
 *
 *      ## Design (per Phase 2 architecture decision 2026-05-18)
 *
 *      Trust model. The verifier asserts that an attestation was endorsed by a
 *      supermajority (default 4 of 5) of a randomly-selected committee, drawn
 *      from a pool of eligible attesters. Pool membership is computed from
 *      existing on-chain state — it is NOT a maintained allowlist:
 *        - `Bootstrap.isNodeActive(addr)` returns true for nodeType == 0
 *          (gateway validator with live heartbeat)
 *        - `IOmniRegistrationReader.getRegistration(addr).kycTier >= minKycTier`
 *        - `IOmniCoreStakingReader.getStake(addr).amount >= minStake AND active`
 *
 *      A permissionless `refreshEligibleSet()` recomputes the snapshot any time
 *      the on-chain truth has changed. The snapshot is cached so per-`verify()`
 *      gas stays bounded.
 *
 *      Committee selection. Per attestation, the proof carries a `commitBlock`
 *      number in its first 32 bytes. The verifier derives a seed
 *        seed = keccak256(blockhash(commitBlock), messageHash)
 *      and runs a Fisher-Yates sample of `committeeSize` validators from the
 *      eligible snapshot. `blockhash` returns zero for blocks older than 256
 *      so proofs expire ~8 min after the commit block — prevents adaptive
 *      committee-bribing.
 *
 *      Signature verification. Lifted from `Ecdsa5of5AttestationVerifier`:
 *      sorted-ascending-unique signers, ethSigned envelope, tryRecover for
 *      uniform-error semantics.
 *
 *      Commit-block binding (audit H-06, v2). Committee members sign
 *        keccak256(abi.encode(messageHash, commitBlock))
 *      instead of `messageHash` alone, so a signature is only valid for the
 *      ONE committee-selection block its signer committed to. Without the
 *      binding, a submitter holding honestly-produced signatures could grind
 *      the ~255 recent `commitBlock` values post-hoc until the derived
 *      committee consisted of exactly the signers in hand, defeating the
 *      randomization. During the migration window the verifier also accepts
 *      the legacy unbound form (`legacySignaturesAccepted`, one-way
 *      disable via {disableLegacySignatures}) so the off-chain signer fleet
 *      can cut over without breaking live KYC attestations.
 *
 *      Slashing. The verifier exposes `verifyVeto` for single-signer fraud
 *      proofs (same shape as the bridge verifier). The actual stake-slash is
 *      done by an off-chain handler (or a future `AttestationFraudHandler`
 *      contract) calling `OmniCore.slash` — out of this contract's scope.
 *
 *      Governance. Owner is intended to be `OmniTimelockController`. Owner
 *      calls `setParameters` (M, N, minKycTier, minStake) via a 7-day
 *      timelock proposal. The dependency-contract addresses (Bootstrap,
 *      OmniCore, OmniRegistration) are set ONCE at construction and never
 *      mutated — swap requires a verifier redeploy and a Timelock-gated
 *      `OmniRegistration.setAttestationVerifier` call.
 */
contract RandomCommitteeVerifier is IBridgeVerifier, Ownable2Step {
    using ECDSA for bytes32;

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Length of one canonical ECDSA signature (r || s || v).
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @notice Length of the `commitBlock` field at the head of every proof.
    uint256 public constant COMMIT_BLOCK_FIELD_LENGTH = 32;

    /// @notice Lower bound on committee size. Below this, randomized
    ///         selection provides no meaningful security; reject outright.
    uint256 public constant MIN_COMMITTEE_SIZE = 3;

    /// @notice Upper bound on committee size. Above this, calldata for the
    ///         proof grows beyond a reasonable single-tx budget and the
    ///         verifier becomes the bottleneck. A future BLS-aggregating
    ///         verifier can raise this; here we cap conservatively.
    uint256 public constant MAX_COMMITTEE_SIZE = 31;

    /// @notice Hard floor on `minKycTier`. Governance can raise the bar
    ///         via {setParameters}, never lower it below this constant.
    ///         Per `decision_validator_kyc_tier3_final`: Tier 3 (Persona
    ///         Identity) is the FINAL validator KYC requirement.
    ///         Audit finding M-5 / F-10 remediation.
    uint256 public constant MIN_KYC_TIER_FLOOR = 3;

    /// @notice Maximum addresses we'll iterate from Bootstrap when refreshing
    ///         the eligible-set snapshot. Bounds the gas cost of a refresh.
    ///         Above this, refresh paginates (caller invokes repeatedly).
    uint256 public constant MAX_REFRESH_BATCH = 256;

    // ════════════════════════════════════════════════════════════════════════
    //                          DEPENDENCY CONTRACTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Bootstrap contract used to check active-heartbeat + node type.
    IBootstrapReader public immutable bootstrap;

    /// @notice OmniCore (or staking-pool reader) used for stake lookup.
    IOmniCoreStakingReader public immutable omniCore;

    /// @notice OmniRegistration used for KYC-tier lookup.
    IOmniRegistrationReader public immutable omniRegistration;

    // ════════════════════════════════════════════════════════════════════════
    //                       GOVERNANCE-ROTATABLE PARAMETERS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Number of validators in each attestation committee.
    uint256 public committeeSize;

    /// @notice Minimum signatures required from the committee for valid quorum.
    ///         MUST satisfy `quorumThreshold * 3 >= committeeSize * 2`
    ///         (≥ ⌈2N/3⌉ supermajority).
    uint256 public quorumM;

    /// @notice Minimum KYC tier required to be eligible. Per
    ///         `decision_validator_kyc_tier3_final`, this is 3.
    uint256 public minKycTier;

    /// @notice Minimum stake (in wei, 1e18 = 1 XOM) required to be eligible.
    ///         Initial: 1,000,000 XOM = 1e24.
    uint256 public minStake;

    /// @notice Audit H-06 migration toggle: while true, {verify} also
    ///         accepts the legacy v1 signature form (signers signed
    ///         `messageHash` alone, not bound to `commitBlock`). One-way
    ///         disabled via {disableLegacySignatures} once the off-chain
    ///         signer fleet produces commit-block-bound signatures.
    bool public legacySignaturesAccepted = true;

    // ════════════════════════════════════════════════════════════════════════
    //                          ELIGIBLE-POOL SNAPSHOT
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Snapshot of eligible attester addresses, sorted ascending.
    address[] private _eligibleSnapshot;

    /// @notice Block number at which `_eligibleSnapshot` was last refreshed.
    uint256 public eligibleSnapshotBlock;

    /// @notice O(1) membership-lookup for the current snapshot.
    mapping(address attester => bool inSnapshot) private _isInSnapshot;

    // ════════════════════════════════════════════════════════════════════════
    //                                  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when the eligible-pool snapshot is recomputed.
    /// @param poolSize Number of validators in the new snapshot.
    /// @param refreshedAt Block number at which the refresh ran.
    event EligibleSetRefreshed(uint256 poolSize, uint256 refreshedAt);

    /// @notice Emitted when governance updates verifier parameters.
    /// @param committeeSize New `committeeSize`.
    /// @param quorumM New `quorumM`.
    /// @param minKycTier New `minKycTier`.
    /// @param minStake New `minStake`.
    event ParametersUpdated(
        uint256 committeeSize,
        uint256 quorumM,
        uint256 minKycTier,
        uint256 minStake
    );

    /// @notice Emitted when the legacy (unbound) signature form is
    ///         permanently disabled (audit H-06 migration complete).
    /// @param disabledAt Block number of the disable.
    event LegacySignaturesDisabled(uint256 disabledAt);

    // ════════════════════════════════════════════════════════════════════════
    //                                  ERRORS
    // ════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error CommitteeSizeOutOfRange(uint256 size);
    error QuorumBelowSupermajority(uint256 m, uint256 n);
    /// @notice Quorum threshold exceeds committee size (m > n).
    error QuorumExceedsCommittee(uint256 m, uint256 n);
    /// @notice Minimum KYC tier below the hardcoded `MIN_KYC_TIER_FLOOR`.
    error MinKycTierBelowFloor(uint256 attempted);
    error ProofTooShort(uint256 length);
    error ProofWrongLength(uint256 length);
    error EligibleSnapshotEmpty();
    error EligibleSnapshotTooSmall(uint256 poolSize, uint256 committeeSize);
    error StaleCommitBlock(uint256 commitBlock);

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialise the verifier with its dependency contracts and
     *         initial governance parameters.
     * @param owner_ Initial owner (intended: OmniTimelockController).
     * @param bootstrap_ Bootstrap contract address.
     * @param omniCore_ OmniCore (staking-info reader) address.
     * @param omniRegistration_ OmniRegistration address.
     * @param initialCommitteeSize Initial N (e.g. 5).
     * @param initialQuorumM Initial M (e.g. 4). Must be ≥ ⌈2N/3⌉.
     * @param initialMinKycTier Initial minimum KYC tier (e.g. 3).
     * @param initialMinStake Initial minimum stake in wei (e.g. 1e24).
     */
    constructor(
        address owner_,
        address bootstrap_,
        address omniCore_,
        address omniRegistration_,
        uint256 initialCommitteeSize,
        uint256 initialQuorumM,
        uint256 initialMinKycTier,
        uint256 initialMinStake
    ) Ownable(owner_) {
        if (
            owner_ == address(0) ||
            bootstrap_ == address(0) ||
            omniCore_ == address(0) ||
            omniRegistration_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _validateParameters(
            initialCommitteeSize,
            initialQuorumM,
            initialMinKycTier
        );
        bootstrap = IBootstrapReader(bootstrap_);
        omniCore = IOmniCoreStakingReader(omniCore_);
        omniRegistration = IOmniRegistrationReader(omniRegistration_);
        committeeSize = initialCommitteeSize;
        quorumM = initialQuorumM;
        minKycTier = initialMinKycTier;
        minStake = initialMinStake;
    }

    // ════════════════════════════════════════════════════════════════════════
    //                       GOVERNANCE PARAMETER UPDATES
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update governance-controlled parameters atomically. Caller
     *         MUST be the owner (Timelock).
     * @param newCommitteeSize New N. Must be in [MIN_COMMITTEE_SIZE, MAX_COMMITTEE_SIZE].
     * @param newQuorumM New M. Must satisfy `newQuorumM * 3 >= newCommitteeSize * 2`.
     * @param newMinKycTier New minimum KYC tier (0-4).
     * @param newMinStake New minimum stake (wei, 1e18 = 1 XOM).
     */
    function setParameters(
        uint256 newCommitteeSize,
        uint256 newQuorumM,
        uint256 newMinKycTier,
        uint256 newMinStake
    ) external onlyOwner {
        _validateParameters(newCommitteeSize, newQuorumM, newMinKycTier);
        committeeSize = newCommitteeSize;
        quorumM = newQuorumM;
        minKycTier = newMinKycTier;
        minStake = newMinStake;
        emit ParametersUpdated(
            newCommitteeSize,
            newQuorumM,
            newMinKycTier,
            newMinStake
        );
    }

    /**
     * @notice Permanently disable acceptance of legacy (unbound) v1
     *         signatures (audit H-06)
     * @dev One-way: there is deliberately no re-enable. Call ONLY after
     *      every committee signer produces commit-block-bound signatures
     *      and in-flight legacy attestations have drained — flipping
     *      early breaks live KYC attestation verification.
     */
    function disableLegacySignatures() external onlyOwner {
        legacySignaturesAccepted = false;
        emit LegacySignaturesDisabled(block.number);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                       ELIGIBLE-SET SNAPSHOT MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Refresh the eligible-pool snapshot from current on-chain state.
     * @dev Permissionless. Anyone can pay the gas to recompute the snapshot.
     *      Walks `Bootstrap.getActiveGatewayValidators` (paginated to
     *      MAX_REFRESH_BATCH) and filters each candidate via
     *      {isEligibleAttester}. The result is sorted ascending so the proof-
     *      side sorted-unique check works in O(N) (vs O(N²) without sort).
     *
     *      Snapshot is durable until the next call. Validators that fall
     *      below criteria (stake slashed, KYC expired, heartbeat dropped)
     *      remain in the snapshot until someone refreshes it — same as the
     *      bridge's batch-rotation pattern. Refresh is cheap (~200K gas at
     *      pool size 5; ~1M gas at pool size 50).
     */
    function refreshEligibleSet() external {
        // `getActiveNodes(0, limit)` returns gateway-validator addresses only.
        address[] memory candidates = bootstrap.getActiveNodes(
            0,
            MAX_REFRESH_BATCH
        );
        uint256 candidateCount = candidates.length;
        address[] memory filtered = new address[](candidateCount);
        uint256 filteredCount = 0;
        for (uint256 i = 0; i < candidateCount; ) {
            address addr = candidates[i];
            if (_isEligible(addr)) {
                filtered[filteredCount] = addr;
                unchecked {
                    ++filteredCount;
                }
            }
            unchecked {
                ++i;
            }
        }
        // Trim to actual size.
        address[] memory toSort = new address[](filteredCount);
        for (uint256 i = 0; i < filteredCount; ) {
            toSort[i] = filtered[i];
            unchecked {
                ++i;
            }
        }
        // Audit M-3: sort in MEMORY (O(N log N) heuristic via insertion
        // sort on small N — N ≤ MAX_REFRESH_BATCH = 256). Storage writes
        // happen exactly once per slot. Pre-fix cost: O(N²) storage writes
        // (~330M gas at N=256, unconfirmable). Post-fix cost: ~N storage
        // writes (~25K gas × N = ~6.4M gas at N=256). The insertion-sort
        // step is in-memory and cheap.
        _insertionSortMemory(toSort);

        // Clear the old snapshot membership lookup.
        uint256 oldLen = _eligibleSnapshot.length;
        for (uint256 i = 0; i < oldLen; ) {
            _isInSnapshot[_eligibleSnapshot[i]] = false;
            unchecked {
                ++i;
            }
        }
        delete _eligibleSnapshot;

        // Bulk-write the sorted snapshot. Each slot written exactly once.
        for (uint256 i = 0; i < filteredCount; ) {
            address addr = toSort[i];
            _eligibleSnapshot.push(addr);
            _isInSnapshot[addr] = true;
            unchecked {
                ++i;
            }
        }
        eligibleSnapshotBlock = block.number;
        emit EligibleSetRefreshed(filteredCount, block.number);
    }

    /**
     * @dev In-memory insertion sort. N ≤ 256 in practice (capped by
     *      MAX_REFRESH_BATCH), so O(N²) at ~30 gas/compare is acceptable
     *      (~2M gas at the cap). Audit M-3 — replaced storage-resident sort.
     */
    function _insertionSortMemory(address[] memory arr) private pure {
        uint256 len = arr.length;
        for (uint256 i = 1; i < len; ) {
            address key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                unchecked {
                    --j;
                }
            }
            arr[j] = key;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Live check whether `account` would qualify for the pool right
     *         now. Independent of the cached snapshot.
     * @param account Address to test.
     * @return True if eligible.
     */
    function isEligibleNow(address account) external view returns (bool) {
        return _isEligible(account);
    }

    /**
     * @notice Read the current eligible-pool snapshot (sorted ascending).
     * @return Array of eligible attester addresses.
     */
    function eligibleSnapshot() external view returns (address[] memory) {
        return _eligibleSnapshot;
    }

    /**
     * @notice Length of the current eligible-pool snapshot.
     * @dev Cheaper than {eligibleSnapshot} when callers only need the count
     *      (e.g. `OmniRegistration.setAttestationVerifier` brick-prevention
     *      check per audit finding H-4).
     */
    function eligibleSnapshotLength() external view returns (uint256) {
        return _eligibleSnapshot.length;
    }

    /**
     * @notice Predict the committee for a given (messageHash, commitBlock).
     * @dev Off-chain coordinators call this to know which validators to ask
     *      for signatures. Audit H-3 mitigation: seed is derived from TWO
     *      consecutive blockhashes (commitBlock and commitBlock-1) so a
     *      single block-proposer cannot bias selection without controlling
     *      two consecutive proposed blocks.
     *
     *      Audit L-2 unification: returns empty array on stale block
     *      (matching {verify}'s `(false, [])` behavior). Caller checks
     *      `committee.length == 0` for the staleness condition.
     * @param messageHash Same messageHash that will be passed to {verify}.
     * @param commitBlock The commit-block field that will be packed at the
     *        head of the proof.
     * @return committee The sorted committee addresses (length == committeeSize),
     *         OR empty array if commitBlock is stale / out of range.
     */
    function committeeFor(bytes32 messageHash, uint256 commitBlock)
        external
        view
        returns (address[] memory committee)
    {
        bytes32 seed = _deriveSeed(messageHash, commitBlock);
        if (seed == bytes32(0)) return new address[](0); // stale block
        return _selectCommittee(seed, committeeSize);
    }

    /**
     * @dev Derive the committee-selection seed from two consecutive
     *      blockhashes + the message hash. Audit H-3: pairing two blocks
     *      means a single proposer cannot grind committee selection in one
     *      block; collusion across two consecutive proposers is required.
     *      Returns `bytes32(0)` when EITHER blockhash is unavailable
     *      (`blockhash` returns zero for blocks older than 256 OR for
     *      blocks not yet mined / equal to current).
     */
    function _deriveSeed(bytes32 messageHash, uint256 commitBlock)
        private
        view
        returns (bytes32)
    {
        if (commitBlock == 0) return bytes32(0);
        bytes32 h1 = blockhash(commitBlock);
        if (h1 == bytes32(0)) return bytes32(0);
        bytes32 h2 = blockhash(commitBlock - 1);
        if (h2 == bytes32(0)) return bytes32(0);
        return keccak256(abi.encode(h1, h2, messageHash));
    }

    // ════════════════════════════════════════════════════════════════════════
    //                          IBridgeVerifier IMPLEMENTATION
    // ════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IBridgeVerifier
    function verifierVersion() external pure override returns (string memory) {
        return "random-committee-ecdsa-v2";
    }

    /// @inheritdoc IBridgeVerifier
    function quorumThreshold() external view override returns (uint256) {
        return quorumM;
    }

    // Audit Pass-2 H-NEW-1: the gateway reads committee size (N) via
    // staticcall `committeeSize()`. Solidity auto-generates that getter
    // from the public `uint256 public committeeSize` state variable
    // declared above; no explicit function declaration is needed.

    /// @inheritdoc IBridgeVerifier
    function isValidator(address account) external view override returns (bool) {
        if (account == address(0)) return false;
        return _isInSnapshot[account];
    }

    /**
     * @inheritdoc IBridgeVerifier
     * @dev Proof format:
     *        proof = commitBlock(32 bytes) || sig0(65) || sig1(65) || ...
     *
     *        - commitBlock MUST resolve to a non-zero blockhash (i.e. within
     *          the last 256 blocks).
     *        - Number of signatures MUST equal committeeSize OR be in
     *          [quorumM, committeeSize] (≥ M, ≤ N).
     *        - Signers MUST appear sorted ascending (dedup check).
     *        - Each signer MUST be in the committee derived from
     *          keccak256(blockhash(commitBlock), messageHash).
     *        - Audit H-06 (v2): signatures MUST be over
     *          keccak256(abi.encode(messageHash, commitBlock)) — binding
     *          each signature to the ONE committee-selection block its
     *          signer committed to, so honestly-produced signatures cannot
     *          be replayed under a post-hoc-ground commitBlock. While
     *          `legacySignaturesAccepted` is true the unbound v1 form
     *          (signature over `messageHash` alone) is also accepted as a
     *          migration fallback; the whole proof must use ONE form.
     */
    function verify(bytes32 messageHash, bytes calldata proof)
        external
        view
        override
        returns (bool valid, address[] memory attesters)
    {
        // Parse: first 32 bytes commitBlock, rest signatures.
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
        uint256 n = committeeSize;
        if (sigCount < quorumM || sigCount > n) {
            return (false, new address[](0));
        }

        uint256 commitBlock;
        assembly {
            commitBlock := calldataload(proof.offset)
        }

        // Audit H-3: multi-blockhash seed (commitBlock + commitBlock-1).
        // Returns bytes32(0) on stale or invalid block.
        bytes32 seed = _deriveSeed(messageHash, commitBlock);
        if (seed == bytes32(0)) {
            return (false, new address[](0));
        }

        // Resolve committee.
        address[] memory committee = _selectCommittee(seed, n);
        if (committee.length == 0) {
            return (false, new address[](0));
        }

        // Audit H-06: bound form first — signers commit to commitBlock.
        bytes32 boundHash = keccak256(abi.encode(messageHash, commitBlock));
        (valid, attesters) = _recoverCommitteeSignatures(
            boundHash,
            committee,
            proof,
            sigCount
        );
        if (valid) {
            return (valid, attesters);
        }

        // Migration fallback: legacy v1 form (unbound). One-way disabled
        // via {disableLegacySignatures} after the signer fleet cuts over.
        if (legacySignaturesAccepted) {
            return
                _recoverCommitteeSignatures(
                    messageHash,
                    committee,
                    proof,
                    sigCount
                );
        }
        return (false, new address[](0));
    }

    /**
     * @notice Recover and validate every committee signature in `proof`
     *         against one signed digest
     * @dev Standard sorted-ascending dedup (lifted from
     *      Ecdsa5of5AttestationVerifier:147-167). Audit H-1: re-checks
     *      live eligibility per-signer so a slashed/unstaked validator
     *      who hasn't yet been refreshed out of the snapshot cannot
     *      still sign valid attestations.
     * @param signedHash The raw digest the committee signed (bound v2
     *        form or legacy v1 `messageHash`) — wrapped in the EIP-191
     *        envelope here.
     * @param committee Committee derived for this (messageHash,
     *        commitBlock) pair.
     * @param proof Full proof blob (commitBlock prefix + signatures).
     * @param sigCount Number of signatures in the proof.
     * @return valid True when every signature recovers to a distinct,
     *         sorted, committee-member, still-eligible signer.
     * @return attesters Recovered signer addresses (empty on failure).
     */
    function _recoverCommitteeSignatures(
        bytes32 signedHash,
        address[] memory committee,
        bytes calldata proof,
        uint256 sigCount
    ) internal view returns (bool valid, address[] memory attesters) {
        bytes32 ethSigned = _toEthSignedMessageHash(signedHash);
        address[] memory recovered = new address[](sigCount);
        address last;
        for (uint256 i = 0; i < sigCount; ) {
            uint256 sigStart = COMMIT_BLOCK_FIELD_LENGTH + i * SIGNATURE_LENGTH;
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
            // Audit H-1: live eligibility check. Snapshot may include
            // validators who have since been slashed / unstaked /
            // KYC-revoked / heartbeat-dropped; reject their signatures
            // even if they're in the cached committee.
            if (!_isEligible(signer)) {
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
     * @inheritdoc IBridgeVerifier
     * @dev `fraudProof` is a single 65-byte ECDSA signature; signer must be in
     *      the current eligible-snapshot. Returned for off-chain slashing.
     */
    function verifyVeto(bytes32 vetoHash, bytes calldata fraudProof)
        external
        view
        override
        returns (bool valid, address signer)
    {
        if (fraudProof.length != SIGNATURE_LENGTH) {
            return (false, address(0));
        }
        bytes32 ethSigned = _toEthSignedMessageHash(vetoHash);
        (address recovered, ECDSA.RecoverError err, ) = ethSigned.tryRecover(
            fraudProof
        );
        if (err != ECDSA.RecoverError.NoError || recovered == address(0)) {
            return (false, address(0));
        }
        if (!_isInSnapshot[recovered]) {
            return (false, address(0));
        }
        return (true, recovered);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              PRIVATE LOGIC
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @dev Validate (N, M, minKycTier) parameters. Used by constructor +
     *      setParameters.
     *
     *      Floor on `minKycTier`: per `decision_validator_kyc_tier3_final`,
     *      Tier 3 (Persona Identity) is the FINAL validator KYC requirement.
     *      Governance can raise it, never lower it. Codifying the floor on-
     *      chain makes the invariant violation impossible even under a
     *      compromised Timelock.
     */
    function _validateParameters(
        uint256 n,
        uint256 m,
        uint256 minTier
    ) private pure {
        if (n < MIN_COMMITTEE_SIZE || n > MAX_COMMITTEE_SIZE) {
            revert CommitteeSizeOutOfRange(n);
        }
        // M ≥ ⌈2N/3⌉  ↔  3M ≥ 2N  (supermajority threshold).
        if (m * 3 < n * 2) revert QuorumBelowSupermajority(m, n);
        if (m > n) revert QuorumExceedsCommittee(m, n);
        // Hardcoded Tier-3 floor — audit finding M-5 / F-10 remediation.
        if (minTier < MIN_KYC_TIER_FLOOR) revert MinKycTierBelowFloor(minTier);
    }

    /**
     * @dev Live eligibility check against the three dependency contracts.
     */
    function _isEligible(address account) private view returns (bool) {
        if (account == address(0)) return false;

        (bool active, uint8 nodeType) = bootstrap.isNodeActive(account);
        if (!active || nodeType != 0) return false;

        IOmniRegistrationReader.Registration memory reg =
            omniRegistration.getRegistration(account);
        if (uint256(reg.kycTier) < minKycTier) return false;

        IOmniCoreStakingReader.Stake memory s = omniCore.getStake(account);
        if (!s.active) return false;
        if (s.amount < minStake) return false;

        return true;
    }

    /**
     * @dev Fisher-Yates sample of `n` indices from the eligible snapshot,
     *      using `seed` as the RNG source. Returns sorted-ascending committee.
     *      Returns empty array on snapshot-too-small.
     */
    function _selectCommittee(bytes32 seed, uint256 n)
        private
        view
        returns (address[] memory)
    {
        uint256 poolSize = _eligibleSnapshot.length;
        if (poolSize < n || poolSize == 0) {
            return new address[](0);
        }
        // Copy the snapshot into a memory pool we can shuffle.
        address[] memory pool = new address[](poolSize);
        for (uint256 i = 0; i < poolSize; ) {
            pool[i] = _eligibleSnapshot[i];
            unchecked {
                ++i;
            }
        }
        // Fisher-Yates: for i in 0..n, swap pool[i] with pool[rand(i,poolSize)]
        // using `seed` rotated by index to derive each random pick.
        for (uint256 i = 0; i < n; ) {
            uint256 j = i +
                (
                    uint256(keccak256(abi.encode(seed, i))) %
                        (poolSize - i)
                );
            (pool[i], pool[j]) = (pool[j], pool[i]);
            unchecked {
                ++i;
            }
        }
        // Take pool[0..n] and sort ascending.
        address[] memory committee = new address[](n);
        for (uint256 i = 0; i < n; ) {
            committee[i] = pool[i];
            unchecked {
                ++i;
            }
        }
        // Insertion sort — n ≤ MAX_COMMITTEE_SIZE = 31, so O(n²) is fine.
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

    /**
     * @dev Binary search for `addr` in the sorted `committee`.
     */
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

    /**
     * @dev `eth_sign` envelope so off-chain signers can use standard wallets.
     */
    function _toEthSignedMessageHash(bytes32 messageHash)
        private
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
            );
    }
}

// ════════════════════════════════════════════════════════════════════════════
//                          MINIMAL DEPENDENCY READERS
// ════════════════════════════════════════════════════════════════════════════
//
// Narrow interfaces to keep the verifier independent of the rest of the
// codebase. Each upstream contract already exposes these in its public ABI;
// we declare locally so the verifier compiles against an interface and the
// upstream impls can evolve.

/**
 * @notice Minimal subset of Bootstrap.sol we read.
 */
interface IBootstrapReader {
    /// @return isActive Whether the node is registered + active.
    /// @return nodeType 0 = gateway validator, 1+ = other tiers.
    function isNodeActive(address nodeAddress)
        external
        view
        returns (bool isActive, uint8 nodeType);

    /// @notice Paginated active-node list filtered by `nodeType`.
    /// @dev Verifier passes `nodeType=0` to get gateway validators only.
    ///      See `Bootstrap.getActiveNodes` (lines 480-514).
    function getActiveNodes(uint8 nodeType, uint256 limit)
        external
        view
        returns (address[] memory);
}

/**
 * @notice Minimal subset of OmniCore (or staking-pool reader) we read.
 */
interface IOmniCoreStakingReader {
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }
    function getStake(address user) external view returns (Stake memory);
}

/**
 * @notice Minimal subset of OmniRegistration we read.
 * @dev `Registration` MUST match the upstream `OmniRegistration.Registration`
 *      field-for-field, in order, or the ABI decode misaligns and we read
 *      wrong fields. Verified against `OmniRegistration.sol:116-125`
 *      2026-05-18.
 */
interface IOmniRegistrationReader {
    struct Registration {
        uint256 timestamp;
        address referrer;
        address registeredBy;
        bytes32 phoneHash;
        bytes32 emailHash;
        uint8 kycTier;
        bool welcomeBonusClaimed;
        bool firstSaleBonusClaimed;
    }
    function getRegistration(address user)
        external
        view
        returns (Registration memory);
}
