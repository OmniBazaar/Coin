// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockOmniRegistrationForAttestation
 * @notice Test-only stub exposing `getRegistration(address)` in the exact
 *         struct shape `RandomCommitteeVerifier`'s reader interface expects.
 *         Lets tests set the (kycTier, ...) per-validator without exercising
 *         the full Persona / phone / email verification flow.
 * @dev The Registration struct MUST match the real upstream layout in
 *      `OmniRegistration.sol:116-125` exactly — otherwise the ABI decode
 *      on the verifier side misaligns. Verified 2026-05-18.
 */
contract MockOmniRegistrationForAttestation {
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

    mapping(address user => Registration reg) private _regs;

    /// @notice Test helper: set the KYC tier for a user (sufficient for
    ///         verifier eligibility tests).
    function setKycTier(address user, uint8 tier) external {
        Registration storage r = _regs[user];
        r.timestamp = block.timestamp;
        r.kycTier = tier;
    }

    function getRegistration(address user) external view returns (Registration memory) {
        return _regs[user];
    }
}
