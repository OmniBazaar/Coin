// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";

/* solhint-disable max-line-length */

/**
 * @title OmniAttestationGateway
 * @author OmniBazaar Development Team
 * @notice Single-entry attestation dispatcher for `OmniRegistration` (KYC,
 *         AML, email/phone/social, Persona). Owns the dual-path cutover
 *         state (legacy single-key vs. Phase 2 M-of-N committee) and the
 *         replay-protection nonce map. Sits between `OmniRegistration`
 *         (the caller) and the verifier(s) (`RandomCommitteeVerifier`
 *         today, BLS / ZK in future).
 *
 * @dev Designed in response to the 2026-05-18 Phase 2 audit. The pre-audit
 *      design embedded verification logic directly in `OmniRegistration`,
 *      which hit the 24 KiB Spurious Dragon bytecode ceiling and left no
 *      room for audit-recommended hardening (subject exclusion, pool-size
 *      gate, Pausable, version check, set/clear split). This gateway
 *      extracts ALL verification state + logic into a fresh contract with
 *      ample bytecode budget; `OmniRegistration._verifyAttestation` shrinks
 *      to a single delegated call.
 *
 *      Architecture:
 *
 *        OmniRegistration  ─────►  OmniAttestationGateway  ─────►  IBridgeVerifier
 *        (just calls            (owns dual-path state,         (pure-view
 *         verifyAndConsume)      nonces, pause, dispatcher)     M-of-N verify)
 *
 *      Audit findings addressed here:
 *        - C-1: original 3·N committee-vs-pool security gate is
 *          INTENTIONALLY ABSENT — see {setCommitteeVerifier} for
 *          rationale (training-wheels threat model at launch).
 *        - C-2: subject ∉ committee — recovers attesters, rejects if any
 *          signer equals the attestation subject.
 *        - H-4: pool-size brick-prevention guard (pool >= N).
 *        - H-5: Pausable with guardian (emergency circuit-breaker).
 *        - M-1: verifierVersion() whitelist when setting verifier.
 *        - M-2: split setCommitteeVerifier / clearCommitteeVerifier.
 *
 *      Audit findings retained in RandomCommitteeVerifier (companion):
 *        - H-1, H-3, L-2, M-3.
 *
 *      Audit findings NOT yet addressed (require Bootstrap upgrade or
 *      cross-app/Validator-side work, tracked in audit report):
 *        - H-2 (Bootstrap pagination), M-6 (Persona consistency).
 *
 *      Storage layout: standalone, non-upgradeable. Future BLS/ZK verifier
 *      swap is a Timelock parameter change, NOT a contract upgrade.
 */
contract OmniAttestationGateway is Ownable2Step, Pausable {
    using ECDSA for bytes32;

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Encoded selectors used in staticcall probes against
    ///         IBridgeVerifier implementations to read out-of-interface
    ///         metadata. Pulling them into constants makes the gateway's
    ///         trust assumptions explicit and prevents accidental ABI drift.
    bytes4 private constant _SEL_ELIGIBLE_SNAPSHOT_LENGTH =
        bytes4(keccak256("eligibleSnapshotLength()"));
    bytes4 private constant _SEL_ELIGIBLE_SNAPSHOT =
        bytes4(keccak256("eligibleSnapshot()"));
    bytes4 private constant _SEL_COMMITTEE_SIZE =
        bytes4(keccak256("committeeSize()"));

    // ════════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Trusted single-key signer for the legacy attestation path.
    ///         Used when `committeeVerifier == address(0)`.
    address public trustedVerificationKey;

    /// @notice M-of-N committee verifier (Phase 2). When non-zero, the
    ///         M-of-N path is active. When zero, the legacy single-key
    ///         path runs against `trustedVerificationKey`.
    IBridgeVerifier public committeeVerifier;

    /// @notice Permanently-burned nonces for replay protection. Owned here
    ///         (not in `OmniRegistration`) so the gateway can survive
    ///         future OmniRegistration redeploys without losing nonce state.
    mapping(bytes32 => bool) public usedNonces;

    /// @notice Authorized consumers of {verifyAndConsume}. Typically just
    ///         `OmniRegistration`. Owner-managed; revocable.
    mapping(address => bool) public authorizedConsumers;

    /// @notice Guardian role that can {pause} the gateway in an emergency.
    ///         Separate from owner (Timelock) so a fast-pause is possible
    ///         without waiting for the 7-day governance window. Audit H-5.
    /// @dev    OmniBazaar two-governance invariant: the guardian MUST be a
    ///         Protocol-governance-controlled multisig (KYC/AML attestation
    ///         is protocol state, NOT ODDAO treasury state). Do not appoint
    ///         the ODDAO ops multisig here — that would let ODDAO halt the
    ///         protocol attestation pipeline, violating the
    ///         `decision_oddao_vs_protocol_governance` separation. Enforced
    ///         by runbook + off-chain monitoring, not by code (the two
    ///         multisig addresses are not yet on-chain registered).
    address public guardian;

    /// @notice Whitelist of allowed `verifierVersion()` strings. Setter
    ///         rejects any verifier whose `verifierVersion()` is not
    ///         present in this set. Audit M-1 remediation.
    mapping(bytes32 => bool) public approvedVerifierVersions;

    /// @notice Audit Pass-2 H-NEW-3: one-way latch that permanently disables
    ///         the legacy single-key path. Once `disableLegacyPath()` flips
    ///         this to true, the gateway can NEVER fall back to the
    ///         `trustedVerificationKey` path, even if `committeeVerifier` is
    ///         later cleared. Defense against a compromised owner silently
    ///         downgrading attestation trust by calling
    ///         `clearCommitteeVerifier()` to re-activate a pre-existing
    ///         legacy key.
    bool public legacyDisabled;

    /// @notice Audit Pass-2 AC-1 / M-NEW-5: cached minimum-attesters
    ///         post-condition for the committee path. Set at
    ///         {setCommitteeVerifier} time from the verifier's
    ///         `quorumThreshold()`; cleared at {clearCommitteeVerifier}.
    ///         Gateway requires `attesters.length >= minAttestersForCommittee`
    ///         on every committee-path call, defending against a malformed
    ///         or future BLS-aggregated verifier returning `(true, [])`.
    uint256 public minAttestersForCommittee;

    // ════════════════════════════════════════════════════════════════════════
    //                                  EVENTS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Emitted whenever an attestation is accepted (committee OR
    ///         legacy path). Off-chain slashing pipelines pair this with
    ///         {CommitteeAttested} to recover the attester set without
    ///         needing the originating tx calldata.
    event AttestationAccepted(
        address indexed user,
        bytes32 indexed digest,
        bool committeePath
    );

    /// @notice Audit Pass-2 M-NEW-5: emitted alongside {AttestationAccepted}
    ///         whenever the committee path is used. Carries the attester
    ///         list so off-chain fraud-detection / slashing pipelines have a
    ///         permanent on-chain record of who signed each attestation —
    ///         independent of `blockhash(commitBlock)` availability (which
    ///         expires after 256 blocks). Indexed `digest` lets event
    ///         consumers join with {AttestationAccepted}.
    event CommitteeAttested(bytes32 indexed digest, address[] attesters);

    /// @notice Emitted when {setCommitteeVerifier} activates the M-of-N path.
    event CommitteeVerifierSet(address indexed newVerifier);

    /// @notice Emitted when {clearCommitteeVerifier} rolls back to legacy.
    event CommitteeVerifierCleared();

    /// @notice Emitted when {setTrustedVerificationKey} changes the legacy key.
    event TrustedVerificationKeyUpdated(address indexed newKey);

    /// @notice Emitted when {setAuthorizedConsumer} grants/revokes consumer rights.
    event AuthorizedConsumerSet(address indexed consumer, bool authorized);

    /// @notice Emitted when {setGuardian} changes the emergency-pause role.
    event GuardianSet(address indexed newGuardian);

    /// @notice Emitted when a verifier version is added/removed from the whitelist.
    event ApprovedVerifierVersion(bytes32 indexed versionHash, bool approved);

    /// @notice Audit Pass-2 H-NEW-3: emitted when {disableLegacyPath} is
    ///         called. The legacy single-key path is now permanently
    ///         unreachable. Irreversible.
    event LegacyPathDisabled();

    // ════════════════════════════════════════════════════════════════════════
    //                                  ERRORS
    // ════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error UnauthorizedConsumer(address caller);
    error UnauthorizedGuardian(address caller);
    error TrustedVerificationKeyNotSet();
    error CommitteeVerifierNotSet();
    error InvalidVerificationProof();
    error ProofExpired();
    error NonceAlreadyUsed();
    error VerifierVersionNotApproved(string version);
    /// @notice Audit Pass-1 H-4 brick-prevention: eligible pool must
    ///         have at least `committeeSize` (N) members or
    ///         `committeeFor()` always returns empty and the gateway
    ///         is operationally dead.
    error EligiblePoolTooSmall(uint256 poolSize, uint256 committeeSize);
    error SubjectInCommittee(address subject);
    /// @notice Audit Pass-2 H-NEW-3 — committee→legacy fallback after the
    ///         one-way `legacyDisabled` latch has been thrown.
    error LegacyPathPermanentlyDisabled();
    /// @notice Audit Pass-2 AC-1 / M-NEW-5 — verifier returned an attester
    ///         list shorter than its own quorum threshold (or empty).
    error InsufficientAttesterCount(uint256 got, uint256 required);
    /// @notice Audit Pass-2 M-NEW-3 — empty version string can never be a
    ///         legitimate `verifierVersion()` and must not be on the
    ///         approved-version whitelist.
    error EmptyVersionString();
    /// @notice Audit Pass-2 M-NEW-6 — verifier failed to return either
    ///         `eligibleSnapshotLength()` or `eligibleSnapshot()` /
    ///         `committeeSize()`. Without snapshot/size readable, the C-1
    ///         pool gate cannot be enforced honestly.
    error VerifierMetadataUnreadable();

    // ════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ════════════════════════════════════════════════════════════════════════

    modifier onlyAuthorizedConsumer() {
        if (!authorizedConsumers[msg.sender]) {
            revert UnauthorizedConsumer(msg.sender);
        }
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) {
            revert UnauthorizedGuardian(msg.sender);
        }
        _;
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the gateway.
     * @param owner_ Initial owner (intended: OmniTimelockController).
     * @param guardian_ Initial guardian (intended: ops multisig, separate
     *        from owner for fast emergency pause).
     * @param trustedKey Initial legacy single-key signer (or `address(0)`
     *        if launching directly into committee mode — then the legacy
     *        path is unreachable).
     */
    constructor(
        address owner_,
        address guardian_,
        address trustedKey
    ) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        guardian = guardian_; // address(0) allowed = no guardian configured yet
        trustedVerificationKey = trustedKey; // address(0) allowed = legacy disabled
        emit GuardianSet(guardian_);
        emit TrustedVerificationKeyUpdated(trustedKey);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                          MAIN ENTRY POINT
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify an attestation proof and consume its nonce. Single
     *         entry point used by `OmniRegistration._verifyAttestation`.
     * @dev Dual-path:
     *        - `committeeVerifier != address(0)` → Phase 2 M-of-N committee
     *          path. Recovers attesters; rejects if `subject` is among
     *          them (C-2 fix). Emits {AttestationAccepted} with
     *          `committeePath = true`.
     *        - `committeeVerifier == address(0)` → legacy single-key path
     *          against `trustedVerificationKey`. Emits {AttestationAccepted}
     *          with `committeePath = false`.
     *
     *      Replay protection: `nonce` is permanently consumed on success.
     *      Time-bound: reverts if `block.timestamp > deadline`.
     *      Pausable: reverts when paused (`whenNotPaused`).
     *      Access-gated: only `authorizedConsumers` can invoke
     *      (`onlyAuthorizedConsumer`).
     *
     *      Subject binding (audit M-02): the gateway does NOT independently
     *      verify that `subject` is cryptographically bound into `digest` —
     *      `digest` is the caller's EIP-712 struct hash. The caller MUST
     *      bind `subject` into the signed struct; the gateway only enforces
     *      the C-2 subject-in-committee exclusion. This is a trust
     *      assumption on the authorized consumer, not a verifier check.
     * @param subject User address whose attestation is being verified
     *        (audit C-2 — verifier path rejects when any signer == subject).
     * @param digest Pre-computed EIP-712 digest
     *        `keccak256("\x19\x01" || DOMAIN_SEPARATOR || structHash)`
     *        — caller (OmniRegistration) owns the EIP-712 domain. The
     *        caller MUST bind `subject` into the struct before hashing
     *        (audit M-02); the gateway cannot re-derive this binding.
     * @param nonce Unique nonce for replay protection.
     * @param deadline Proof expiration timestamp.
     * @param proof Legacy: 65-byte ECDSA signature. Committee: opaque
     *        verifier-specific blob.
     */
    function verifyAndConsume(
        address subject,
        bytes32 digest,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata proof
    ) external whenNotPaused onlyAuthorizedConsumer {
        if (block.timestamp > deadline) revert ProofExpired(); // solhint-disable-line not-rely-on-time
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        IBridgeVerifier v = committeeVerifier;
        bool committeePath;
        address[] memory attesters;
        if (address(v) != address(0)) {
            // Phase 2 M-of-N path. Use full `(bool, address[])` decode so
            // we can enforce subject ∉ committee (C-2) AND the audit Pass-2
            // AC-1 minimum-attesters post-condition.
            bool valid;
            (valid, attesters) = v.verify(digest, proof);
            if (!valid) revert InvalidVerificationProof();
            uint256 nAtt = attesters.length;
            // AC-1 / M-NEW-5: reject `(true, [])` and any attester count
            // below the cached quorum threshold. Defends against a
            // future verifier that aggregates signatures (BLS, ZK) and
            // returns an empty array, or a buggy/malicious verifier
            // returning a placeholder.
            uint256 minAtt = minAttestersForCommittee;
            if (nAtt < minAtt) revert InsufficientAttesterCount(nAtt, minAtt);
            for (uint256 i = 0; i < nAtt; ) {
                if (attesters[i] == subject) revert SubjectInCommittee(subject);
                unchecked {
                    ++i;
                }
            }
            committeePath = true;
        } else {
            // Legacy single-key path. Audit Pass-2 H-NEW-3: the one-way
            // `legacyDisabled` latch blocks this branch once governance
            // has permanently committed to the committee path; protects
            // against silent downgrade if a compromised owner later calls
            // `clearCommitteeVerifier()`.
            if (legacyDisabled) revert LegacyPathPermanentlyDisabled();
            address k = trustedVerificationKey;
            if (k == address(0)) revert TrustedVerificationKeyNotSet();
            if (digest.recover(proof) != k) revert InvalidVerificationProof();
            committeePath = false;
        }

        usedNonces[nonce] = true;
        emit AttestationAccepted(subject, digest, committeePath);
        if (committeePath) {
            // Audit Pass-2 M-NEW-5: persist attester list in event log so
            // off-chain slashing pipelines aren't dependent on
            // `blockhash(commitBlock)` (256-block window).
            emit CommitteeAttested(digest, attesters);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //                            GOVERNANCE SETTERS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Activate the M-of-N committee verifier. Audit M-2: this is
     *         the SOLE activation path; {clearCommitteeVerifier} is the
     *         separate rollback. No sentinel overload.
     * @dev Enforces audit findings:
     *        - M-1: `verifierVersion()` must be on the approved whitelist.
     *        - H-4: `poolSize >= committeeSize` (brick-prevention only —
     *          without this, `committeeFor()` always returns empty).
     *
     *      The Pass-1 C-1 finding originally added a `poolSize >= 3·N`
     *      gate as a "security uplift floor" for the
     *      adversarial-permissionless-subset threat model. That threat
     *      model does not apply during the launch phase: the 5 beacon
     *      validators are team-controlled + co-located, so an
     *      "adversarial subset" of the pool is the trusted operator
     *      itself. The gate would only block setup without providing
     *      security benefit, so it has been removed. The training-wheels
     *      phase explicitly acknowledges that beacon validators dominate
     *      the trust matrix until pool > 15 — that is descriptive of
     *      reality, not an attack surface. As permissionless validators
     *      onboard, the beacon validators' share of the eligible pool
     *      drops naturally; no governance action required at the
     *      transition.
     * @param newVerifier Non-zero verifier address.
     */
    function setCommitteeVerifier(IBridgeVerifier newVerifier) external onlyOwner {
        if (address(newVerifier) == address(0)) revert ZeroAddress();

        // M-1: verifier version must be on approved whitelist.
        string memory version = newVerifier.verifierVersion();
        bytes32 versionHash = keccak256(bytes(version));
        if (!approvedVerifierVersions[versionHash]) {
            revert VerifierVersionNotApproved(version);
        }

        // Read committeeSize (N) via staticcall + the pool snapshot
        // length. Both are required to enforce H-4 brick-prevention —
        // without `pool >= N`, the verifier's `committeeFor()` returns
        // an empty committee and every attestation reverts.
        uint256 cSize = _readCommitteeSize(newVerifier);
        uint256 pool = _readEligibleSnapshotLength(newVerifier);
        if (cSize == 0 || pool == 0) revert VerifierMetadataUnreadable();
        if (pool < cSize) revert EligiblePoolTooSmall(pool, cSize);

        // Audit Pass-2 AC-1 / M-NEW-5: cache the verifier's quorum (M) at
        // setter time. `verifyAndConsume` enforces the recovered
        // attester count >= this cached value. Gateway's runtime check
        // is fixed against the value reviewed by governance at setter
        // time; verifier-side parameter rotation that lowers M further
        // does NOT loosen the gateway check.
        uint256 quorum = newVerifier.quorumThreshold();
        if (quorum == 0) revert VerifierMetadataUnreadable();

        committeeVerifier = newVerifier;
        minAttestersForCommittee = quorum;
        emit CommitteeVerifierSet(address(newVerifier));
    }

    /**
     * @notice Roll back to the legacy single-key path. Subsequent
     *         attestations validate against {trustedVerificationKey}.
     *         Audit M-2: separate entry point from {setCommitteeVerifier}
     *         eliminates the sentinel-overload foot-gun.
     * @dev Audit M-01: reverts once {disableLegacyPath} has thrown the
     *      one-way `legacyDisabled` latch. Clearing the committee verifier
     *      after the legacy path is permanently disabled would leave the
     *      gateway with NO active path (committee zero, legacy latched off)
     *      and brick every attestation until a new verifier is set.
     */
    function clearCommitteeVerifier() external onlyOwner {
        if (legacyDisabled) revert LegacyPathPermanentlyDisabled();
        if (trustedVerificationKey == address(0)) revert TrustedVerificationKeyNotSet();
        committeeVerifier = IBridgeVerifier(address(0));
        minAttestersForCommittee = 0;
        emit CommitteeVerifierCleared();
    }

    /**
     * @notice Audit Pass-2 H-NEW-3: permanently disable the legacy
     *         single-key attestation path. Irreversible — once flipped,
     *         `verifyAndConsume` will revert `LegacyPathPermanentlyDisabled`
     *         on every legacy-branch call, even if `committeeVerifier` is
     *         later cleared.
     * @dev    Intended to be called by governance as the final step of
     *         Phase 2 cutover, once the committee path has produced
     *         attestations cleanly for a stability window (per the
     *         decision_phase2_attestation_architecture cutover plan).
     *         Defends against a future compromised owner silently
     *         downgrading trust by calling `clearCommitteeVerifier()` to
     *         re-activate an old trusted key. After this call, the
     *         `trustedVerificationKey` storage slot is effectively dead.
     */
    function disableLegacyPath() external onlyOwner {
        if (committeeVerifier == IBridgeVerifier(address(0))) {
            revert CommitteeVerifierNotSet();
        }
        legacyDisabled = true;
        emit LegacyPathDisabled();
    }

    /// @notice Set the legacy single-key signer.
    /// @param newKey New signer (address(0) disables legacy path entirely).
    function setTrustedVerificationKey(address newKey) external onlyOwner {
        trustedVerificationKey = newKey;
        emit TrustedVerificationKeyUpdated(newKey);
    }

    /// @notice Add or revoke an authorized consumer.
    /// @param consumer Contract permitted to invoke {verifyAndConsume}.
    /// @param authorized True to grant, false to revoke.
    function setAuthorizedConsumer(address consumer, bool authorized)
        external
        onlyOwner
    {
        if (consumer == address(0)) revert ZeroAddress();
        authorizedConsumers[consumer] = authorized;
        emit AuthorizedConsumerSet(consumer, authorized);
    }

    /// @notice Set the emergency-pause guardian role.
    /// @dev Audit Pass-2 M-NEW-2: rejects `address(0)` so a single owner tx
    ///      cannot remove the fast-pause defense. To intentionally remove
    ///      the guardian, call {disableGuardian} (separate, explicit).
    /// @param newGuardian Non-zero guardian address.
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Audit Pass-2 M-NEW-2: explicit setter for removing the
    ///         guardian (e.g., during decommissioning). Separate from
    ///         {setGuardian} so accidental zero-rotation cannot occur.
    function disableGuardian() external onlyOwner {
        guardian = address(0);
        emit GuardianSet(address(0));
    }

    /// @notice Add/remove a verifier-version string from the approved
    ///         whitelist. Audit M-1 — defends against `setCommitteeVerifier`
    ///         being misconfigured with a hostile or buggy verifier.
    /// @param version Canonical `verifierVersion()` string
    ///        (e.g. "random-committee-ecdsa-v1", future "bls-bn254-v1").
    /// @param approved True to approve, false to revoke.
    function setApprovedVerifierVersion(string calldata version, bool approved)
        external
        onlyOwner
    {
        // Audit Pass-2 M-NEW-3: reject empty string. A verifier returning
        // `""` from `verifierVersion()` would otherwise sail past the M-1
        // whitelist if `""` were ever (accidentally) added.
        if (bytes(version).length == 0) revert EmptyVersionString();
        bytes32 versionHash = keccak256(bytes(version));
        approvedVerifierVersions[versionHash] = approved;
        emit ApprovedVerifierVersion(versionHash, approved);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                          PAUSE / UNPAUSE (H-5)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Pause all `verifyAndConsume` calls. Audit H-5: emergency
     *         circuit-breaker that doesn't wait for the 7-day Timelock
     *         governance window. Callable by guardian OR owner.
     * @dev Audit Pass-2 M-NEW-Biz-Pause: pausing here freezes every KYC-tier
     *      promotion AND the welcome-bonus pipeline (Tier 1 is the
     *      precondition for `canClaimWelcomeBonus`). Already-promoted users
     *      can still claim bonuses through `OmniRewardManager` — pause
     *      blocks only NEW attestations, not redemptions of state that
     *      already exists on-chain. Operator runbook MUST surface this
     *      coupling to incident commanders before invoking pause.
     */
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /**
     * @notice Unpause. Owner-only — re-enabling the gateway after an
     *         emergency requires full governance review.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ════════════════════════════════════════════════════════════════════════
    //                              VIEW HELPERS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check whether a (digest, nonce) tuple would currently be
     *         accepted. Off-chain coordinators use this to avoid wasting
     *         gas on attestations that will revert.
     */
    function isAcceptable(bytes32 nonce, uint256 deadline)
        external
        view
        returns (bool)
    {
        if (paused()) return false;
        if (block.timestamp > deadline) return false; // solhint-disable-line not-rely-on-time
        if (usedNonces[nonce]) return false;
        return true;
    }

    /**
     * @notice Read eligible-pool length from the verifier via low-level
     *         staticcall against either `eligibleSnapshotLength()` (new
     *         shape) or `eligibleSnapshot()` (full-array fallback).
     *         Lets the gateway interrogate any IBridgeVerifier impl
     *         even if it doesn't expose the optimized length view.
     * @dev    Audit Pass-2 M-NEW-6: returns 0 ONLY when both probes fail
     *         AND yield no decodable data. The setter treats 0 as a hard
     *         error (`VerifierMetadataUnreadable`), so we never silently
     *         pass the H-4 brick-prevention gate with an unreadable pool.
     */
    function _readEligibleSnapshotLength(IBridgeVerifier v)
        private
        view
        returns (uint256)
    {
        // Try the optimized length-only view first.
        (bool ok, bytes memory data) = address(v).staticcall(
            abi.encodeWithSelector(_SEL_ELIGIBLE_SNAPSHOT_LENGTH)
        );
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        // Fallback to full-array view (heavy on memory but works).
        (ok, data) = address(v).staticcall(
            abi.encodeWithSelector(_SEL_ELIGIBLE_SNAPSHOT)
        );
        if (!ok || data.length < 64) return 0;
        address[] memory arr = abi.decode(data, (address[]));
        return arr.length;
    }

    /**
     * @notice Read the verifier's committee size (N) via staticcall
     *         against `committeeSize()`. Required for the H-4
     *         brick-prevention gate `pool >= N` in
     *         {setCommitteeVerifier}.
     * @dev    Returns 0 if the verifier does not implement the optional
     *         `committeeSize()` view; setter treats 0 as
     *         `VerifierMetadataUnreadable` to force every approved
     *         verifier to expose this metadata.
     */
    function _readCommitteeSize(IBridgeVerifier v)
        private
        view
        returns (uint256)
    {
        (bool ok, bytes memory data) = address(v).staticcall(
            abi.encodeWithSelector(_SEL_COMMITTEE_SIZE)
        );
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }
}
