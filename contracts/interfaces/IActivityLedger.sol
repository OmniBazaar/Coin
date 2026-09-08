// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IActivityLedger
 * @author OmniBazaar Team
 * @notice Minimal interface for the on-chain validator activity ledger
 *         (VT-18). OmniValidatorRewards V4 reads the last committee-attested
 *         epoch per validator to derive the activity component of reward
 *         weights from on-chain events only, instead of self-submitted
 *         heartbeats.
 */
interface IActivityLedger {
    /**
     * @notice The most recent epoch in which the validator was attested
     *         active by the committee.
     * @param validator The validator address.
     * @return The last attested epoch, or 0 if never attested.
     */
    function lastAttestationEpoch(
        address validator
    ) external view returns (uint256);

    /**
     * @notice The lifetime count of epochs in which the validator was
     *         attested active.
     * @param validator The validator address.
     * @return The attestation count.
     */
    function attestationCount(
        address validator
    ) external view returns (uint256);
}
