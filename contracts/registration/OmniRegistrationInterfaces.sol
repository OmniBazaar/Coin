// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Slim view-only surface of `IBridgeVerifier` that OmniRegistration
 *         and {OmniRegistrationDigestLib} need for the OMNICORE-DECENT
 *         eligibility gate and equivocation attribution. The full
 *         interface lives at `Coin/contracts/bridge/IBridgeVerifier.sol`;
 *         hoisted to this shared file so the library and the consuming
 *         contract can reference the same type without forcing the heavy
 *         bridge-package dependency into the library compile graph.
 *
 * @dev    `verify` is view by contract — no nonce consumption, no replay
 *         risk from reading it twice. The returned `attesters` list is
 *         the deduplicated, sorted committee that backed `messageHash`.
 */
interface IBridgeVerifier {
    function verify(bytes32 messageHash, bytes calldata proof)
        external
        view
        returns (bool valid, address[] memory attesters);
}

/**
 * @notice OmniRegistration's view of the attestation gateway — only the
 *         three accessors the consumer + library actually call. See
 *         `Coin/contracts/attestation/OmniAttestationGateway.sol` for the
 *         full implementation.
 */
interface IOmniAttestationGateway {
    function verifyAndConsume(
        address subject,
        bytes32 digest,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata proof
    ) external;

    /// @notice True if `consumer` is permitted to invoke `verifyAndConsume`.
    function authorizedConsumers(address consumer) external view returns (bool);

    /// @notice Active committee verifier. Returns `address(0)` while the
    ///         gateway is running the legacy single-key path.
    /// @dev OMNICORE-DECENT: OmniRegistration reads this so the eligibility
    ///      gate + `recordEquivocation` can call `verify(digest, proof)`
    ///      directly — view-only, no nonce consumption (Option B).
    function committeeVerifier() external view returns (IBridgeVerifier);
}
