// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IBridgeVerifier, IOmniAttestationGateway}
    from "./OmniRegistrationInterfaces.sol";

/**
 * @title OmniRegistrationDigestLib
 * @author OmniBazaar Team
 * @notice External library hosting the OMNICORE-DECENT helpers — EIP-712
 *         envelope dispatcher, supersedes-chain enforcer, auto-eligibility
 *         gate, misbehavior-window counter, canonical recorder, and the
 *         permissionless equivocation-attribution function body — extracted
 *         from {OmniRegistration} so the consuming contract fits under the
 *         24576-byte Subnet-EVM deployment limit.
 *
 * @dev    All functions are `external`. Solidity compiles consumer calls
 *         as DELEGATECALL to the library address linked at deploy time;
 *         the library's bytecode lives in its own deployment, not in the
 *         consumer's. Functions that touch consumer storage take
 *         `mapping(...) storage` parameters — the DELEGATECALL means the
 *         storage slots they read/write are the consumer's, not the
 *         library's.
 *
 *         Events declared here are emitted under the consumer's address
 *         (DELEGATECALL semantics). OmniRegistration redeclares the same
 *         events so the ABI exposes them to clients; signatures match by
 *         construction.
 *
 *         IMPORTANT: typehash constants here MUST stay in lock-step with
 *         OmniRegistration. Both are `keccak256(...)` of the same string
 *         literal — divergence would silently break attribution.
 */
library OmniRegistrationDigestLib {
    // ─── Typehash constants (must match OmniRegistration verbatim) ────────

    bytes32 internal constant PHONE_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "PhoneVerification(address user,bytes32 phoneHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant SOCIAL_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "SocialVerification(address user,bytes32 socialHash,string platform,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant EMAIL_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "EmailVerification(address user,bytes32 emailHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant ID_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "IDVerification(address user,bytes32 idHash,string country,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant ADDRESS_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "AddressVerification(address user,bytes32 addressHash,string country,bytes32 documentType,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant SELFIE_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "SelfieVerification(address user,bytes32 selfieHash,uint256 similarity,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant PERSONA_VERIFICATION_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "PersonaVerification(address user,bytes32 verificationHash,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant ACCREDITED_INVESTOR_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "AccreditedInvestorCertification(address user,uint8 criteria,bool certified,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant AML_CLEARANCE_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "AMLClearance(address user,bool cleared,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );
    bytes32 internal constant THIRD_PARTY_KYC_TYPEHASH = keccak256(
        // solhint-disable-next-line max-line-length
        "ThirdPartyKYC(address user,address provider,bytes32 supersedes,uint256 timestamp,bytes32 nonce,uint256 deadline)"
    );

    uint256 internal constant MISBEHAVIOR_EXCLUSION_THRESHOLD = 3;
    uint256 internal constant MISBEHAVIOR_EXCLUSION_WINDOW = 30 days;

    // ─── Events (redeclared on consumer too — same signature, same topic) ──

    event AttestationRaceLost(
        address indexed user,
        bytes32 indexed typehash,
        bytes32 attemptedDigest,
        bytes32 currentCanonicalDigest
    );
    event AttestationEquivocationAttempt(
        address indexed user,
        bytes32 indexed typehash,
        bytes32 attemptedDigest,
        bytes32 attemptedPayloadHash,
        bytes32 currentCanonicalDigest,
        bytes32 currentCanonicalPayloadHash
    );
    event MisbehaviorRecorded(
        address indexed attester,
        address indexed subject,
        bytes32 indexed typehash,
        uint64 timestamp
    );

    // ─── Errors (mirror OmniRegistration's surface) ────────────────────────

    error InvalidSupersedes(bytes32 expected, bytes32 submitted);
    error NotHistoricalCanonical(bytes32 claimedSupersedes);
    error FirstAttestationRaceImmune();
    error PayloadHashesIdentical();
    error ProofVerificationFailed();
    error NoCommonAttester();
    error AttesterIneligible(address attester, uint256 misbehaviorCount);
    error EvidenceAlreadyRecorded(bytes32 evidenceKey);
    error UnsupportedTypehash(bytes32 typehash);

    /**
     * @notice Reconstruct the EIP-712 digest + payload hash for an
     *         attestation envelope (SL-01: delegates to shared internal impl).
     * @dev See `OmniRegistration._reconstructDigest` NatSpec for envelope
     *      layouts.
     */
    function reconstruct(
        bytes32 typehash,
        address subject,
        bytes32 sharedSupersedes,
        bytes calldata envelope,
        bytes32 domainSeparator
    ) external pure returns (bytes32 digest, bytes32 payloadHash) {
        return _reconstructInline(
            typehash, subject, sharedSupersedes, envelope, domainSeparator
        );
    }

    /**
     * @notice Supersedes-chain check (extracted helper).
     * @dev Reverts {InvalidSupersedes} on mismatch with classifier event
     *      emitted first so off-chain observers can distinguish racing from
     *      equivocation. Called from `OmniRegistration._enforceSupersedesChain`.
     */
    function checkSupersedesChain(
        mapping(address => mapping(bytes32 => bytes32)) storage currentCanonical,
        mapping(address => mapping(bytes32 => bytes32)) storage canonicalPayloadHash,
        address user,
        bytes32 typehash,
        bytes32 newDigest,
        bytes32 newPayloadHash,
        bytes32 submittedSupersedes
    ) external {
        bytes32 canonical = currentCanonical[user][typehash];
        if (submittedSupersedes != canonical) {
            bytes32 priorPayload = canonicalPayloadHash[user][typehash];
            if (newPayloadHash == priorPayload) {
                emit AttestationRaceLost(user, typehash, newDigest, canonical);
            } else {
                emit AttestationEquivocationAttempt(
                    user, typehash, newDigest, newPayloadHash, canonical, priorPayload
                );
            }
            revert InvalidSupersedes(canonical, submittedSupersedes);
        }
    }

    /**
     * @notice Eligibility gate (extracted helper). Reverts {AttesterIneligible}
     *         when any attester in the verifier's returned set has reached
     *         {MISBEHAVIOR_EXCLUSION_THRESHOLD} in the trailing window.
     */
    function requireEligibleAttesters(
        mapping(address => uint64[]) storage misbehaviorTimestamps,
        IOmniAttestationGateway gateway,
        bytes32 digest,
        bytes calldata proof
    ) external view {
        if (address(gateway) == address(0)) return;
        IBridgeVerifier verifier = gateway.committeeVerifier();
        if (address(verifier) == address(0)) return;
        (bool valid, address[] memory attesters) = verifier.verify(digest, proof);
        if (!valid) return;
        uint256 len = attesters.length;
        for (uint256 i = 0; i < len; ) {
            uint256 count = _windowCount(
                misbehaviorTimestamps[attesters[i]], MISBEHAVIOR_EXCLUSION_WINDOW
            );
            if (count >= MISBEHAVIOR_EXCLUSION_THRESHOLD) {
                revert AttesterIneligible(attesters[i], count);
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Combined submit-side gate: runs chain check, eligibility
     *         check, AND advances the canonical pointers in one library
     *         call. Combines `checkSupersedesChain` + `requireEligibleAttesters`
     *         + `recordCanonical` so each `_submit*Internal` callsite has
     *         a single library-call stub instead of three. The gateway's
     *         `verifyAndConsume` is NOT folded in because the third-party-
     *         KYC path skips it (uses a different verifier).
     *
     *         Caller MUST call `gateway.verifyAndConsume` between the
     *         chain/eligibility check and the canonical advance — that's
     *         why this function is split into two phases internally:
     *           Phase A (this function, returns false) — pre-verify.
     *         Then caller does verifyAndConsume.
     *         Then caller calls {recordCanonical} for the post-verify advance.
     *
     *         To keep the call count at 2 per submit (down from 3), the
     *         caller wraps both phases via the {gateAndRecord} convenience
     *         below. That convenience does NOT call verifyAndConsume.
     */
    function gateAndRecord(
        mapping(address => mapping(bytes32 => bytes32)) storage currentCanonical,
        mapping(address => mapping(bytes32 => bytes32)) storage canonicalPayloadHash,
        mapping(bytes32 => bool) storage wasEverCanonical,
        mapping(address => uint64[]) storage misbehaviorTimestamps,
        IOmniAttestationGateway gateway,
        address user,
        bytes32 typehash,
        bytes32 digest,
        bytes32 payloadHash,
        bytes32 supersedes,
        bytes calldata proof,
        bool phaseRecord
    ) external {
        if (phaseRecord) {
            // Phase B: advance canonical + mark prior historical.
            bytes32 prior = currentCanonical[user][typehash];
            if (prior != bytes32(0)) {
                wasEverCanonical[prior] = true;
            }
            currentCanonical[user][typehash] = digest;
            canonicalPayloadHash[user][typehash] = payloadHash;
            return;
        }
        // Phase A: chain check + eligibility.
        bytes32 canonical = currentCanonical[user][typehash];
        if (supersedes != canonical) {
            bytes32 priorPayload = canonicalPayloadHash[user][typehash];
            if (payloadHash == priorPayload) {
                emit AttestationRaceLost(user, typehash, digest, canonical);
            } else {
                emit AttestationEquivocationAttempt(
                    user, typehash, digest, payloadHash, canonical, priorPayload
                );
            }
            revert InvalidSupersedes(canonical, supersedes);
        }
        if (address(gateway) != address(0)) {
            IBridgeVerifier verifier = gateway.committeeVerifier();
            if (address(verifier) != address(0)) {
                (bool valid, address[] memory attesters)
                    = verifier.verify(digest, proof);
                if (valid) {
                    uint256 len = attesters.length;
                    for (uint256 i = 0; i < len; ) {
                        uint256 count = _windowCount(
                            misbehaviorTimestamps[attesters[i]],
                            MISBEHAVIOR_EXCLUSION_WINDOW
                        );
                        if (count >= MISBEHAVIOR_EXCLUSION_THRESHOLD) {
                            revert AttesterIneligible(attesters[i], count);
                        }
                        unchecked { ++i; }
                    }
                }
            }
        }
    }

    /**
     * @notice Advance the canonical pointers after a successful submit AND
     *         mark the prior canonical as historical.
     */
    function recordCanonical(
        mapping(address => mapping(bytes32 => bytes32)) storage currentCanonical,
        mapping(address => mapping(bytes32 => bytes32)) storage canonicalPayloadHash,
        mapping(bytes32 => bool) storage wasEverCanonical,
        address user,
        bytes32 typehash,
        bytes32 newDigest,
        bytes32 newPayloadHash
    ) external {
        bytes32 prior = currentCanonical[user][typehash];
        if (prior != bytes32(0)) {
            wasEverCanonical[prior] = true;
        }
        currentCanonical[user][typehash] = newDigest;
        canonicalPayloadHash[user][typehash] = newPayloadHash;
    }

    /**
     * @notice Permissionless equivocation-attribution body. See
     *         `OmniRegistration.recordEquivocation` NatSpec for full
     *         semantics, false-positive protection, and the v4-acceptable
     *         dedup rationale (the dedup mapping is consulted here).
     */
    function recordEquivocation(
        mapping(address => mapping(bytes32 => bytes32)) storage currentCanonical,
        mapping(bytes32 => bool) storage wasEverCanonical,
        mapping(address => uint64[]) storage misbehaviorTimestamps,
        mapping(bytes32 => bool) storage recordedEquivocationEvidence,
        IOmniAttestationGateway gateway,
        bytes32 domainSeparator,
        bytes32 typehash,
        address subject,
        bytes32 sharedSupersedes,
        bytes calldata envelopeA,
        bytes calldata proofA,
        bytes calldata envelopeB,
        bytes calldata proofB
    ) external {
        // 1. Reconstruct both digests + payload hashes via this same library.
        //    Direct internal-style call (not external) — these are internal
        //    helper paths reused, kept inline for clarity.
        bytes32 digestA;
        bytes32 payloadHashA;
        bytes32 digestB;
        bytes32 payloadHashB;
        (digestA, payloadHashA) = _reconstructInline(
            typehash, subject, sharedSupersedes, envelopeA, domainSeparator
        );
        (digestB, payloadHashB) = _reconstructInline(
            typehash, subject, sharedSupersedes, envelopeB, domainSeparator
        );

        if (payloadHashA == payloadHashB) revert PayloadHashesIdentical();

        // 2. Dedup against prior recording (audit remediation).
        (bytes32 lo, bytes32 hi) = digestA < digestB
            ? (digestA, digestB)
            : (digestB, digestA);
        bytes32 evidenceKey = keccak256(abi.encode(
            typehash, subject, sharedSupersedes, lo, hi
        ));
        if (recordedEquivocationEvidence[evidenceKey]) {
            revert EvidenceAlreadyRecorded(evidenceKey);
        }
        recordedEquivocationEvidence[evidenceKey] = true;

        // 3. Historical-canonical + first-attestation-race-immune checks.
        if (sharedSupersedes != bytes32(0)
            && !wasEverCanonical[sharedSupersedes]) {
            revert NotHistoricalCanonical(sharedSupersedes);
        }
        if (sharedSupersedes == bytes32(0)
            && currentCanonical[subject][typehash] != bytes32(0)) {
            revert FirstAttestationRaceImmune();
        }

        // 4. Verifier check.
        if (address(gateway) == address(0)) revert ProofVerificationFailed();
        IBridgeVerifier verifier = gateway.committeeVerifier();
        if (address(verifier) == address(0)) revert ProofVerificationFailed();
        (bool validA, address[] memory attestersA) = verifier.verify(digestA, proofA);
        (bool validB, address[] memory attestersB) = verifier.verify(digestB, proofB);
        if (!validA || !validB) revert ProofVerificationFailed();

        // 5. Attribute common attesters.
        // solhint-disable-next-line not-rely-on-time
        uint64 ts = uint64(block.timestamp);
        bool anyCommon = false;
        uint256 lenA = attestersA.length;
        uint256 lenB = attestersB.length;
        for (uint256 i = 0; i < lenA; ) {
            address candidate = attestersA[i];
            for (uint256 j = 0; j < lenB; ) {
                if (attestersB[j] == candidate) {
                    misbehaviorTimestamps[candidate].push(ts);
                    emit MisbehaviorRecorded(candidate, subject, typehash, ts);
                    anyCommon = true;
                    break;
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        if (!anyCommon) revert NoCommonAttester();
    }

    /// @notice Public counter view exposed by the consumer via thin wrapper.
    function getMisbehaviorCountInWindow(
        mapping(address => uint64[]) storage misbehaviorTimestamps,
        address attester,
        uint256 windowSeconds
    ) external view returns (uint256) {
        return _windowCount(misbehaviorTimestamps[attester], windowSeconds);
    }

    // ─── Internal helpers (compiled inline into the library bytecode) ──────

    function _windowCount(
        uint64[] storage stamps,
        uint256 windowSeconds
    ) private view returns (uint256 count) {
        uint256 len = stamps.length;
        if (len == 0) return 0;
        // solhint-disable-next-line not-rely-on-time
        uint256 cutoff = block.timestamp > windowSeconds
            ? block.timestamp - windowSeconds
            : 0;
        for (uint256 i = len; i > 0; ) {
            unchecked { --i; }
            if (stamps[i] < cutoff) break;
            unchecked { ++count; }
        }
    }

    // solhint-disable-next-line code-complexity
    function _reconstructInline(
        bytes32 typehash,
        address subject,
        bytes32 sharedSupersedes,
        bytes calldata envelope,
        bytes32 domainSeparator
    ) private pure returns (bytes32 digest, bytes32 payloadHash) {
        // Mirror of {reconstruct} kept private so {recordEquivocation} can
        // reuse the dispatcher without an additional external SLOAD round-
        // trip through the library's call-site.
        bytes32 structHash;
        if (typehash == PHONE_VERIFICATION_TYPEHASH) {
            (bytes32 phoneHash, uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, uint256, bytes32, uint256));
            payloadHash = phoneHash;
            structHash = keccak256(abi.encode(
                typehash, subject, phoneHash, sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == SOCIAL_VERIFICATION_TYPEHASH) {
            (bytes32 socialHash, string memory platform, uint256 ts,
             bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, string, uint256, bytes32, uint256));
            payloadHash = keccak256(abi.encode(socialHash, keccak256(bytes(platform))));
            structHash = keccak256(abi.encode(
                typehash, subject, socialHash, keccak256(bytes(platform)),
                sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == EMAIL_VERIFICATION_TYPEHASH) {
            (bytes32 emailHash, uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, uint256, bytes32, uint256));
            payloadHash = emailHash;
            structHash = keccak256(abi.encode(
                typehash, subject, emailHash, sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == ID_VERIFICATION_TYPEHASH) {
            (bytes32 idHash, string memory country, uint256 ts,
             bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, string, uint256, bytes32, uint256));
            payloadHash = keccak256(abi.encode(idHash, keccak256(bytes(country))));
            structHash = keccak256(abi.encode(
                typehash, subject, idHash, keccak256(bytes(country)),
                sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == ADDRESS_VERIFICATION_TYPEHASH) {
            (bytes32 addressHash, string memory country, bytes32 documentType,
             uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, string, bytes32, uint256, bytes32, uint256));
            payloadHash = keccak256(abi.encode(
                addressHash, keccak256(bytes(country)), documentType
            ));
            structHash = keccak256(abi.encode(
                typehash, subject, addressHash, keccak256(bytes(country)),
                documentType, sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == SELFIE_VERIFICATION_TYPEHASH) {
            (bytes32 selfieHash, uint256 similarity, uint256 ts,
             bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, uint256, uint256, bytes32, uint256));
            payloadHash = keccak256(abi.encode(selfieHash, similarity));
            structHash = keccak256(abi.encode(
                typehash, subject, selfieHash, similarity,
                sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == PERSONA_VERIFICATION_TYPEHASH) {
            (bytes32 verificationHash, uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bytes32, uint256, bytes32, uint256));
            payloadHash = verificationHash;
            structHash = keccak256(abi.encode(
                typehash, subject, verificationHash,
                sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == ACCREDITED_INVESTOR_TYPEHASH) {
            (uint8 criteria, bool certified, uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (uint8, bool, uint256, bytes32, uint256));
            payloadHash = keccak256(abi.encode(criteria, certified));
            structHash = keccak256(abi.encode(
                typehash, subject, criteria, certified,
                sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == AML_CLEARANCE_TYPEHASH) {
            (bool cleared, uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (bool, uint256, bytes32, uint256));
            payloadHash = keccak256(abi.encode(cleared));
            structHash = keccak256(abi.encode(
                typehash, subject, cleared,
                sharedSupersedes, ts, nonce, dl
            ));
        } else if (typehash == THIRD_PARTY_KYC_TYPEHASH) {
            (address provider, uint256 ts, bytes32 nonce, uint256 dl)
                = abi.decode(envelope, (address, uint256, bytes32, uint256));
            payloadHash = bytes32(uint256(uint160(provider)));
            structHash = keccak256(abi.encode(
                typehash, subject, provider,
                sharedSupersedes, ts, nonce, dl
            ));
        } else {
            revert UnsupportedTypehash(typehash);
        }
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
