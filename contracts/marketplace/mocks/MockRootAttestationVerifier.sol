// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockRootAttestationVerifier
 * @author OmniCoin Development Team
 * @notice Test-only stand-in for the committee verifier that
 *         `MarketplaceRootRegistry` consults.
 * @dev Lets a test drive the registry's own rules — epoch ordering, chain
 *      links, range continuity — without assembling real committee signatures
 *      for every case. The end-to-end path against the real
 *      `RandomCommitteeVerifier` is covered separately; this mock exists so a
 *      failure in an ordering test cannot be blamed on signature assembly.
 *
 *      🛑 `verify` is `view`, and has to be. The registry calls it through a
 *      `view` interface, which compiles to `STATICCALL`, so a mock that
 *      recorded its arguments in storage would revert every call. That is the
 *      correct constraint rather than an inconvenience: a verifier able to
 *      write state could lie about a quorum it once reported, which is exactly
 *      why the real interface is `view`.
 *
 *      So instead of recording what it was asked, the mock is told in advance
 *      what it should be asked and refuses anything else. That is the stronger
 *      test: the registry's "recomputes the commitment from its own arguments"
 *      property is checked by giving the mock the independently-computed
 *      commitment and watching the publish fail whenever the registry would
 *      have derived something different.
 */
contract MockRootAttestationVerifier {
    /// @notice What {verify} returns for `valid`, before any expectation check.
    bool public nextValid = true;

    /// @notice The attesters {verify} returns.
    address[] private _attesters;

    /// @notice What {quorumThreshold} returns.
    uint256 public threshold = 4;

    /**
     * @notice The `messageHash` {verify} will accept.
     * @dev Zero means "accept any", which is what the ordering tests want.
     */
    bytes32 public expectedMessageHash;

    /**
     * @notice The `proof` blob {verify} will accept.
     * @dev Empty means "accept any".
     */
    bytes public expectedProof;

    /**
     * @notice Set the verdict {verify} returns when its expectations are met.
     * @param valid Whether the next verification succeeds.
     */
    function setValid(bool valid) external {
        nextValid = valid;
    }

    /**
     * @notice Set the attester list {verify} returns.
     * @param attesters The addresses to report as having signed.
     */
    function setAttesters(address[] calldata attesters) external {
        delete _attesters;
        for (uint256 i = 0; i < attesters.length; ++i) {
            _attesters.push(attesters[i]);
        }
    }

    /**
     * @notice Set the quorum {quorumThreshold} reports.
     * @param newThreshold The threshold to report.
     */
    function setThreshold(uint256 newThreshold) external {
        threshold = newThreshold;
    }

    /**
     * @notice Require {verify} to be called with exactly this `messageHash`.
     * @param messageHash The commitment the registry is expected to compute;
     *        zero to accept any.
     */
    function expectMessageHash(bytes32 messageHash) external {
        expectedMessageHash = messageHash;
    }

    /**
     * @notice Require {verify} to be called with exactly this `proof`.
     * @param proof The blob the registry is expected to forward unchanged;
     *        empty to accept any.
     */
    function expectProof(bytes calldata proof) external {
        expectedProof = proof;
    }

    /**
     * @notice Mirror of the verifier's `verify`.
     * @param messageHash The hash the registry computed.
     * @param proof The opaque proof blob.
     * @return valid The configured verdict, and only when both expectations hold.
     * @return attesters The configured attester list, empty when invalid.
     */
    function verify(bytes32 messageHash, bytes calldata proof)
        external
        view
        returns (bool valid, address[] memory attesters)
    {
        if (
            expectedMessageHash != bytes32(0) &&
            messageHash != expectedMessageHash
        ) {
            return (false, new address[](0));
        }
        if (
            expectedProof.length != 0 &&
            keccak256(proof) != keccak256(expectedProof)
        ) {
            return (false, new address[](0));
        }
        if (!nextValid) {
            return (false, new address[](0));
        }
        return (true, _attesters);
    }

    /**
     * @notice Mirror of the verifier's `quorumThreshold`.
     * @return The configured threshold.
     */
    function quorumThreshold() external view returns (uint256) {
        return threshold;
    }
}
