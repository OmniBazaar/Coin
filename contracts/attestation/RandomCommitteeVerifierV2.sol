// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";
import {CommitteeSeedPinningLib} from "./CommitteeSeedPinningLib.sol";
import {
    IBootstrapReader,
    IOmniCoreStakingReader,
    IOmniRegistrationReader
} from "./RandomCommitteeVerifier.sol";

/* solhint-disable max-line-length */
/* solhint-disable gas-strict-inequalities */
// gas-strict-inequalities: `<=` semantics required for the sorted-unique
// signer dedup check (`signer <= last`) — strict `<` would change
// behavior. Same justification as `CommitteeAttestor.sol` and the
// verbatim-reused v1 `RandomCommitteeVerifier.sol`.

/**
 * @title RandomCommitteeVerifierV2
 * @author OmniBazaar Development Team
 * @notice Grinding-resistant successor to `RandomCommitteeVerifier`. Same
 *         trust model, dependency contracts and proof shape, plus mandatory
 *         commit-block pinning — closes `COMMITTEE-GRINDING`
 *         (TODO.md; memory `security_committee_grinding_gap_2026-07-04`).
 *
 * @dev NOT deployed. This is a complete, independently-testable, swap-in
 *      replacement for `RandomCommitteeVerifier` activated via
 *      `OmniAttestationGateway.setCommitteeVerifier(IBridgeVerifier)`
 *      (audit fix I-01, 2026-08-04 — a prior draft of this NatSpec named
 *      the wrong cutover function, `OmniRegistration.setAttestationVerifier`,
 *      which does not exist; confirmed against
 *      `OmniAttestationGateway.sol` source). Cutover preconditions,
 *      verified against that contract's actual code:
 *        1. This verifier's `verifierVersion()` string
 *           ("random-committee-ecdsa-v3-pinned") MUST first be approved via
 *           `OmniAttestationGateway.setApprovedVerifierVersion(version, true)`
 *           (audit M-1 whitelist) — `setCommitteeVerifier` reverts
 *           `VerifierVersionNotApproved` otherwise.
 *        2. `eligibleSnapshotLength() >= committeeSize()` MUST hold at
 *           cutover time (H-4 brick-prevention) — `setCommitteeVerifier`
 *           reverts `EligiblePoolTooSmall` otherwise. Call
 *           {refreshEligibleSet} first if needed.
 *        3. Every digest a consumer will {verify} MUST have been pinned
 *           via {requestCommitteeSeed} first — this verifier has no
 *           unpinned fallback path. Swapping this verifier in without
 *           updating the off-chain attestation coordinator to call
 *           {requestCommitteeSeed} before collecting signatures breaks
 *           every subsequent attestation (`verify()` returns `(false, [])`
 *           unconditionally for a never-pinned digest).
 *      No changes to `RandomCommitteeVerifier.sol` itself, no changes to
 *      `OmniRegistration`. Deploying + swapping + a follow-up `/audit`
 *      pass are deliberately left for a dedicated follow-up session — see
 *      the CSW in the originating report.
 *
 *      ## What's identical to v1
 *      Eligibility model, snapshot refresh, multi-blockhash seed
 *      (`h1 = blockhash(commitBlock)`, `h2 = blockhash(commitBlock - 1)`,
 *      audit H-3), commit-block digest binding (audit H-06), sorted-unique
 *      signature recovery, per-signer live-eligibility recheck (audit H-1),
 *      `verifyVeto`. Reuses v1's dependency-reader interfaces verbatim
 *      (`IBootstrapReader` / `IOmniCoreStakingReader` /
 *      `IOmniRegistrationReader`) so both verifiers read the exact same
 *      ABI shape off `Bootstrap` / `OmniCore` / `OmniRegistration`.
 *
 *      ## What's new: mandatory commit-block pinning
 *      v1 lets the prover supply ANY `commitBlock` from the last ~256
 *      mined blocks. Because `committeeFor(messageHash, commitBlock)` is a
 *      public view, a colluding minority of the eligible pool can
 *      enumerate all ~256 already-known candidates, pick whichever one
 *      seats >= `quorumM` of themselves, and sign that specific
 *      `commitBlock` on demand — grinding the outcome. Digest-binding
 *      (H-06) does not stop this: it only prevents an outside party from
 *      REPLAYING an honest signature under a different `commitBlock`; the
 *      colluders hold their own keys and can sign whichever `commitBlock`
 *      they choose. See `CommitteeSeedPinningLib` for the full writeup.
 *
 *      This verifier closes it by requiring every `commitBlock` to be
 *      pinned via {requestCommitteeSeed} BEFORE its own hash exists:
 *      `pinnedBlock = block.number + delay` at pin time, so nobody —
 *      including the pinner — can predict which committee it will yield.
 *      `verify()` rejects any proof whose `commitBlock` does not exactly
 *      match the digest's live pin. Unlike v1's `legacySignaturesAccepted`
 *      migration toggle, pinning is unconditional here — this is a new
 *      contract with no live traffic to preserve compatibility with.
 *
 *      ## 2026-08-04 re-audit remediation status
 *      A follow-up audit (`RandomCommitteeVerifierV2-audit-2026-08-04.md`)
 *      found that pinning the seed alone was not sufficient — the
 *      eligible *pool* being sampled was still read live at
 *      verify-time. Fixed here (M-01): `requestCommitteeSeed` now also
 *      freezes a content hash of the eligible pool, and both {verify}
 *      and {committeeFor} require a freshly computed hash of the live
 *      pool to still match — see `_pinnedPoolHash`. This also resolves
 *      M-04 (recursive Sybil-bootstrapping), which the audit confirmed
 *      depends entirely on M-01's gap. Also fixed (M-05): the signed
 *      digest in {verify} now binds `address(this)`/`block.chainid`.
 *
 *      Same-day adversarial re-audit (`decision_contract_deploy_requires_audit_cycle_2026-08-04`
 *      standing audit-cycle rule) caught a regression in the FIRST M-01
 *      implementation: binding pins to `eligibleSnapshotBlock` (a block
 *      number that {refreshEligibleSet} bumps unconditionally on EVERY
 *      call, even a no-op one) let any address — no stake, no
 *      eligibility, no pool-size precondition — grief any in-flight pin
 *      for free. Revised same-day to content-hash binding (see
 *      `_pinnedPoolHash`), which closes the identical grinding gap
 *      without that regression: a no-op refresh no longer invalidates
 *      outstanding pins, only a refresh that actually changes pool
 *      membership does.
 *
 *      Two related findings are DEFERRED, not fixed in this contract,
 *      both confirmed inert at today's 5-validator launch configuration
 *      (`poolSize == committeeSize`) and gated on the same "pool exceeds
 *      committee size" precondition as M-01/M-04 — must be resolved
 *      before permissionless validator entry (invariant #7), tracked in
 *      `TODO.md`:
 *        - M-02 (unlimited free re-pin-until-favorable after the
 *          256-block abandonment window): the audit's own recommendation
 *          is "additionally consider an escalating cost/cooldown or a
 *          slashable bond" — a new economic mechanism, not yet designed
 *          anywhere in this codebase, and explicitly not required before
 *          deploying at the current configuration.
 *        - M-03 (pin-key nonce/deadline shopping): the real fix is
 *          upstream, in whatever builds `messageHash` before calling
 *          {requestCommitteeSeed} (e.g. `OmniRegistrationDigestLib`'s
 *          typehashed structs) — deriving a semantic pin key that
 *          excludes attacker-controlled `nonce`/`deadline` fields. Out
 *          of this contract's/this redeploy's scope: it touches a
 *          separate, already-live contract with its own blast radius
 *          and audit unit.
 *
 *      ## Governance / Pioneer Phase
 *      `owner_` at construction MUST be the deployer EOA directly per the
 *      Pioneer-Phase deployer-direct-admin rule (CLAUDE.md) — NOT
 *      `OmniTimelockController`. v1's NatSpec says "Owner is intended to be
 *      OmniTimelockController"; that is a pre-existing gap against the
 *      Pioneer-Phase rule, not a pattern to repeat here. The owner slot
 *      stays a swappable address so a deliberate, founder-authorized
 *      post-Pioneer migration can later transfer it to
 *      `OmniTimelockController` + `OmniGovernance` — same as every other
 *      contract's admin authority.
 */
contract RandomCommitteeVerifierV2 is IBridgeVerifier, Ownable2Step {
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
    uint256 public constant MIN_KYC_TIER_FLOOR = 3;

    /// @notice Maximum addresses we'll iterate from Bootstrap when refreshing
    ///         the eligible-set snapshot. Bounds the gas cost of a refresh.
    uint256 public constant MAX_REFRESH_BATCH = 256;

    /// @notice Blocks of lead time {requestCommitteeSeed} pins ahead of the
    ///         current block. See `CommitteeSeedPinningLib.MIN_PIN_DELAY`.
    uint256 public constant COMMIT_SEED_PIN_DELAY = 2;

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
    ///         (>= ceil(2N/3) supermajority).
    uint256 public quorumM;

    /// @notice Minimum KYC tier required to be eligible.
    uint256 public minKycTier;

    /// @notice Minimum stake (in wei, 1e18 = 1 XOM) required to be eligible.
    uint256 public minStake;

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
    //                       COMMIT-BLOCK PIN STORE (grinding resistance)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Per-messageHash pinned future commitBlocks. See
    ///         `CommitteeSeedPinningLib`.
    CommitteeSeedPinningLib.PinStore private _pinStore;

    /// @notice Content hash of `_eligibleSnapshot` recorded at pin time
    ///         for each digest (audit fix M-01, 2026-08-04; revised
    ///         same-day after adversarial re-audit finding NEW-1 — see
    ///         below). {verify} and {committeeFor} require a freshly
    ///         computed hash of the CURRENT `_eligibleSnapshot` to still
    ///         equal this value — pinning the seed alone is not enough,
    ///         since the eligible pool composition is separately mutable
    ///         via the permissionless {refreshEligibleSet}. A colluding
    ///         minority could otherwise: pin a digest, preview the
    ///         resulting committee via {committeeFor}, and — if
    ///         unfavorable — toggle their own eligibility and call
    ///         {refreshEligibleSet} to reshuffle the pool, then re-check
    ///         the SAME pinned seed against the new pool composition.
    ///         Binding the pin to a content hash of the pool active at
    ///         pin time means any {refreshEligibleSet} call that
    ///         actually CHANGES pool membership after pinning invalidates
    ///         the pin outright (forcing a re-pin against the new pool)
    ///         rather than letting the pinned seed be re-evaluated
    ///         against a post-hoc-reshuffled pool.
    ///
    ///         First implementation (2026-08-04, same day) bound this to
    ///         `eligibleSnapshotBlock` (a block-number counter that
    ///         {refreshEligibleSet} bumps unconditionally on EVERY call,
    ///         even a no-op one producing an identical set) instead of a
    ///         content hash. That let any address — no stake, no
    ///         eligibility, no precondition on pool size — grief any
    ///         in-flight pin for free by calling {refreshEligibleSet}
    ///         after observing a `CommitteeSeedPinned` event, with no
    ///         requirement that the pool actually changed. Content-hash
    ///         binding closes the identical grinding gap (a genuine
    ///         reshuffle still changes the hash and still invalidates
    ///         the pin) without that regression: a no-op refresh leaves
    ///         the hash — and therefore the pin — unchanged.
    ///
    ///         `_eligibleSnapshot` is maintained sorted ascending (see
    ///         {refreshEligibleSet}), so `keccak256(abi.encodePacked(...))`
    ///         over it is a canonical, order-independent-in-effect content
    ///         hash of the set. Gas cost scales with pool size (bounded
    ///         by {MAX_REFRESH_BATCH}); acceptable given the alternative
    ///         is an unconditional DoS.
    mapping(bytes32 messageHash => bytes32 poolHash)
        private _pinnedPoolHash;

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

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialise the verifier with its dependency contracts and
     *         initial governance parameters.
     * @param owner_ Initial owner. Pioneer Phase: MUST be the deployer EOA
     *        directly — never a timelock/intermediary contract.
     * @param bootstrap_ Bootstrap contract address.
     * @param omniCore_ OmniCore (staking-info reader) address.
     * @param omniRegistration_ OmniRegistration address.
     * @param initialCommitteeSize Initial N (e.g. 5).
     * @param initialQuorumM Initial M (e.g. 4). Must be >= ceil(2N/3).
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
     *         MUST be the owner.
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

    // ════════════════════════════════════════════════════════════════════════
    //                       ELIGIBLE-SET SNAPSHOT MANAGEMENT
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Refresh the eligible-pool snapshot from current on-chain state.
     * @dev Permissionless. Identical logic to v1 — see
     *      `RandomCommitteeVerifier.refreshEligibleSet` for full rationale.
     */
    function refreshEligibleSet() external {
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
        address[] memory toSort = new address[](filteredCount);
        for (uint256 i = 0; i < filteredCount; ) {
            toSort[i] = filtered[i];
            unchecked {
                ++i;
            }
        }
        _insertionSortMemory(toSort);

        uint256 oldLen = _eligibleSnapshot.length;
        for (uint256 i = 0; i < oldLen; ) {
            _isInSnapshot[_eligibleSnapshot[i]] = false;
            unchecked {
                ++i;
            }
        }
        delete _eligibleSnapshot;

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

    /// @dev In-memory insertion sort. N <= 256 in practice.
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
     */
    function eligibleSnapshotLength() external view returns (uint256) {
        return _eligibleSnapshot.length;
    }

    // ════════════════════════════════════════════════════════════════════════
    //                  COMMIT-BLOCK PINNING (grinding resistance)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pin the future block whose hash will seed committee selection
     *         for `messageHash`. MUST be called (and mined) before the
     *         resulting proof is submitted to {verify} — every proof's
     *         `commitBlock` is checked against this pin; there is no
     *         unpinned path in this verifier. Permissionless.
     * @param messageHash The digest a future committee proof will cover.
     * @return pinnedBlock The block number whose hash will seed selection.
     */
    function requestCommitteeSeed(bytes32 messageHash)
        external
        returns (uint256 pinnedBlock)
    {
        pinnedBlock = CommitteeSeedPinningLib.pin(
            _pinStore,
            messageHash,
            COMMIT_SEED_PIN_DELAY
        );
        // Audit fix M-01, 2026-08-04 (content-hash revision): freeze
        // the eligible-pool content this pin will be evaluated against.
        // See `_pinnedPoolHash` for the full rationale.
        _pinnedPoolHash[messageHash] = _eligiblePoolHash();
    }

    /**
     * @notice Compute a canonical content hash of the current eligible
     *         pool
     * @dev Used to detect whether the eligible pool's actual membership
     *      has changed between pin time and verify time (audit fix
     *      M-01, 2026-08-04). `_eligibleSnapshot` is maintained sorted
     *      ascending by {refreshEligibleSet}, so this hash is a
     *      canonical representation of set membership, not affected by
     *      insertion order.
     * @return Content hash of the live eligible set.
     */
    function _eligiblePoolHash() private view returns (bytes32) {
        return keccak256(abi.encodePacked(_eligibleSnapshot));
    }

    /**
     * @notice Read the pinned commitBlock for `messageHash`, if any.
     * @param messageHash The digest to look up.
     * @return pinnedBlock The pinned block number (0 if never pinned).
     * @return isPinned True if a pin has been recorded.
     */
    function pinnedCommitBlock(bytes32 messageHash)
        external
        view
        returns (uint256 pinnedBlock, bool isPinned)
    {
        return CommitteeSeedPinningLib.get(_pinStore, messageHash);
    }

    /**
     * @notice Predict the committee for a given (messageHash, commitBlock).
     * @dev Off-chain coordinators call this AFTER the pinned block mines to
     *      know which validators to ask for signatures. Multi-blockhash
     *      seed (audit H-3): pairing two consecutive blocks means a single
     *      proposer cannot bias selection alone.
     * @param messageHash Same messageHash that will be passed to {verify}.
     * @param commitBlock The commit-block field that will be packed at the
     *        head of the proof. Callers should pass the value returned by
     *        {requestCommitteeSeed} / {pinnedCommitBlock}.
     * @return committee The sorted committee addresses (length == committeeSize),
     *         OR empty array if commitBlock is stale / out of range.
     */
    function committeeFor(bytes32 messageHash, uint256 commitBlock)
        external
        view
        returns (address[] memory committee)
    {
        bytes32 seed = _deriveSeed(messageHash, commitBlock);
        if (seed == bytes32(0)) return new address[](0);
        // Audit fix M-01, 2026-08-04: if this digest was pinned and the
        // eligible pool's actual membership has since changed, the
        // preview must honestly reflect that {verify} will reject it
        // too — otherwise an off-chain coordinator could be shown a
        // stale preview that no longer matches what verification will
        // actually accept.
        (, bool isPinned) = CommitteeSeedPinningLib.get(_pinStore, messageHash);
        if (isPinned && _pinnedPoolHash[messageHash] != _eligiblePoolHash()) {
            return new address[](0);
        }
        return _selectCommittee(seed, committeeSize);
    }

    /**
     * @dev Derive the committee-selection seed from two consecutive
     *      blockhashes + the message hash. Identical to v1 — see
     *      `RandomCommitteeVerifier._deriveSeed`.
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
        return "random-committee-ecdsa-v3-pinned";
    }

    /// @inheritdoc IBridgeVerifier
    function quorumThreshold() external view override returns (uint256) {
        return quorumM;
    }

    /// @inheritdoc IBridgeVerifier
    function isValidator(address account) external view override returns (bool) {
        if (account == address(0)) return false;
        return _isInSnapshot[account];
    }

    /* solhint-disable code-complexity */
    // code-complexity: each branch below is a distinct, necessary
    // proof-validation step (length, quorum bounds, pin match, pool
    // generation, seed derivation, committee derivation) — collapsing
    // any of them would weaken the security property it enforces.
    /**
     * @inheritdoc IBridgeVerifier
     * @dev Proof format:
     *        proof = commitBlock(32 bytes) || sig0(65) || sig1(65) || ...
     *
     *      - `commitBlock` MUST equal the live pin recorded via
     *        {requestCommitteeSeed} for `messageHash` (grinding
     *        resistance — see `CommitteeSeedPinningLib`). Unpinned or
     *        mismatched `commitBlock` values are rejected unconditionally;
     *        there is no legacy/unpinned fallback in this verifier.
     *      - `commitBlock` MUST also resolve to a non-zero blockhash (i.e.
     *        within the last 256 blocks) at verification time.
     *      - Number of signatures MUST be in [quorumM, committeeSize].
     *      - Signers MUST appear sorted ascending (dedup check).
     *      - The eligible pool's content hash at pin-time MUST still
     *        match the live pool's content hash (audit fix M-01,
     *        2026-08-04, content-hash revision) — see `_pinnedPoolHash`.
     *      - Each signer MUST be in the committee derived from
     *        keccak256(blockhash(commitBlock), blockhash(commitBlock-1), messageHash).
     *      - Signatures MUST be over
     *        keccak256(abi.encode(address(this), block.chainid, messageHash,
     *        commitBlock)) (audit fix M-05, 2026-08-04, extending audit
     *        H-06's original commitBlock binding with instance/chain
     *        binding) — binding each signature to the one
     *        committee-selection block its signer committed to, this
     *        specific verifier instance, and this chain.
     */
    function verify(bytes32 messageHash, bytes calldata proof)
        external
        view
        override
        returns (bool valid, address[] memory attesters)
    {
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

        // Grinding resistance: commitBlock MUST be the live pin for this
        // exact messageHash — no unpinned path.
        if (!CommitteeSeedPinningLib.matchesPin(_pinStore, messageHash, commitBlock)) {
            return (false, new address[](0));
        }

        // Audit fix M-01, 2026-08-04 (content-hash revision): the
        // eligible pool's actual membership at pin-time MUST still
        // match the live pool. Only a `refreshEligibleSet()` call that
        // genuinely changes membership invalidates the pin — a no-op
        // refresh does not, closing the griefing regression the first
        // (block-number-bound) implementation had. See
        // `_pinnedPoolHash`.
        if (_pinnedPoolHash[messageHash] != _eligiblePoolHash()) {
            return (false, new address[](0));
        }

        bytes32 seed = _deriveSeed(messageHash, commitBlock);
        if (seed == bytes32(0)) {
            return (false, new address[](0));
        }

        address[] memory committee = _selectCommittee(seed, n);
        if (committee.length == 0) {
            return (false, new address[](0));
        }

        // Audit fix M-05, 2026-08-04: bind the signed digest to this
        // contract instance and chain, closing a cross-instance/
        // cross-chain replay gap for any future `IBridgeVerifier`
        // consumer that signs this raw hash without its own outer
        // EIP-712 domain separator (the current, live
        // `OmniRegistration` consumer is unaffected either way — its
        // own `DOMAIN_SEPARATOR` already binds chainId/verifyingContract
        // before this hash is ever reached).
        bytes32 boundHash = keccak256(
            abi.encode(address(this), block.chainid, messageHash, commitBlock)
        );
        return _recoverCommitteeSignatures(boundHash, committee, proof, sigCount);
    }
    /* solhint-enable code-complexity */

    /**
     * @notice Recover and validate every committee signature in `proof`
     *         against one signed digest. Identical to v1 — see
     *         `RandomCommitteeVerifier._recoverCommitteeSignatures`.
     * @param signedHash The raw digest the committee signed — wrapped in
     *        the EIP-191 envelope here.
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
            // Audit H-1: live eligibility check.
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
     *      Identical to v1 — does not involve committee selection so no
     *      pinning requirement applies.
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
     * @dev Validate (N, M, minKycTier) parameters. Identical to v1.
     */
    function _validateParameters(
        uint256 n,
        uint256 m,
        uint256 minTier
    ) private pure {
        if (n < MIN_COMMITTEE_SIZE || n > MAX_COMMITTEE_SIZE) {
            revert CommitteeSizeOutOfRange(n);
        }
        if (m * 3 < n * 2) revert QuorumBelowSupermajority(m, n);
        if (m > n) revert QuorumExceedsCommittee(m, n);
        if (minTier < MIN_KYC_TIER_FLOOR) revert MinKycTierBelowFloor(minTier);
    }

    /**
     * @dev Live eligibility check against the three dependency contracts.
     *      Identical to v1.
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
     *      using `seed` as the RNG source. Identical to v1.
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
        address[] memory pool = new address[](poolSize);
        for (uint256 i = 0; i < poolSize; ) {
            pool[i] = _eligibleSnapshot[i];
            unchecked {
                ++i;
            }
        }
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
        address[] memory committee = new address[](n);
        for (uint256 i = 0; i < n; ) {
            committee[i] = pool[i];
            unchecked {
                ++i;
            }
        }
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
     * @dev Binary search for `addr` in the sorted `committee`. Identical
     *      to v1.
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
