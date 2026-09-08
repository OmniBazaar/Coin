// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IBridgeVerifier
 * @author OmniCoin Development Team
 * @notice Pluggable attestation verifier for OmniPrivacyBridgeV2.
 * @dev v1 implementation is `Ecdsa5of5AttestationVerifier` (k-of-n ECDSA at the
 *      5-validator scale). Future v2 swaps in a real BLS aggregator or a SNARK
 *      verifier without changing the bridge ABI. The bridge is allowed to swap
 *      the verifier address only via a timelocked governance call.
 *
 *      The verifier MUST be **stateless from the bridge's perspective**: every
 *      call is `view`, no privileged state mutation. Bridge security depends on
 *      this — a malicious verifier with state could lie about quorum on past
 *      messages and replay never-emitted events.
 */
interface IBridgeVerifier {
    /**
     * @notice Verify an attestation `proof` over `messageHash`.
     * @dev MUST be a pure verification — no calls outside the registered
     *      validator set, no time-dependent logic, no storage writes.
     *      The returned `attesters` list is the canonical record of which
     *      validators backed this message; the bridge stores it for slashing
     *      on a successful fraud challenge.
     * @param messageHash Keccak hash of the attested payload (lock/burn nonce + amount + recipient + chainId).
     * @param proof Verifier-specific opaque blob. ECDSA v1: `bytes proof = abi.encodePacked(sig0 || sig1 || ...)` 65 bytes per signature.
     * @return valid Whether `proof` constitutes a valid quorum attestation over `messageHash`.
     * @return attesters Sorted, deduplicated list of validator addresses whose signatures contributed to the quorum. Empty if `valid` is false.
     */
    function verify(bytes32 messageHash, bytes calldata proof)
        external
        view
        returns (bool valid, address[] memory attesters);

    /**
     * @notice Stable identifier for this verifier implementation.
     * @return Short version string ("ecdsa-5of5-v1", "bls-bn254-v1", "zk-groth16-v1", ...).
     */
    function verifierVersion() external view returns (string memory);

    /**
     * @notice The minimum number of attesters (k of n) this verifier requires.
     * @dev The bridge does not enforce a separate quorum threshold; the
     *      verifier is the single source of truth for "is quorum reached".
     *      Exposed for off-chain monitoring and clear audit reports.
     */
    function quorumThreshold() external view returns (uint256);

    /**
     * @notice Whether `account` is currently a registered attester.
     * @dev Mandatory to be implemented by every concrete verifier so that
     *      bridges can rely on a typed check rather than duck-typed
     *      staticcall. Implementations MUST return false for `address(0)`.
     */
    function isValidator(address account) external view returns (bool);

    /**
     * @notice Verify a single-signer veto proof over `vetoHash`.
     * @dev Used by the bridge's `challengeUnlock` / `challengeMint` paths so
     *      that ANY caller (not just registered validators) can submit a
     *      veto, provided it was signed by a single registered validator.
     *      The signer is returned as slashing evidence.
     *
     *      `vetoHash` semantics: bridges hash `(VETO_DOMAIN_TAG, chainId,
     *      address(this), burnNonce_or_lockNonce)` — see bridge
     *      `_vetoHash` for the exact encoding.
     *
     *      MUST be a pure verification — same constraints as {verify}: no
     *      state mutation, no time-dependent logic, no external calls
     *      outside the registered validator set.
     * @param vetoHash Keccak hash of the canonical veto payload.
     * @param fraudProof Single ECDSA signature (65 bytes) from a registered validator.
     * @return valid Whether `fraudProof` constitutes a valid veto signature.
     * @return signer The recovered registered validator address (zero if `valid` is false).
     */
    function verifyVeto(bytes32 vetoHash, bytes calldata fraudProof)
        external
        view
        returns (bool valid, address signer);
}
