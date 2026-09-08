// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    MpcCore,
    gtUint256
} from "../coti-helium/utils/mpc/MpcCore.sol";

/**
 * @title PrivatePredictionMath
 * @author OmniBazaar
 * @notice External MPC-math helpers extracted from {PrivatePredictionMarket} so
 *         that contract stays under the EIP-170 24576-byte deployment limit
 *         after the itUint256 retrofit. Every function is PURE value-in →
 *         value-out MPC computation over `gtUint256` garbled handles — it reads
 *         and writes NO contract storage and declares NO state — so calling it
 *         via the (delegatecall) library linkage from an upgradeable (UUPS)
 *         contract introduces zero storage-layout coupling. Because libraries
 *         are invoked by `delegatecall`, the garbled handles remain valid in the
 *         caller's MPC session (`address(this)` and the tx are unchanged).
 * @dev    Functions are `external` (not `internal`) on purpose: only externally
 *         linked library code is deployed separately and removed from the
 *         caller's bytecode. The caller must link this library's deployed
 *         address at deploy time.
 */
library PrivatePredictionMath {
    /**
     * @notice Split an encrypted stake into (fee, stakeAfterFee) in MPC space:
     *         `fee = stake * betFeeBps / bpsDivisor`, `stakeAfter = stake - fee`.
     * @param stakeG     Encrypted stake handle.
     * @param betFeeBps  Public bet fee in basis points.
     * @param bpsDivisor Public basis-points divisor (10_000).
     * @return feeG       Encrypted fee.
     * @return stakeAfterG Encrypted stake net of fee.
     */
    function feeSplit(
        gtUint256 stakeG,
        uint256 betFeeBps,
        uint256 bpsDivisor
    ) external returns (gtUint256 feeG, gtUint256 stakeAfterG) {
        require(bpsDivisor > 0, "bpsDivisor cannot be zero");
        require(betFeeBps <= bpsDivisor, "betFeeBps cannot exceed bpsDivisor");
        gtUint256 feeBpsG = MpcCore.setPublic256(betFeeBps);
        gtUint256 bpsDivG = MpcCore.setPublic256(bpsDivisor);
        gtUint256 feeNumG = MpcCore.checkedMul(stakeG, feeBpsG);
        feeG = MpcCore.div(feeNumG, bpsDivG);
        stakeAfterG = MpcCore.checkedSub(stakeG, feeG);
    }

    /**
     * @notice Compute an encrypted payout in MPC space:
     *         `payout = shares * payoutPerShareBps / bpsDivisor`.
     * @param sharesG          Encrypted winning-shares handle.
     * @param payoutPerShareBps Public payout-per-share in basis points.
     * @param bpsDivisor       Public basis-points divisor (10_000).
     * @return payoutG Encrypted payout.
     */
    function payout(
        gtUint256 sharesG,
        uint256 payoutPerShareBps,
        uint256 bpsDivisor
    ) external returns (gtUint256 payoutG) {
        require(bpsDivisor > 0, "bpsDivisor cannot be zero");
        gtUint256 mulG = MpcCore.setPublic256(payoutPerShareBps);
        gtUint256 divG = MpcCore.setPublic256(bpsDivisor);
        gtUint256 numG = MpcCore.checkedMul(sharesG, mulG);
        payoutG = MpcCore.div(numG, divG);
    }
}
