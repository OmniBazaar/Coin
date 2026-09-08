// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IBridgeVerifier} from "../bridge/IBridgeVerifier.sol";

/**
 * @title MockGatewayForDecent
 * @author OmniBazaar Team
 * @notice Minimal `IOmniAttestationGateway` stand-in for OMNICORE-DECENT
 *         test coverage. Implements the three accessors OmniRegistration
 *         actually consumes (`verifyAndConsume`, `authorizedConsumers`,
 *         `committeeVerifier`) with operator-controlled outcomes so tests
 *         can drive every chain-check + eligibility branch without
 *         standing up the real OmniAttestationGateway + RandomCommitteeVerifier
 *         pair (which both enforce production-only metadata gates that
 *         don't apply to chain-check coverage).
 */
contract MockGatewayForDecent {
    /// @notice Verifier returned by {committeeVerifier}.
    IBridgeVerifier public verifier;

    /// @notice When true, `verifyAndConsume` reverts with `Forced()`.
    bool public consumeShouldRevert;

    /// @notice When true, `verifyAndConsume` counts how many times it was called.
    uint256 public consumeCallCount;

    /// @notice Test hook: simulate gateway rejection path.
    error Forced();

    /// @notice Set the committee verifier returned by {committeeVerifier}.
    /// @param v Verifier implementation address (mock or real).
    function setCommitteeVerifier(IBridgeVerifier v) external {
        verifier = v;
    }

    /// @notice Toggle whether `verifyAndConsume` reverts on next call.
    /// @param shouldRevert New revert flag.
    function setConsumeShouldRevert(bool shouldRevert) external {
        consumeShouldRevert = shouldRevert;
    }

    /// @notice OmniRegistration calls this from `_verifyAttestation`.
    /// @dev Mock counts invocations and respects the {consumeShouldRevert}
    ///      flag. Real verification logic is intentionally absent —
    ///      OmniRegistration's own chain check + eligibility gate are what
    ///      these tests exercise.
    function verifyAndConsume(
        address /* subject */,
        bytes32 /* digest */,
        bytes32 /* nonce */,
        uint256 /* deadline */,
        bytes calldata /* proof */
    ) external {
        ++consumeCallCount;
        if (consumeShouldRevert) revert Forced();
    }

    /// @notice {committeeVerifier} accessor surface consumed by
    ///         OmniRegistration's eligibility gate + `recordEquivocation`.
    function committeeVerifier() external view returns (IBridgeVerifier) {
        return verifier;
    }

    /// @notice OmniRegistration calls this from `setAttestationGateway` to
    ///         confirm the new gateway already whitelists OmniRegistration
    ///         as a consumer (audit M-NEW-4). Mock returns true unconditionally.
    function authorizedConsumers(address /* consumer */) external pure returns (bool) {
        return true;
    }
}
